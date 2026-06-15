// Keep MappedFile alive while using its pointers. If freed, pointers dangle.

import Foundation
import MLX
import MLXNN
import MLXLMCommon

enum MMapError: Error { case openFailed, statFailed, mapFailed, rangeError }

final class MappedFile {
    let fd: Int32
    let size: Int
    let base: UnsafePointer<UInt8>

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw MMapError.openFailed }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw MMapError.statFailed
        }
        let size = Int(st.st_size)
        guard size > 0 else {
            close(fd)
            throw MMapError.openFailed
        }

        let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
        guard let raw = raw, raw != MAP_FAILED else {
            close(fd)
            throw MMapError.mapFailed
        }

        self.fd = fd
        self.size = size
        self.base = UnsafePointer(raw.assumingMemoryBound(to: UInt8.self))
    }

    func bytes(offset: Int, length: Int) throws -> UnsafeBufferPointer<UInt8> {
        guard offset >= 0, length >= 0, offset + length <= size else {
            throw MMapError.rangeError
        }
        return UnsafeBufferPointer(start: base + offset, count: length)
    }

    func read<T>(_ type: T.Type, offset: Int, count: Int) throws -> [T] {
        let byteLength = count * MemoryLayout<T>.stride
        guard offset >= 0, count >= 0, offset + byteLength <= size else {
            throw MMapError.rangeError
        }
        let raw = UnsafeRawPointer(base + offset)
        var result = [T]()
        result.reserveCapacity(count)
        for i in 0..<count {
            let value = raw.loadUnaligned(
                fromByteOffset: i * MemoryLayout<T>.stride,
                as: T.self
            )
            result.append(value)
        }
        return result
    }

    func advise(_ advice: Advice) {
        _ = madvise(UnsafeMutableRawPointer(mutating: base), size, advice.raw)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), size)
        close(fd)
    }
}

enum Advice {
    case sequential, random, willNeed
    var raw: Int32 {
        switch self {
        case .sequential: return MADV_SEQUENTIAL
        case .random:     return MADV_RANDOM
        case .willNeed:   return MADV_WILLNEED
        }
    }
}

struct TensorInfo {
    let shape: [Int]
    let dtype: String
    let dataOffsets: (start: Int, end: Int)
}

final class SafetensorsReader {
    let file: MappedFile
    let tensorIndex: [String: TensorInfo]

    init(path: String) throws {
        self.file = try MappedFile(path: path)

        let lenBuf = try file.bytes(offset: 0, length: 8)
        var headerLength = 0
        for i in 0..<8 { headerLength |= Int(lenBuf[i]) << (i * 8) }

        guard headerLength + 8 <= file.size else { throw MMapError.rangeError }

        let jsonBuf = try file.bytes(offset: 8, length: headerLength)
        let jsonData = Data(jsonBuf)

        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MMapError.mapFailed
        }

        var index = [String: TensorInfo]()
        for (name, info) in json {
            guard let dict = info as? [String: Any],
                  let shapeArr = dict["shape"] as? [Int],
                  let dtype = dict["dtype"] as? String,
                  let offsetsArr = dict["data_offsets"] as? [Int],
                  offsetsArr.count == 2 else { continue }

            let start = offsetsArr[0] + 8 + headerLength
            let end = offsetsArr[1] + 8 + headerLength

            index[name] = TensorInfo(shape: shapeArr, dtype: dtype, dataOffsets: (start, end))
        }
        self.tensorIndex = index
    }

    func readTensor(name: String) throws -> TensorInfo {
        guard let info = tensorIndex[name] else { throw MMapError.rangeError }
        guard info.dataOffsets.end <= file.size else { throw MMapError.rangeError }
        return info
    }

    /// Creates an MLXArray backed by the memory-mapped file.
    /// The receiver (SafetensorsReader) is kept alive for the lifetime of the array.
    func makeArray(named name: String) throws -> MLXArray {
        let info = try readTensor(name: name)
        let dtype = try mapDType(info.dtype)

        let ptr = UnsafeMutableRawPointer(mutating: file.base + info.dataOffsets.start)

        return MLXArray(rawPointer: ptr, info.shape, dtype: dtype) { [self] in
            // Capture self so the MappedFile stays alive as long as the MLXArray exists.
            _ = self
        }
    }
}

private func mapDType(_ string: String) throws -> DType {
    switch string {
    case "float32":  return .float32
    case "float16":  return .float16
    case "bfloat16": return .bfloat16
    case "float64":  return .float64
    case "int8":     return .int8
    case "uint8":    return .uint8
    case "int16":    return .int16
    case "uint16":   return .uint16
    case "int32":    return .int32
    case "uint32":   return .uint32
    case "int64":    return .int64
    case "uint64":   return .uint64
    case "bool":     return .bool
    case "complex64": return .complex64
    default:
        throw MMapError.mapFailed
    }
}

// MARK: - Full Model Loading Path (mmap)

/// Loads all weights from the safetensors files in `modelDirectory` using memory mapping.
/// Returns the list of readers that must be kept alive for the lifetime of the model.
func loadWeightsMmap(
    modelDirectory: URL,
    model: any LanguageModel,
    quantization: BaseConfiguration.Quantization? = nil,
    perLayerQuantization: BaseConfiguration.PerLayerQuantization? = nil
) throws -> [SafetensorsReader] {

    // 1. Discover all safetensors shards
    var shardURLs: [URL] = []
    let enumerator = FileManager.default.enumerator(at: modelDirectory, includingPropertiesForKeys: nil)!
    for case let url as URL in enumerator {
        if url.pathExtension == "safetensors" {
            shardURLs.append(url)
        }
    }

    // 2. Create a reader for each shard and load every tensor via mmap.
    //    Capture metadata from the first shard (matching original loader behavior).
    var readers: [SafetensorsReader] = []
    var weights = [String: MLXArray]()
    var metadata: [String: String] = [:]

    for (index, url) in shardURLs.enumerated() {
        let reader = try SafetensorsReader(path: url.path)
        for name in reader.tensorIndex.keys {
            let array = try reader.makeArray(named: name)
            weights[name] = array
        }
        if index == 0 {
            // Read metadata from the first shard only
            let lenBuf = try reader.file.bytes(offset: 0, length: 8)
            var headerLength = 0
            for i in 0..<8 { headerLength |= Int(lenBuf[i]) << (i * 8) }
            let jsonBuf = try reader.file.bytes(offset: 8, length: headerLength)
            if let json = try? JSONSerialization.jsonObject(with: Data(jsonBuf)) as? [String: Any],
               let meta = json["__metadata__"] as? [String: String] {
                metadata = meta
            }
        }
        readers.append(reader)
    }

    // 3. Per-model sanitize (now using real metadata from first shard)
    weights = model.sanitize(weights: weights, metadata: metadata)

    // 4. Quantization (if requested)
    if quantization != nil || perLayerQuantization != nil {
        quantize(model: model) { path, module in
            if weights["\(path).scales"] != nil {
                if let perLayerQuantization {
                    return perLayerQuantization.quantization(layer: path)?.asTuple
                } else {
                    return quantization?.asTuple
                }
            } else {
                return nil
            }
        }
    }

    // 5. Apply weights to the model
    let parameters = ModuleParameters.unflattened(weights)
    try model.update(parameters: parameters, verify: [.all])

    eval(model)

    return readers
}
