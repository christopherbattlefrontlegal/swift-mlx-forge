// Forge — bounded per-shard and deferred MLX weight loading.
//
// Forge-controlled MLX weight materialization (bounded/deferred). Public-source
// audit: MLX arrays are lazy until eval, but mlx-swift-lm's loadWeights calls
// eval(model) on everything at once. This module provides Forge-controlled
// materialization without patching the remote mlx-swift-lm pin.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

enum WeightLoadError: Error, LocalizedError {
    case noSafetensors
    case unreadableModelDirectory(URL)
    case duplicateTensor(String, URL)

    var errorDescription: String? {
        switch self {
        case .noSafetensors: "No .safetensors shards found in the model folder."
        case .unreadableModelDirectory(let url):
            "Unable to enumerate model folder: \(url.path)"
        case .duplicateTensor(let name, let url):
            "Duplicate tensor '\(name)' found while loading \(url.lastPathComponent)."
        }
    }
}

/// Resolve the separately packaged AEON Qwen3.6 MTP drafter. Explicit
/// configuration wins; otherwise accept a sidecar inside the target folder or
/// any installed `qwen3_5_mtp` checkpoint in Forge's managed model cache.
func qwenMTPDrafterDirectory(for targetDirectory: URL) -> URL? {
    let fm = FileManager.default
    guard let targetConfig = qwenConfiguration(at: targetDirectory),
        qwenModelType(in: targetConfig).hasPrefix("qwen3_5"),
        qwenModelType(in: targetConfig) != "qwen3_5_mtp"
    else { return nil }

    func isCompatibleDrafter(_ url: URL) -> Bool {
        guard let draftConfig = qwenConfiguration(at: url),
            qwenModelType(in: draftConfig) == "qwen3_5_mtp"
        else { return false }

        let targetText = qwenTextConfiguration(in: targetConfig)
        let draftText = qwenTextConfiguration(in: draftConfig)
        return targetText["hidden_size"] as? Int == draftText["hidden_size"] as? Int
            && targetText["vocab_size"] as? Int == draftText["vocab_size"] as? Int
    }

    if let explicit = ProcessInfo.processInfo.environment["FORGE_QWEN_MTP_DRAFTER_PATH"],
        !explicit.isEmpty
    {
        let url = URL(fileURLWithPath: explicit, isDirectory: true)
        if isCompatibleDrafter(url) { return url }
    }

    for name in ["mtp-drafter", "MTP-Drafter", "qwen3_5_mtp"] {
        let url = targetDirectory.appending(component: name, directoryHint: .isDirectory)
        if isCompatibleDrafter(url) { return url }
    }

    guard let enumerator = fm.enumerator(
        at: ForgePaths.modelsRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    for case let url as URL in enumerator where url.lastPathComponent == "config.json" {
        let directory = url.deletingLastPathComponent()
        if isCompatibleDrafter(directory) { return directory }
    }
    return nil
}

/// True when the checkpoint packages Qwen's native MTP head in its own shards
/// (Qwen3.8): the text config declares MTP layers and a shard holds an `mtp.`
/// tensor. Reads the safetensors index, or only the shard headers; no weights.
func qwenCheckpointHasNativeMTPHead(at directory: URL) -> Bool {
    guard let config = qwenConfiguration(at: directory),
        qwenModelType(in: config).hasPrefix("qwen3_5"),
        qwenModelType(in: config) != "qwen3_5_mtp"
    else { return false }
    let text = qwenTextConfiguration(in: config)
    let declared =
        (text["mtp_num_hidden_layers"] as? Int)
        ?? (text["num_nextn_predict_layers"] as? Int) ?? 0
    guard declared > 0 else { return false }
    return checkpointTensorNames(in: directory).contains { $0.contains("mtp.") }
}

/// Whether Forge can drive native MTP for this checkpoint: a head inside the
/// shards, or a compatible sidecar drafter.
func qwenNativeMTPAvailable(for directory: URL) -> Bool {
    qwenCheckpointHasNativeMTPHead(at: directory) || qwenMTPDrafterDirectory(for: directory) != nil
}

/// Tensor names across the checkpoint without loading any weights: the
/// safetensors index when present, otherwise each shard's JSON header.
private func checkpointTensorNames(in directory: URL) -> [String] {
    let indexURL = directory.appending(component: "model.safetensors.index.json")
    if let data = try? Data(contentsOf: indexURL),
        let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let weightMap = index["weight_map"] as? [String: Any]
    {
        return Array(weightMap.keys)
    }
    guard let shards = try? safetensorsShardURLs(in: directory) else { return [] }
    return shards.flatMap(safetensorsHeaderTensorNames)
}

private func safetensorsHeaderTensorNames(_ url: URL) -> [String] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else {
        return []
    }
    let length = lengthData.withUnsafeBytes {
        UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
    }
    guard length > 0, length < 256 * 1024 * 1024,
        let headerData = try? handle.read(upToCount: Int(length)),
        let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
    else { return [] }
    return header.keys.filter { $0 != "__metadata__" }
}

