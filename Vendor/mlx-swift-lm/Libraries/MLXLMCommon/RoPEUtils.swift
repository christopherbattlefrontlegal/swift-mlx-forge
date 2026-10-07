//
//  RoPEUtils.swift
//  mlx-swift-lm
//
//  Created by John Mai on 2025/8/11.
//

import Foundation
import MLX
import MLXNN

private let yarnTypes: Set<String> = ["yarn", "deepseek_yarn", "telechat3-yarn"]
private let supportedRoPETypes: Set<String> = Set([
    "default", "linear", "proportional", "llama3", "longrope", "mrope",
]).union(yarnTypes)

private func ropeType(in scalingConfig: [String: StringOrNumber]?) -> String? {
    guard let value = scalingConfig?["type"] ?? scalingConfig?["rope_type"] else { return nil }
    guard case .string(let ropeType) = value else { return nil }
    return ropeType
}

private func invalidRoPEConfiguration(_ context: String, _ message: String) -> ModelFactoryError {
    .invalidConfiguration("\(context): \(message)")
}

public func validateRoPEConfiguration(
    _ scalingConfig: [String: StringOrNumber]?,
    context: String = "rope_scaling",
    supportedTypes: Set<String>? = nil
) throws {
    guard let scalingConfig else { return }
    let supportedTypes = supportedTypes ?? supportedRoPETypes

    if let typeValue = scalingConfig["type"] ?? scalingConfig["rope_type"] {
        guard case .string(let ropeType) = typeValue else {
            throw invalidRoPEConfiguration(context, "type must be a string")
        }
        guard supportedTypes.contains(ropeType) else {
            throw invalidRoPEConfiguration(context, "unsupported type '\(ropeType)'")
        }
    }

    if let factor = scalingConfig["factor"], factor.asFloat() == nil {
        throw invalidRoPEConfiguration(context, "factor must be numeric")
    }

    switch ropeType(in: scalingConfig) {
    case "llama3":
        for key in ["low_freq_factor", "high_freq_factor", "original_max_position_embeddings"] {
            if let value = scalingConfig[key], value.asFloat() == nil {
                throw invalidRoPEConfiguration(context, "\(key) must be numeric")
            }
        }
    case "longrope":
        guard scalingConfig["original_max_position_embeddings"]?.asInt() != nil else {
            throw invalidRoPEConfiguration(
                context, "longrope requires original_max_position_embeddings")
        }
        guard scalingConfig["short_factor"]?.asFloats() != nil else {
            throw invalidRoPEConfiguration(context, "longrope requires numeric short_factor")
        }
        guard scalingConfig["long_factor"]?.asFloats() != nil else {
            throw invalidRoPEConfiguration(context, "longrope requires numeric long_factor")
        }
    case "mrope":
        try validateMROPESection(scalingConfig, context: context)
    default:
        break
    }
}

public func validateMROPESection(
    _ scalingConfig: [String: StringOrNumber]?,
    context: String = "rope_scaling"
) throws {
    guard let section = scalingConfig?["mrope_section"]?.asInts() else {
        throw invalidRoPEConfiguration(context, "mrope_section must be an array of integers")
    }
    guard section.count == 3, section.allSatisfy({ $0 > 0 }) else {
        throw invalidRoPEConfiguration(
            context, "mrope_section must contain three positive integers")
    }
}

public class Llama3RoPE: Module, OffsetLayer, ArrayOffsetLayer {
    let dims: Int
    let maxPositionEmbeddings: Int
    let traditional: Bool
    let _freqs: MLXArray

