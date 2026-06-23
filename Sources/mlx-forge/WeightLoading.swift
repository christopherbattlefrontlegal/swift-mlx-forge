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

    var errorDescription: String? {
        switch self {
        case .noSafetensors: "No .safetensors shards found in the model folder."
        }
    }
}

/// Sorted shard URLs under `modelDirectory` (deterministic load order).
func safetensorsShardURLs(in modelDirectory: URL) throws -> [URL] {
    var shardURLs: [URL] = []
    let enumerator = FileManager.default.enumerator(
        at: modelDirectory, includingPropertiesForKeys: nil)!
    for case let url as URL in enumerator {
        if url.pathExtension == "safetensors" {
            shardURLs.append(url)
        }
    }
    shardURLs.sort { $0.path < $1.path }
    guard !shardURLs.isEmpty else { throw WeightLoadError.noSafetensors }
    return shardURLs
}

/// Load model weights with Forge's materialization policy.
func loadWeights(
    modelDirectory: URL,
    model: BaseLanguageModel,
    policy: WeightLoadPolicy,
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
    var configuration = ResolvedModelConfiguration(directory: modelDirectory)
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
    if let generationData = try? Data(contentsOf: generationConfigURL),
        let generationConfig = try? JSONDecoder.json5().decode(
            GenerationConfigFile.self, from: generationData),
        let genEosIds = generationConfig.eosTokenIds?.values
    {
        eosTokenIds = Set(genEosIds)
    }

    let toolCallFormat =
        configuration.toolCallFormat
        ?? ToolCallFormat.infer(from: baseConfig.modelType, configData: configData)
    let defaultPrompt = configuration.defaultPrompt
    let extraEOSTokens = configuration.extraEOSTokens
    let tokenizerDirectory = configuration.tokenizerDirectory

    async let tokenizerTask = tokenizerLoader.load(from: tokenizerDirectory)

    try loadWeights(
        modelDirectory: modelDirectory,
        model: model,
        policy: policy,
        perLayerQuantization: baseConfig.perLayerQuantization,
        progress: progress)

    let tokenizer = try await tokenizerTask

    let messageGenerator =
        if let model = model as? LLMModel {
            model.messageGenerator(tokenizer: tokenizer)
        } else {
            DefaultMessageGenerator()
        }

    let modelConfig = ModelConfiguration(
        directory: modelDirectory,
        defaultPrompt: defaultPrompt,
        extraEOSTokens: extraEOSTokens,
        eosTokenIds: eosTokenIds,
        toolCallFormat: toolCallFormat)

    let processor = ForgeLLMInputProcessor(
        tokenizer: tokenizer, configuration: modelConfig,
        messageGenerator: messageGenerator)

    let context = ModelContext(
        configuration: modelConfig, model: model, processor: processor,
        tokenizer: tokenizer)
    return (ModelContainer(context: context), policy)
}