// Port of https://github.com/Blaizzy/mlx-vlm/tree/main/mlx_vlm/models/inkling

import Foundation
import MLX
import MLXLMCommon
import MLXNN

public struct InklingConfiguration: Codable, Sendable {
    public struct TextConfiguration: Codable, Sendable {
        var hiddenSize = 4096, hiddenLayers = 42, vocabularySize = 201_024
        var unpaddedVocabularySize: Int?
        var rmsNormEps: Float = 1e-6
        var tieWordEmbeddings = false, useEmbedNorm = true
        var logitsMupWidthMultiplier: Float = 1
        var attentionHeads = 32, kvHeads = 8, headDim = 128
        var swaAttentionHeads = 32, swaKVHeads = 8, swaHeadDim = 128
        var slidingWindowSize = 512
        var localLayerIDs: [Int]?, layerTypes: [String]?
        var relativeDimensions = 16, relativeExtent = 1024
        var logScalingFloor: Int?
        var logScalingAlpha: Float = 0.1
        var shortConvKernelSize = 4, denseMLPIndex = 0
        var mlpLayerTypes: [String]?
        var intermediateSize = 2048, denseIntermediateSize: Int?
        var routedExperts = 256, expertsPerToken = 6, sharedExperts = 2
        var routeScale: Float = 8

        enum CodingKeys: String, CodingKey {
            case hiddenSize="hidden_size", hiddenLayers="num_hidden_layers", vocabularySize="vocab_size"
            case unpaddedVocabularySize="unpadded_vocab_size", rmsNormEps="rms_norm_eps"
            case tieWordEmbeddings="tie_word_embeddings", useEmbedNorm="use_embed_norm"
            case logitsMupWidthMultiplier="logits_mup_width_multiplier"
            case attentionHeads="num_attention_heads", kvHeads="num_key_value_heads", headDim="head_dim"
            case swaAttentionHeads="swa_num_attention_heads", swaKVHeads="swa_num_key_value_heads", swaHeadDim="swa_head_dim"
            case slidingWindowSize="sliding_window_size", localLayerIDs="local_layer_ids", layerTypes="layer_types"
            case relativeDimensions="d_rel", relativeExtent="rel_extent"
            case logScalingFloor="log_scaling_n_floor", logScalingAlpha="log_scaling_alpha"
            case shortConvKernelSize="sconv_kernel_size", denseMLPIndex="dense_mlp_idx", mlpLayerTypes="mlp_layer_types"
            case intermediateSize="intermediate_size", denseIntermediateSize="dense_intermediate_size"
            case routedExperts="n_routed_experts", expertsPerToken="num_experts_per_tok"
            case sharedExperts="n_shared_experts", routeScale="route_scale"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hiddenSize = try c.decodeIfPresent(Int.self, forKey:.hiddenSize) ?? hiddenSize
            hiddenLayers = try c.decodeIfPresent(Int.self, forKey:.hiddenLayers) ?? hiddenLayers
            vocabularySize = try c.decodeIfPresent(Int.self, forKey:.vocabularySize) ?? vocabularySize
            unpaddedVocabularySize = try c.decodeIfPresent(Int.self, forKey:.unpaddedVocabularySize)
            rmsNormEps = try c.decodeIfPresent(Float.self, forKey:.rmsNormEps) ?? rmsNormEps
            tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey:.tieWordEmbeddings) ?? tieWordEmbeddings
            useEmbedNorm = try c.decodeIfPresent(Bool.self, forKey:.useEmbedNorm) ?? useEmbedNorm
            logitsMupWidthMultiplier = try c.decodeIfPresent(Float.self, forKey:.logitsMupWidthMultiplier) ?? logitsMupWidthMultiplier
            attentionHeads = try c.decodeIfPresent(Int.self, forKey:.attentionHeads) ?? attentionHeads
            kvHeads = try c.decodeIfPresent(Int.self, forKey:.kvHeads) ?? attentionHeads
            headDim = try c.decodeIfPresent(Int.self, forKey:.headDim) ?? headDim
            swaAttentionHeads = try c.decodeIfPresent(Int.self, forKey:.swaAttentionHeads) ?? attentionHeads
            swaKVHeads = try c.decodeIfPresent(Int.self, forKey:.swaKVHeads) ?? kvHeads
            swaHeadDim = try c.decodeIfPresent(Int.self, forKey:.swaHeadDim) ?? headDim
            slidingWindowSize = try c.decodeIfPresent(Int.self, forKey:.slidingWindowSize) ?? slidingWindowSize
            localLayerIDs = try c.decodeIfPresent([Int].self, forKey:.localLayerIDs)
            layerTypes = try c.decodeIfPresent([String].self, forKey:.layerTypes)
            relativeDimensions = try c.decodeIfPresent(Int.self, forKey:.relativeDimensions) ?? relativeDimensions
            relativeExtent = try c.decodeIfPresent(Int.self, forKey:.relativeExtent) ?? relativeExtent
            logScalingFloor = try c.decodeIfPresent(Int.self, forKey:.logScalingFloor)
            logScalingAlpha = try c.decodeIfPresent(Float.self, forKey:.logScalingAlpha) ?? logScalingAlpha
            shortConvKernelSize = try c.decodeIfPresent(Int.self, forKey:.shortConvKernelSize) ?? shortConvKernelSize
            denseMLPIndex = try c.decodeIfPresent(Int.self, forKey:.denseMLPIndex) ?? denseMLPIndex
            mlpLayerTypes = try c.decodeIfPresent([String].self, forKey:.mlpLayerTypes)
            intermediateSize = try c.decodeIfPresent(Int.self, forKey:.intermediateSize) ?? intermediateSize
            denseIntermediateSize = try c.decodeIfPresent(Int.self, forKey:.denseIntermediateSize)
            routedExperts = try c.decodeIfPresent(Int.self, forKey:.routedExperts) ?? routedExperts
            expertsPerToken = try c.decodeIfPresent(Int.self, forKey:.expertsPerToken) ?? expertsPerToken
            sharedExperts = try c.decodeIfPresent(Int.self, forKey:.sharedExperts) ?? sharedExperts
            routeScale = try c.decodeIfPresent(Float.self, forKey:.routeScale) ?? routeScale
        }
        func isSliding(_ layer:Int)->Bool {
            if let layerTypes { return layerTypes[layer] == "hybrid_sliding" }
            if let localLayerIDs { return localLayerIDs.contains(layer) }
            return (layer + 1) % 6 != 0
        }
        func isDense(_ layer:Int)->Bool {
            if let mlpLayerTypes { return mlpLayerTypes[layer] == "dense" }
            return layer < denseMLPIndex
        }
    }
    let textConfiguration: TextConfiguration
    let modelType: String
    enum CodingKeys:String,CodingKey { case textConfiguration="text_config", modelType="model_type" }
}