    init(
        dims: Int,
        maxPositionEmbeddings: Int = 2048,
        traditional: Bool = false,
        base: Float = 10000,
        scalingConfig: [String: StringOrNumber]? = nil
    ) {
        self.dims = dims
        self.maxPositionEmbeddings = maxPositionEmbeddings
        self.traditional = traditional

        guard let scalingConfig = scalingConfig else {
            fatalError("Llama3RoPE requires scaling_config")
        }

        let factor = scalingConfig["factor"]?.asFloat() ?? 1.0
        let lowFreqFactor = scalingConfig["low_freq_factor"]?.asFloat() ?? 1.0
        let highFreqFactor = scalingConfig["high_freq_factor"]?.asFloat() ?? 4.0
        let oldContextLen = scalingConfig["original_max_position_embeddings"]?.asFloat() ?? 8192.0

        let lowFreqWavelen = oldContextLen / lowFreqFactor
        let highFreqWavelen = oldContextLen / highFreqFactor

        let indices = MLXArray(stride(from: 0, to: dims, by: 2))
        var frequencies = MLX.pow(base, indices / Float(dims))
        let wavelens = 2 * Float.pi * frequencies

        frequencies = MLX.where(
            wavelens .> MLXArray(lowFreqWavelen),
            frequencies * factor,
            frequencies
        )

        let isMediumFreq = MLX.logicalAnd(
            wavelens .> MLXArray(highFreqWavelen),
            wavelens .< MLXArray(lowFreqWavelen)
        )

        let smoothFactors =
            (oldContextLen / wavelens - lowFreqFactor) / (highFreqFactor - lowFreqFactor)
        let smoothFreqs = frequencies / ((1 - smoothFactors) / factor + smoothFactors)

        self._freqs = MLX.where(isMediumFreq, smoothFreqs, frequencies)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        MLXFast.RoPE(
            x,
            dimensions: dims,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: _freqs
        )
    }

    public func callAsFunction(_ x: MLXArray, offset: MLXArray) -> MLXArray {
        MLXFast.RoPE(
            x,
            dimensions: dims,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: _freqs
        )
    }

}

public class ProportionalRoPE: Module, OffsetLayer, ArrayOffsetLayer {
    let dims: Int
    let traditional: Bool
    let rotatedDims: Int
    let _freqs: MLXArray?

    init(
        dims: Int,
        traditional: Bool = false,
        base: Float = 10_000,
        scalingConfig: [String: StringOrNumber]? = nil
    ) {
        self.dims = dims
        self.traditional = traditional

        let factor = scalingConfig?["factor"]?.asFloat() ?? 1.0
        let partialRotaryFactor = scalingConfig?["partial_rotary_factor"]?.asFloat() ?? 1.0
        let ropeAngles = Int(partialRotaryFactor * Float(dims) / 2.0)
        self.rotatedDims = 2 * ropeAngles

        if rotatedDims > 0 {
            let exponents =
                MLXArray(stride(from: 0, to: rotatedDims, by: 2)).asType(.float32) / Float(dims)
            self._freqs = factor * MLX.pow(base, exponents)
        } else {
            self._freqs = nil
        }

        super.init()
    }

    public func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        guard rotatedDims > 0, let _freqs else {
            return x
        }

        let half = dims / 2
        let rotatedHalf = rotatedDims / 2

        let head: MLXArray
        let tail: MLXArray?
        if x.shape[x.ndim - 1] > dims {
            let parts = split(x, indices: [dims], axis: -1)
            head = parts[0]
            tail = parts[1]
        } else {
            head = x
            tail = nil
        }

        let headParts = split(head, indices: [half], axis: -1)
        var left = headParts[0]
        var right = headParts[1]

        let leftParts = split(left, indices: [rotatedHalf], axis: -1)
        let rightParts = split(right, indices: [rotatedHalf], axis: -1)
        var rotated = concatenated([leftParts[0], rightParts[0]], axis: -1)
        rotated = MLXFast.RoPE(
            rotated,
            dimensions: rotatedDims,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: _freqs
        )

        let rotatedParts = split(rotated, indices: [rotatedHalf], axis: -1)
        left = concatenated([rotatedParts[0], leftParts[1]], axis: -1)
        right = concatenated([rotatedParts[1], rightParts[1]], axis: -1)
        let updatedHead = concatenated([left, right], axis: -1)

