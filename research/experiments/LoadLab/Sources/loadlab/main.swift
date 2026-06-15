// LoadLab — empirical measurement of MLX safetensors load behavior.
//
// Usage:
//   loadlab lazyproof <model.safetensors>
//   loadlab baseline  <model.safetensors>
//   loadlab chunked   <model.safetensors> <chunkSize>
//
// Modes:
//   lazyproof — load arrays WITHOUT eval, snapshot memory, then eval, snapshot
//               again. Proves (or disproves) that bytes are read only at eval.
//   baseline  — load + eval all tensors at once (what Forge's loadWeights does).
//   chunked   — load lazily, eval in batches of <chunkSize> tensors (the
//               proposed Option B mechanism), measuring peak footprint.
//
// All modes print: wall-clock per phase, process phys_footprint (the number
// Activity Monitor calls "Memory"), and MLX GPU active/peak memory.

import Darwin
import Foundation
import MLX

// MARK: - Measurement

/// phys_footprint: the kernel's ledger of dirty + compressed + IOKit memory
/// for this task — the honest "how much RAM does this cost" number.
func physFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

func mb(_ bytes: Int64) -> String { String(format: "%8.1f MB", Double(bytes) / 1_048_576) }
func mb(_ bytes: Int) -> String { mb(Int64(bytes)) }

struct Snapshot {
    let label: String
    let footprint: Int64
    let gpuActive: Int
    let gpuPeak: Int
    let elapsed: TimeInterval

    func line() -> String {
        "\(label.padding(toLength: 26, withPad: " ", startingAt: 0))"
            + "footprint=\(mb(footprint))  gpuActive=\(mb(gpuActive))  "
            + "gpuPeak=\(mb(gpuPeak))  t=\(String(format: "%6.2f", elapsed))s"
    }
}

final class Bench {
    let start = Date()
    var peakFootprint: Int64 = 0
    var snapshots: [Snapshot] = []

    func snap(_ label: String) {
        let fp = physFootprint()
        peakFootprint = max(peakFootprint, fp)
        let s = Snapshot(
            label: label, footprint: fp,
            gpuActive: Memory.activeMemory, gpuPeak: Memory.peakMemory,
            elapsed: Date().timeIntervalSince(start))
        snapshots.append(s)
        print(s.line())
    }
}

// MARK: - Modes

func loadLazy(_ url: URL, bench: Bench) throws -> [String: MLXArray] {
    bench.snap("before load")
    let (weights, _) = try loadArraysAndMetadata(url: url)
    bench.snap("after load (no eval)")
    print("  tensors: \(weights.count)")
    return weights
}

func runLazyProof(_ url: URL) throws {
    let bench = Bench()
    let weights = try loadLazy(url, bench: bench)
    // If loading is lazy, footprint/gpu must be ~flat here despite the
    // multi-GB file. The jump must happen at eval below.
    eval(Array(weights.values))
    bench.snap("after eval (all)")
    print("PEAK footprint: \(mb(bench.peakFootprint))")
}

func runBaseline(_ url: URL) throws {
    let bench = Bench()
    let weights = try loadLazy(url, bench: bench)
    eval(Array(weights.values))  // what Forge's loadWeights does: one big eval
    bench.snap("after eval (all-at-once)")
    print("PEAK footprint: \(mb(bench.peakFootprint))")
}

func runChunked(_ url: URL, chunkSize: Int) throws {
    let bench = Bench()
    let weights = try loadLazy(url, bench: bench)
    // Deterministic order so runs are comparable.
    let values = weights.keys.sorted().map { weights[$0]! }
    var done = 0
    for chunk in stride(from: 0, to: values.count, by: chunkSize) {
        let batch = Array(values[chunk ..< min(chunk + chunkSize, values.count)])
        eval(batch)
        done += batch.count
        // Sample footprint mid-flight — the peak is the whole point.
        bench.peakFootprint = max(bench.peakFootprint, physFootprint())
    }
    bench.snap("after eval (chunked x\(chunkSize))")
    print("  evaluated \(done) tensors in chunks of \(chunkSize)")
    print("PEAK footprint: \(mb(bench.peakFootprint))")
}

// MARK: - Entry

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: loadlab lazyproof|baseline|chunked <model.safetensors> [chunkSize]")
    exit(2)
}
let mode = args[1]
let url = URL(filePath: args[2])
guard FileManager.default.fileExists(atPath: url.path) else {
    print("no such file: \(url.path)")
    exit(2)
}
let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    .flatMap { $0 } ?? 0
print("== loadlab \(mode) — \(url.lastPathComponent) (\(mb(fileSize))) ==")

do {
    switch mode {
    case "lazyproof": try runLazyProof(url)
    case "baseline": try runBaseline(url)
    case "chunked":
        let chunkSize = args.count > 3 ? Int(args[3]) ?? 64 : 64
        try runChunked(url, chunkSize: chunkSize)
    default:
        print("unknown mode \(mode)")
        exit(2)
    }
} catch {
    print("FAILED: \(error)")
    exit(1)
}