private final class InklingShortConvolution: Module {
    let kernelSize:Int, cacheIndex:Int
    @ModuleInfo(key:"conv") var conv:Conv1d
    init(channels:Int,kernelSize:Int,cacheIndex:Int) {
        self.kernelSize=kernelSize; self.cacheIndex=cacheIndex
        _conv.wrappedValue=Conv1d(inputChannels:channels,outputChannels:channels,kernelSize:kernelSize,groups:channels,bias:false)
    }
    func callAsFunction(_ x:MLXArray,cache:ArraysCache?,residual:MLXArray?=nil)->MLXArray {
        let state=cache?[cacheIndex] ?? MLXArray.zeros([x.dim(0),kernelSize-1,x.dim(-1)],dtype:.float32)
        let xf=x.asType(.float32), padded=concatenated([state,xf],axis:1)
        cache?[cacheIndex]=contiguous(padded[0...,(padded.dim(1)-kernelSize+1)...,0...])
        var out=(conv(padded.asType(conv.weight.dtype)).asType(.float32)+xf).asType(x.dtype)
        if let residual { out=residual+out }
        return out
    }
}

private func inklingBandedMask(_ relative:MLXArray,_ projection:MLXArray,keyLength:Int,window:Int,extent:Int)->MLXArray {
    let b=relative.dim(0),l=relative.dim(1),h=relative.dim(2),offset=keyLength-l
    let logits=matmul(relative,projection).transposed(0,2,1,3)
    let q=MLXArray(Int32(offset)..<Int32(offset+l))[0...,.newAxis], k=MLXArray(Int32(0)..<Int32(keyLength))[.newAxis,0...]
    let distance=q-k
    let gather=broadcast(clip(distance,min:0,max:extent-1)[.newAxis,.newAxis,0...,0...],to:[b,h,l,keyLength])
    var bias=takeAlong(logits,gather,axis:-1)
    bias=MLX.where(distance[.newAxis,.newAxis,0...,0...] .>= extent,MLXArray(0,dtype:relative.dtype),bias)
    var masked=distance .< 0
    if window>0 { masked=masked | (distance .>= window) }
    return MLX.where(masked[.newAxis,.newAxis,0...,0...],MLXArray(-1e30,dtype:relative.dtype),bias)
}