        if let tail {
            return concatenated([updatedHead, tail], axis: -1)
        } else {
            return updatedHead
        }
    }

    public func callAsFunction(_ x: MLXArray, offset: MLXArray) -> MLXArray {
        guard rotatedDims > 0, let _freqs else {
            return x
        }

        let half = dims / 2
        let rotatedHalf = rotatedDims / 2

        let head: MLXArray
        let tail: MLXArray?
        if x.shape[x.ndim - 1] > dims {
            let parts = split(x, indices: [dims], axis: -1)
            head = parts[0]
            tail = parts[1]
        } else {
            head = x
            tail = nil
        }

        let headParts = split(head, indices: [half], axis: -1)
        var left = headParts[0]
        var right = headParts[1]

        let leftParts = split(left, indices: [rotatedHalf], axis: -1)
        let rightParts = split(right, indices: [rotatedHalf], axis: -1)
        var rotated = concatenated([leftParts[0], rightParts[0]], axis: -1)
        rotated = MLXFast.RoPE(
            rotated,
            dimensions: rotatedDims,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: _freqs
        )

        let rotatedParts = split(rotated, indices: [rotatedHalf], axis: -1)
        left = concatenated([rotatedParts[0], leftParts[1]], axis: -1)
        right = concatenated([rotatedParts[1], rightParts[1]], axis: -1)
        let updatedHead = concatenated([left, right], axis: -1)

        if let tail {
            return concatenated([updatedHead, tail], axis: -1)
        } else {
            return updatedHead
        }
    }
}

/// YaRN scaling parameters as declared in `rope_scaling` / `rope_parameters`.
///
/// `init?(scalingConfig:)` returns nil for configurations that do not declare a
/// YaRN type, so callers fall back to plain RoPE without re-parsing the dictionary.
public struct YarnRoPEParameters: Sendable, Equatable {
    public var scalingFactor: Float
    public var originalMaxPositionEmbeddings: Int
    public var betaFast: Float
    public var betaSlow: Float
    public var mscale: Float
    public var mscaleAllDim: Float
    /// Explicit `attention_factor`. When present it replaces the mscale-derived
    /// value, matching the reference implementation.
    public var attentionFactor: Float?

    public init(
        scalingFactor: Float,
        originalMaxPositionEmbeddings: Int,
        betaFast: Float = 32,
        betaSlow: Float = 1,
        mscale: Float = 1,
        mscaleAllDim: Float = 0,
        attentionFactor: Float? = nil
    ) {
        self.scalingFactor = scalingFactor
        self.originalMaxPositionEmbeddings = originalMaxPositionEmbeddings
        self.betaFast = betaFast
        self.betaSlow = betaSlow
        self.mscale = mscale
        self.mscaleAllDim = mscaleAllDim
        self.attentionFactor = attentionFactor
    }

    public init?(scalingConfig: [String: StringOrNumber]?) {
        guard let scalingConfig, let type = ropeType(in: scalingConfig), yarnTypes.contains(type)
        else { return nil }
        self.scalingFactor = scalingConfig["factor"]?.asFloat() ?? 32.0
        self.originalMaxPositionEmbeddings =
            scalingConfig["original_max_position_embeddings"]?.asInt() ?? 4096
        self.betaFast = scalingConfig["beta_fast"]?.asFloat() ?? 32.0
        self.betaSlow = scalingConfig["beta_slow"]?.asFloat() ?? 1.0
        self.mscale = scalingConfig["mscale"]?.asFloat() ?? 1.0
        self.mscaleAllDim = scalingConfig["mscale_all_dim"]?.asFloat() ?? 0.0
        self.attentionFactor = scalingConfig["attention_factor"]?.asFloat()
    }

    /// Scale applied to the rotated query and key dimensions.
    public var attentionScale: Float {
        if let attentionFactor {
            return attentionFactor
        }
        func mscaleValue(_ mscale: Float) -> Float {
            if scalingFactor <= 1 {
                return 1.0
            }
            return 0.1 * mscale * log(scalingFactor) + 1.0
        }
        return mscaleValue(mscale) / mscaleValue(mscaleAllDim)
    }