private func qwenConfiguration(at directory: URL) -> [String: Any]? {
    let url = directory.appending(component: "config.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func qwenTextConfiguration(in configuration: [String: Any]) -> [String: Any] {
    configuration["text_config"] as? [String: Any] ?? configuration
}

private func qwenModelType(in configuration: [String: Any]) -> String {
    if let modelType = configuration["model_type"] as? String { return modelType }
    return qwenTextConfiguration(in: configuration)["model_type"] as? String ?? ""
}

/// Sorted shard URLs under `modelDirectory` (deterministic load order).
func safetensorsShardURLs(in modelDirectory: URL) throws -> [URL] {
    var shardURLs: [URL] = []
    guard let enumerator = FileManager.default.enumerator(
        at: modelDirectory, includingPropertiesForKeys: nil)
    else { throw WeightLoadError.unreadableModelDirectory(modelDirectory) }
    for case let url as URL in enumerator {
        if url.pathExtension == "safetensors" {
            shardURLs.append(url)
        }
    }
    shardURLs.sort { $0.path < $1.path }
    guard !shardURLs.isEmpty else { throw WeightLoadError.noSafetensors }
    return shardURLs
}

/// Translate the standalone Qwen MTP checkpoint namespace into the module
/// namespace owned by `Qwen35Model`. Accept already-qualified keys so a future
/// checkpoint can be packaged either bare or pre-namespaced.
func qwenMTPWeightKey(_ rawKey: String) -> String {
    if rawKey.hasPrefix("language_model.mtp.") {
        return rawKey
    }
    if rawKey.hasPrefix("mtp.") {
        return "language_model.mtp.0." + rawKey.dropFirst(4)
    }
    return "language_model.mtp.0." + rawKey
}

/// Load model weights with Forge's materialization policy.
func loadWeights(
    modelDirectory: URL,
    model: BaseLanguageModel,
    policy: WeightLoadPolicy,
    qwenMTPDrafterDirectory: URL? = nil,
    quantization: BaseConfiguration.Quantization? = nil,
    perLayerQuantization: BaseConfiguration.PerLayerQuantization? = nil,
    progress: (@Sendable (Double) -> Void)? = nil
) throws {
    var weights = [String: MLXArray]()
    var metadata = [String: String]()
    let shardURLs = try safetensorsShardURLs(in: modelDirectory)
    let shardCount = Double(shardURLs.count)

    for (index, url) in shardURLs.enumerated() {
        try Task.checkCancellation()
        let (shardWeights, shardMetadata) = try loadArraysAndMetadata(url: url)
        for (key, value) in shardWeights {
            guard weights[key] == nil else {
                throw WeightLoadError.duplicateTensor(key, url)
            }
            weights[key] = value
        }
        if metadata.isEmpty {
            metadata = shardMetadata
        }

        if policy == .boundedEager {
            eval(Array(shardWeights.values))
        }

        progress?(Double(index + 1) / shardCount)
    }

    // The AEON target and native MTP head are separate repositories. Merge
    // the sidecar's bare keys into the exact Qwen module namespace before the
    // single verified module update.
    if let qwenMTPDrafterDirectory {
        for url in try safetensorsShardURLs(in: qwenMTPDrafterDirectory) {
            let (draftWeights, _) = try loadArraysAndMetadata(url: url)
            for (rawKey, value) in draftWeights {
                let key = qwenMTPWeightKey(rawKey)
                guard weights[key] == nil else {
                    throw WeightLoadError.duplicateTensor(key, url)
                }
                weights[key] = value
            }
            if policy == .boundedEager { eval(Array(draftWeights.values)) }
        }
    }

    try Task.checkCancellation()
    weights = model.sanitize(weights: weights, metadata: metadata)

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

    let parameters = ModuleParameters.unflattened(weights)
    try model.update(parameters: parameters, verify: [.all])
    try Task.checkCancellation()

    switch policy {
    case .eager, .boundedEager:
        eval(model)
    case .deferred:
        break
    }
}

/// Loads an LLM from a local directory using Forge's weight materialization policy.
func loadLLMContainerWithPolicy(
    modelDirectory: URL,
    policy: WeightLoadPolicy,
    tokenizerLoader: any TokenizerLoader,
    progress: (@Sendable (Double) -> Void)? = nil
) async throws -> (ModelContainer, WeightLoadPolicy) {
    let configuration = ResolvedModelConfiguration(directory: modelDirectory)
    let configurationURL = modelDirectory.appending(component: "config.json")
    let configData: Data
    do {
        configData = try Data(contentsOf: configurationURL)
    } catch {
        throw ModelFactoryError.configurationFileError(
            configurationURL.lastPathComponent, configuration.name, error)
    }

    let baseConfig: BaseConfiguration
    do {
        baseConfig = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
    } catch let error as DecodingError {
        throw ModelFactoryError.configurationDecodingError(
            configurationURL.lastPathComponent, configuration.name, error)
    }

    // Keep the native MTP head while the model is built and sanitized: packaged
    // inside the checkpoint (Qwen3.8) or merged from a sidecar drafter.
    let mtpDirectory = qwenMTPDrafterDirectory(for: modelDirectory)
    if mtpDirectory != nil || qwenCheckpointHasNativeMTPHead(at: modelDirectory) {
        QwenNativeMTPConfig.retainWeights = true
    }
    defer { QwenNativeMTPConfig.resetRetainWeights() }

    let model: LanguageModel
    do {
        model = try await LLMTypeRegistry.shared.createModel(
            configuration: configData, modelType: baseConfig.modelType)
    } catch let error as DecodingError {
        throw ModelFactoryError.configurationDecodingError(
            configurationURL.lastPathComponent, configuration.name, error)
    } catch let error as ModelFactoryError {
        throw error
    }

    var eosTokenIds = Set(baseConfig.eosTokenIds?.values ?? [])
    let generationConfigURL = modelDirectory.appending(component: "generation_config.json")
    let generationConfig: GenerationConfigFile? =
        if let generationData = try? Data(contentsOf: generationConfigURL) {
            try? JSONDecoder.json5().decode(GenerationConfigFile.self, from: generationData)
        } else {
            nil
        }
    if let genEosIds = generationConfig?.eosTokenIds?.values {
        eosTokenIds = Set(genEosIds)
    }

    var mutableConfiguration = configuration
    mutableConfiguration.eosTokenIds = eosTokenIds
    mutableConfiguration.stopStrings.formUnion(generationConfig?.stopStrings ?? [])
    if mutableConfiguration.toolCallFormat == nil {
        mutableConfiguration.toolCallFormat = ToolCallFormat.infer(
            from: baseConfig.modelType, configData: configData)
    }
    let tokenizerDirectory = mutableConfiguration.tokenizerDirectory

    async let tokenizerTask = tokenizerLoader.load(from: tokenizerDirectory)

    try loadWeights(
        modelDirectory: modelDirectory,
        model: model,
        policy: policy,
        qwenMTPDrafterDirectory: mtpDirectory,
        perLayerQuantization: baseConfig.perLayerQuantization,
        progress: progress)

    let tokenizer = try await tokenizerTask

    let messageGenerator =
        if let model = model as? LLMModel {
            model.messageGenerator(tokenizer: tokenizer)
        } else {
            DefaultMessageGenerator()
        }

    let tokenizerSource: TokenizerSource? =
        tokenizerDirectory == modelDirectory ? nil : .directory(tokenizerDirectory)
    let modelConfig = ModelConfiguration(
        directory: modelDirectory,
        tokenizerSource: tokenizerSource,
        defaultPrompt: mutableConfiguration.defaultPrompt,
        extraEOSTokens: mutableConfiguration.extraEOSTokens,
        stopStrings: mutableConfiguration.stopStrings,
        eosTokenIds: mutableConfiguration.eosTokenIds,
        toolCallFormat: ChatTemplateSniffer.toolCallFormat(modelDirectory: modelDirectory)
            ?? mutableConfiguration.toolCallFormat)

    let processor = ForgeLLMInputProcessor(
        tokenizer: tokenizer,
        messageGenerator: messageGenerator)

    let context = ModelContext(
        configuration: modelConfig, model: model, processor: processor,
        tokenizer: tokenizer)
    return (ModelContainer(context: context), policy)
}