private final class InklingAttention:Module {
    let heads:Int,kvHeads:Int,headDim:Int,relativeDimensions:Int,relativeExtent:Int,window:Int
    let scale:Float,logFloor:Int?,logAlpha:Float
    @ModuleInfo(key:"q_proj") var qProj:Linear
    @ModuleInfo(key:"k_proj") var kProj:Linear
    @ModuleInfo(key:"v_proj") var vProj:Linear
    @ModuleInfo(key:"r_proj") var rProj:Linear
    @ModuleInfo(key:"o_proj") var oProj:Linear
    @ModuleInfo(key:"k_sconv") var keyConv:InklingShortConvolution
    @ModuleInfo(key:"v_sconv") var valueConv:InklingShortConvolution
    @ModuleInfo(key:"q_norm") var queryNorm:RMSNorm
    @ModuleInfo(key:"k_norm") var keyNorm:RMSNorm
    @ParameterInfo(key:"rel_proj") var relativeProjection:MLXArray
    init(_ c:InklingConfiguration.TextConfiguration,layer:Int) {
        let local=c.isSliding(layer)
        heads=local ? c.swaAttentionHeads:c.attentionHeads; kvHeads=local ? c.swaKVHeads:c.kvHeads
        headDim=local ? c.swaHeadDim:c.headDim; relativeDimensions=c.relativeDimensions
        window=local ? c.slidingWindowSize:0; relativeExtent=local ? c.slidingWindowSize:c.relativeExtent
        scale=1/Float(headDim); logFloor=local ? nil:c.logScalingFloor; logAlpha=c.logScalingAlpha
        _qProj.wrappedValue=Linear(c.hiddenSize,heads*headDim,bias:false)
        _kProj.wrappedValue=Linear(c.hiddenSize,kvHeads*headDim,bias:false)
        _vProj.wrappedValue=Linear(c.hiddenSize,kvHeads*headDim,bias:false)
        _rProj.wrappedValue=Linear(c.hiddenSize,heads*relativeDimensions,bias:false)
        _oProj.wrappedValue=Linear(heads*headDim,c.hiddenSize,bias:false)
        _keyConv.wrappedValue=InklingShortConvolution(channels:kvHeads*headDim,kernelSize:c.shortConvKernelSize,cacheIndex:0)
        _valueConv.wrappedValue=InklingShortConvolution(channels:kvHeads*headDim,kernelSize:c.shortConvKernelSize,cacheIndex:1)
        _queryNorm.wrappedValue=RMSNorm(dimensions:headDim,eps:c.rmsNormEps)
        _keyNorm.wrappedValue=RMSNorm(dimensions:headDim,eps:c.rmsNormEps)
        _relativeProjection.wrappedValue=MLXArray.zeros([relativeDimensions,relativeExtent])
    }
    func callAsFunction(_ x:MLXArray,cache:CacheList?)->MLXArray {
        let b=x.dim(0),l=x.dim(1),kv=cache?[0],cc=cache?[1] as? ArraysCache
        var k=keyConv(kProj(x),cache:cc),v=valueConv(vProj(x),cache:cc)
        k=keyNorm(k.reshaped(b,l,kvHeads,headDim)).transposed(0,2,1,3)
        v=v.reshaped(b,l,kvHeads,headDim).transposed(0,2,1,3)
        if let kv { (k,v)=kv.update(keys:k,values:v) }
        if window>0,k.dim(2)>l+window-1 {
            let start=k.dim(2)-l-(window-1); k=k[0...,0...,start...,0...]; v=v[0...,0...,start...,0...]
        }
        var q=queryNorm(qProj(x).reshaped(b,l,heads,headDim)).transposed(0,2,1,3)
        let r=rProj(x).reshaped(b,l,heads,relativeDimensions)
        var mask=inklingBandedMask(r,relativeProjection.asType(x.dtype),keyLength:k.dim(2),window:window,extent:relativeExtent)
        if let floor=logFloor {
            let start=k.dim(2)-l+1
            let pos=MLXArray(Int32(start)..<Int32(start+l)).asType(.float32)
            let tau=(1+logAlpha*log(maximum(pos/Float(floor),MLXArray(1)))).reshaped(1,1,l,1).asType(x.dtype)
            q=q*tau; mask=MLX.where(mask .> -1e29,mask*tau,mask)
        }
        let y=MLXFast.scaledDotProductAttention(queries:q,keys:k,values:v,scale:scale,mask:.array(mask))
        return oProj(y.transposed(0,2,1,3).reshaped(b,l,-1))
    }
}