    /// Per-dimension rotary frequencies after NTK-by-parts interpolation. These
    /// are the `freqs` that `MLXFast.RoPE` consumes: angle = position / freq.
    public func frequencies(dimensions: Int, base: Float) -> MLXArray {
        func correctionDim(numRotations: Float) -> Float {
            return Float(dimensions)
                * log(Float(originalMaxPositionEmbeddings) / (numRotations * 2 * Float.pi))
                / (2 * log(base))
        }
        let low = max(Int(floor(correctionDim(numRotations: betaFast))), 0)
        let high = min(Int(ceil(correctionDim(numRotations: betaSlow))), dimensions - 1)

        var rampMax = Float(high)
        if Float(low) == rampMax {
            rampMax += 0.001
        }
        let linearFunc =
            (MLXArray(0 ..< (dimensions / 2)).asType(.float32) - Float(low)) / (rampMax - Float(low))
        let freqMask = 1.0 - clip(linearFunc, min: 0, max: 1)

        let freqExtra = pow(
            base,
            MLXArray(stride(from: 0, to: dimensions, by: 2)).asType(.float32)
                / dimensions)
        let freqInter = scalingFactor * freqExtra
        return (freqInter * freqExtra) / (freqInter * freqMask + freqExtra * (1 - freqMask))
    }
}

public class YarnRoPE: Module, OffsetLayer, ArrayOffsetLayer {
    let dimensions: Int
    let traditional: Bool

    private let _mscale: Float
    private let _freqs: MLXArray

    public convenience init(
        dimensions: Int,
        traditional: Bool = false,
        maxPositionEmbeddings: Int = 2048,
        base: Float = 10000,
        scalingFactor: Float = 1.0,
        originalMaxPositionEmbeddings: Int = 4096,
        betaFast: Float = 32,
        betaSlow: Float = 1,
        mscale: Float = 1,
        mscaleAllDim: Float = 0,
        attentionFactor: Float? = nil
    ) {
        self.init(
            dimensions: dimensions,
            traditional: traditional,
            base: base,
            parameters: YarnRoPEParameters(
                scalingFactor: scalingFactor,
                originalMaxPositionEmbeddings: originalMaxPositionEmbeddings,
                betaFast: betaFast,
                betaSlow: betaSlow,
                mscale: mscale,
                mscaleAllDim: mscaleAllDim,
                attentionFactor: attentionFactor))
    }

    public init(
        dimensions: Int,
        traditional: Bool = false,
        base: Float = 10000,
        parameters: YarnRoPEParameters
    ) {
        precondition(dimensions % 2 == 0, "Dimensions must be even")

        self.dimensions = dimensions
        self.traditional = traditional
        self._mscale = parameters.attentionScale
        self._freqs = parameters.frequencies(dimensions: dimensions, base: base)
    }

    public func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        // "copy" of x as we are going to write through it and don't want to update
        // through the reference
        // https://github.com/ml-explore/mlx-swift/issues/364
        var x = x
        if _mscale != 1.0 {
            x = x[0..., .ellipsis]
            x[.ellipsis, 0 ..< dimensions] *= _mscale
        }

        return MLXFast.RoPE(
            x,
            dimensions: dimensions,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: self._freqs
        )
    }

    public func callAsFunction(_ x: MLXArray, offset: MLXArray) -> MLXArray {
        var x = x
        if _mscale != 1.0 {
            x = x[0..., .ellipsis]
            x[.ellipsis, 0 ..< dimensions] *= _mscale
        }

        return MLXFast.RoPE(
            x,
            dimensions: dimensions,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: self._freqs
        )
    }

}

/// Keys that describe position scaling, as opposed to the base rotary geometry
/// (`rope_theta`, `partial_rotary_factor`, `mrope_section`, `mrope_interleaved`).
private let ropeScalingKeys: Set<String> = [
    "type", "rope_type", "factor", "original_max_position_embeddings", "attention_factor",
    "beta_fast", "beta_slow", "mscale", "mscale_all_dim", "truncate",
    "low_freq_factor", "high_freq_factor", "short_factor", "long_factor",
]