private class InklingMLP:Module { func callAsFunction(_ x:MLXArray)->MLXArray { fatalError("abstract") } }
private final class InklingDenseMLP:InklingMLP {
    @ModuleInfo(key:"gate_proj") var gate:Linear
    @ModuleInfo(key:"up_proj") var up:Linear
    @ModuleInfo(key:"down_proj") var down:Linear
    @ParameterInfo(key:"global_scale") var globalScale:MLXArray
    init(_ c:InklingConfiguration.TextConfiguration) {
        let n=c.denseIntermediateSize ?? c.intermediateSize
        _gate.wrappedValue=Linear(c.hiddenSize,n,bias:false); _up.wrappedValue=Linear(c.hiddenSize,n,bias:false)
        _down.wrappedValue=Linear(n,c.hiddenSize,bias:false); _globalScale.wrappedValue=MLXArray.ones([1])
    }
    override func callAsFunction(_ x:MLXArray)->MLXArray { down(silu(gate(x))*up(x))*globalScale }
}

private final class InklingSwitchGLU:Module {
    @ModuleInfo(key:"gate_proj") var gateProj:SwitchLinear
    @ModuleInfo(key:"up_proj") var upProj:SwitchLinear
    @ModuleInfo(key:"down_proj") var downProj:SwitchLinear
    @ParameterInfo(key:"gate_scale") var gateScale:MLXArray
    @ParameterInfo(key:"out_scale") var outScale:MLXArray
    init(inputDims:Int,hiddenDims:Int,numExperts:Int) {
        _gateProj.wrappedValue=SwitchLinear(inputDims:inputDims,outputDims:hiddenDims,numExperts:numExperts,bias:false)
        _upProj.wrappedValue=SwitchLinear(inputDims:inputDims,outputDims:hiddenDims,numExperts:numExperts,bias:false)
        _downProj.wrappedValue=SwitchLinear(inputDims:hiddenDims,outputDims:inputDims,numExperts:numExperts,bias:false)
        _gateScale.wrappedValue=MLXArray.ones([numExperts]);_outScale.wrappedValue=MLXArray.ones([numExperts])
    }
    private func perExpert(_ scale:MLXArray,indices:MLXArray,like:MLXArray)->MLXArray {
        let selected=scale[indices].asType(like.dtype)
        return selected.reshaped(selected.shape+Array(repeating:1,count:like.ndim-selected.ndim))
    }
    func callAsFunction(_ input:MLXArray,_ indices:MLXArray)->MLXArray {
        var x=MLX.expandedDimensions(input,axes:[-2,-3])
        let doSort=indices.size >= 64
        var idx=indices,inverseOrder=MLXArray()
        if doSort {(x,idx,inverseOrder)=gatherSort(x:x,indices:indices)}
        let up=upProj(x,idx,sortedIndices:doSort)
        var gate=gateProj(x,idx,sortedIndices:doSort)
        gate=gate*perExpert(gateScale,indices:idx,like:gate)
        x=downProj(compiledSiluProduct(gate,up),idx,sortedIndices:doSort)
        x=x*perExpert(outScale,indices:idx,like:x)
        if doSort {x=scatterUnsort(x:x,invOrder:inverseOrder,shape:indices.shape)}
        return MLX.squeezed(x,axis:-2)
    }
}

private final class InklingSparseMoE:InklingMLP {
    let routedCount:Int,sharedCount:Int,topK:Int,routeScale:Float
    @ParameterInfo(key:"gate_weight") var gateWeight:MLXArray
    @ParameterInfo(key:"e_score_correction_bias") var correction:MLXArray
    @ParameterInfo(key:"global_scale") var globalScale:MLXArray
    @ModuleInfo(key:"switch_mlp") var routed:InklingSwitchGLU
    @ModuleInfo(key:"shared_experts") var shared:SwitchGLU
    init(_ c:InklingConfiguration.TextConfiguration) {
        routedCount=c.routedExperts;sharedCount=c.sharedExperts;topK=c.expertsPerToken;routeScale=c.routeScale
        _gateWeight.wrappedValue=MLXArray.zeros([routedCount+sharedCount,c.hiddenSize])
        _correction.wrappedValue=MLXArray.zeros([routedCount]);_globalScale.wrappedValue=MLXArray.ones([1])
        _routed.wrappedValue=InklingSwitchGLU(inputDims:c.hiddenSize,hiddenDims:c.intermediateSize,numExperts:routedCount)
        _shared.wrappedValue=SwitchGLU(inputDims:c.hiddenSize,hiddenDims:c.intermediateSize,numExperts:sharedCount)
    }
    override func callAsFunction(_ x:MLXArray)->MLXArray {
        let shape=x.shape,flat=x.reshaped(-1,x.dim(-1)),logits=matmul(flat,gateWeight.asType(x.dtype).T)
        let routedLogits=logits[0...,..<routedCount]
        let selection=sigmoid(routedLogits.asType(.float32))+correction
        let indices=stopGradient(argPartition(-selection,kth:topK-1,axis:-1)[0...,..<topK])
        let chosen=takeAlong(routedLogits,indices,axis:-1),sharedLogits=logits[0...,routedCount...]
        let weights=softmax(-softplus(-concatenated([chosen,sharedLogits],axis:-1).asType(.float32)),axis:-1,precise:true)*routeScale*globalScale
        let yr=weightedExpertSum(routed(flat,indices),weights[0...,..<topK].asType(x.dtype))
        let sharedIndices=broadcast(MLXArray(0..<sharedCount)[.newAxis,0...],to:[flat.dim(0),sharedCount])
        let ys=weightedExpertSum(shared(flat,sharedIndices),weights[0...,topK...].asType(x.dtype))
        return (yr+ys).reshaped(shape).asType(x.dtype)
    }
}

private final class InklingDecoderLayer:Module {
    @ModuleInfo(key:"self_attn") var attention:InklingAttention
    @ModuleInfo(key:"mlp") var mlp:InklingMLP
    @ModuleInfo(key:"input_layernorm") var inputNorm:RMSNorm
    @ModuleInfo(key:"post_attention_layernorm") var postNorm:RMSNorm
    @ModuleInfo(key:"attn_sconv") var attentionConv:InklingShortConvolution
    @ModuleInfo(key:"mlp_sconv") var mlpConv:InklingShortConvolution
    init(_ c:InklingConfiguration.TextConfiguration,layer:Int) {
        _attention.wrappedValue=InklingAttention(c,layer:layer)
        _mlp.wrappedValue=c.isDense(layer) ? InklingDenseMLP(c):InklingSparseMoE(c)
        _inputNorm.wrappedValue=RMSNorm(dimensions:c.hiddenSize,eps:c.rmsNormEps)
        _postNorm.wrappedValue=RMSNorm(dimensions:c.hiddenSize,eps:c.rmsNormEps)
        _attentionConv.wrappedValue=InklingShortConvolution(channels:c.hiddenSize,kernelSize:c.shortConvKernelSize,cacheIndex:2)
        _mlpConv.wrappedValue=InklingShortConvolution(channels:c.hiddenSize,kernelSize:c.shortConvKernelSize,cacheIndex:3)
    }
    func callAsFunction(_ x:MLXArray,cache:CacheList?)->MLXArray {
        let cc=cache?[1] as? ArraysCache
        let h=attentionConv(attention(inputNorm(x),cache:cache),cache:cc,residual:x)
        let out=mlpConv(mlp(postNorm(h)),cache:cc,residual:h);cc?.advance(x.dim(1));return out
    }
}