/// Folds a legacy `rope_scaling` block into transformers-v5 style `rope_parameters`.
///
/// Checkpoints converted across the v5 schema change can carry both: `rope_parameters`
/// describing the base geometry with `type: default`, and `rope_scaling` declaring the
/// scaling (for example YaRN) that the converter never folded in. The legacy block is
/// applied only when `rope_parameters` declares no non-default type of its own; an
/// explicit type in `rope_parameters` is authoritative. `rope_type` is normalised to
/// `type` in the result.
public func resolveRoPEParameters(
    _ ropeParameters: [String: StringOrNumber],
    legacyScaling: [String: StringOrNumber]?
) -> [String: StringOrNumber] {
    var resolved = ropeParameters
    if resolved["type"] == nil, let ropeType = resolved["rope_type"] {
        resolved["type"] = ropeType
    }
    guard let legacyScaling,
        (ropeType(in: resolved) ?? "default") == "default",
        let legacyType = ropeType(in: legacyScaling),
        legacyType != "default"
    else {
        return resolved
    }
    for (key, value) in legacyScaling where ropeScalingKeys.contains(key) {
        resolved[key] = value
    }
    resolved["type"] = .string(legacyType)
    return resolved
}

public typealias RoPELayer = OffsetLayer & ArrayOffsetLayer

public func initializeRope(
    dims: Int,
    base: Float,
    traditional: Bool,
    scalingConfig: [String: StringOrNumber]?,
    maxPositionEmbeddings: Int?
) -> RoPELayer {
    let ropeType: String = {
        if let config = scalingConfig,
            let typeValue = config["type"] ?? config["rope_type"],
            case .string(let s) = typeValue
        {
            return s
        }
        return "default"
    }()

    if ropeType == "default" || ropeType == "linear" {
        let scale: Float
        if ropeType == "linear", let factor = scalingConfig?["factor"]?.asFloat() {
            scale = 1 / factor
        } else {
            scale = 1.0
        }
        return RoPE(dimensions: dims, traditional: traditional, base: base, scale: scale)
    } else if ropeType == "proportional" {
        return ProportionalRoPE(
            dims: dims,
            traditional: traditional,
            base: base,
            scalingConfig: scalingConfig
        )
    } else if ropeType == "llama3" {
        return Llama3RoPE(
            dims: dims,
            maxPositionEmbeddings: maxPositionEmbeddings ?? 2048,
            traditional: traditional,
            base: base,
            scalingConfig: scalingConfig
        )
    } else if let parameters = YarnRoPEParameters(scalingConfig: scalingConfig) {
        return YarnRoPE(
            dimensions: dims,
            traditional: traditional,
            base: base,
            parameters: parameters
        )
    } else if ropeType == "longrope" {
        guard let config = scalingConfig else {
            fatalError("longrope requires scaling_config")
        }
        guard let origMax = config["original_max_position_embeddings"]?.asInt() else {
            fatalError("longrope requires original_max_position_embeddings")
        }
        guard let shortFactor = config["short_factor"]?.asFloats() else {
            fatalError("longrope requires short_factor")
        }
        guard let longFactor = config["long_factor"]?.asFloats() else {
            fatalError("longrope requires long_factor")
        }

        return SuScaledRoPE(
            dimensions: dims,
            base: base,
            maxPositionEmbeddings: maxPositionEmbeddings ?? 131072,
            originalMaxPositionEmbeddings: origMax,
            shortFactor: shortFactor,
            longFactor: longFactor
        )
    } else if ropeType == "mrope" {
        // MRoPE returns basic RoPE here. The actual multi-modal rotary embedding logic
        // (applying different embeddings per modality) is handled in the attention layer
        // of multimodal models like Qwen2VL, not in the RoPE module itself.
        if let config = scalingConfig,
            let mropeSection = config["mrope_section"]?.asInts()
        {
            precondition(
                mropeSection.count == 3,
                "MRoPE currently only supports 3 sections, got \(mropeSection.count)"
            )
        }
        return RoPE(dimensions: dims, traditional: traditional, base: base, scale: 1.0)
    } else {
        fatalError("Unsupported RoPE type: \(ropeType)")
    }
}