private final class InklingModelInner:Module {
    @ModuleInfo(key:"embed_tokens") var embed:Embedding
    @ModuleInfo(key:"embed_norm") var embedNorm:RMSNorm?
    let layers:[InklingDecoderLayer]
    @ModuleInfo(key:"norm") var norm:RMSNorm
    init(_ c:InklingConfiguration.TextConfiguration) {
        _embed.wrappedValue=Embedding(embeddingCount:c.vocabularySize,dimensions:c.hiddenSize)
        if c.useEmbedNorm {_embedNorm.wrappedValue=RMSNorm(dimensions:c.hiddenSize,eps:c.rmsNormEps)}
        layers=(0..<c.hiddenLayers).map { InklingDecoderLayer(c,layer:$0) }
        _norm.wrappedValue=RMSNorm(dimensions:c.hiddenSize,eps:c.rmsNormEps)
    }
    func callAsFunction(_ input:MLXArray,cache:[KVCache]?)->MLXArray {
        var h=embed(input);if let embedNorm {h=embedNorm(h)}
        for (i,layer) in layers.enumerated(){h=layer(h,cache:cache?[i] as? CacheList)}
        return norm(h)
    }
}

private final class InklingLanguageModel:Module {
    let config:InklingConfiguration.TextConfiguration
    @ModuleInfo(key:"model") var model:InklingModelInner
    @ModuleInfo(key:"lm_head") var head:Linear?
    init(_ c:InklingConfiguration.TextConfiguration) {
        config=c;_model.wrappedValue=InklingModelInner(c)
        if !c.tieWordEmbeddings {_head.wrappedValue=Linear(c.hiddenSize,c.vocabularySize,bias:false)}
    }
    func callAsFunction(_ input:MLXArray,cache:[KVCache]?)->MLXArray {
        let h=model(input,cache:cache)/config.logitsMupWidthMultiplier
        var logits=head?(h) ?? model.embed.asLinear(h)
        if let n=config.unpaddedVocabularySize,n<logits.dim(-1){logits=logits[.ellipsis,..<n]}
        return logits
    }
}

public final class InklingModel:Module,LLMModel,KVCacheDimensionProvider {
    public let vocabularySize:Int,kvHeads:[Int]
    private let config:InklingConfiguration.TextConfiguration
    @ModuleInfo(key:"language_model") fileprivate var languageModel:InklingLanguageModel
    public init(_ c:InklingConfiguration) {
        let text=c.textConfiguration
        config=text;vocabularySize=text.vocabularySize
        kvHeads=(0..<text.hiddenLayers).map {text.isSliding($0) ? text.swaKVHeads:text.kvHeads}
        _languageModel.wrappedValue=InklingLanguageModel(text)
    }
    public func callAsFunction(_ input:MLXArray,cache:[KVCache]?)->MLXArray {languageModel(input,cache:cache)}
    public func newCache(parameters:GenerateParameters?)->[KVCache] {
        (0..<config.hiddenLayers).map {_ in CacheList(KVCacheSimple(),ArraysCache(size:4))}
    }
    public func sanitize(weights:[String:MLXArray])->[String:MLXArray] {
        weights.filter {$0.key.hasPrefix("language_model.")}
    }
}
extension InklingModel:LoRAModel {public var loraLayers:[Module]{languageModel.model.layers}}
