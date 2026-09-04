import Foundation
import MLX

/// Speculative decoding on Qwen's native multi-token-prediction (MTP) head.
///
/// Each round is one backbone pass over the last confirmed token plus `k`
/// drafts. The drafts come from the checkpoint's single MTP head chained `k`
/// deep: the first fuses the backbone state at the confirmed position with the
/// confirmed token's embedding (the head predicts t+2 from h(t) and token t+1,
/// as in ml-explore/mlx-lm#990 and vLLM's `qwen3_next_mtp`); each further draft
/// fuses the head's own output state with the previous draft's embedding.
///
/// After verification the backbone caches drop the rejected tail. Attention
/// caches shorten; the Gated DeltaNet caches replay their recurrence over the
/// accepted prefix from the state recorded before the window
/// (``MambaCache/trim(_:)``). The head's cache drops its in-flight drafts and is
/// re-synchronised with exact backbone states for the accepted positions in the
/// same batched call that proposes the next first draft, so the head only ever
/// attends over exact history plus its own current drafts.
public struct QwenNativeMTPTokenIterator: TokenIteratorProtocol, MTPStatsCollecting {

    let model: any QwenNativeMTPModel
    var cache: [KVCache]
    var headCache: [KVCache]
    let quantizeKVCache: (inout [KVCache]) -> Void

    var processor: LogitProcessor?
    let sampler: LogitSampler
    let parameters: GenerateParameters

    /// Drafts proposed per round (k), clamped to the tokens still allowed.
    public let numDraftTokens: Int

    public var tokenCount = 0
    public let maxTokens: Int?
    public var promptPrefillTime: TimeInterval = 0

    public private(set) var proposedDraftTokens = 0
    public private(set) var acceptedDraftTokens = 0
    public private(set) var passthroughReason: String?

    /// Backbone passes run after prefill, for tokens-per-pass reporting.
    public private(set) var backbonePasses = 0

    // Last confirmed token, not yet fed to the backbone, and the backbone state
    // at the position whose logits produced it.
    private var y: MLXArray
    private var yValue: Int
    private var lastHidden: MLXArray

    // Exact (state, next token) pairs the head cache is still owed: the
    // accepted window positions of the previous round.
    private var pendingHeadHidden: MLXArray?
    private var pendingHeadTokens = [Int32]()

    private var pendingTokens = [Int]()
    private var pendingIndex = 0

    public init(
        input: LMInput,
        model: any QwenNativeMTPModel,
        cache: [KVCache]? = nil,
        parameters: GenerateParameters,
        numMTPTokens: Int = 3
    ) throws {
        self.model = model
        self.cache = cache ?? model.newCache(parameters: parameters)
        self.headCache = model.makeQwenMTPCache(parameters: parameters)
        guard canTrimPromptCache(self.cache), canTrimPromptCache(self.headCache) else {
            throw KVCacheError(message: "MTP speculative decoding requires trimmable KV caches.")
        }

        self.sampler = parameters.sampler()
        self.processor = parameters.processor()
        self.parameters = parameters
        self.maxTokens = parameters.maxTokens
        self.numDraftTokens = Swift.max(0, numMTPTokens)
        self.quantizeKVCache = { cache in
            maybeQuantizeKVCache(
                cache: &cache,
                kvBits: parameters.kvBits,
                kvGroupSize: parameters.kvGroupSize,
                quantizedKVStart: parameters.quantizedKVStart)
        }
        if model.qwenMTPHeadCount == 0 {
            self.passthroughReason = "checkpoint has no native MTP head loaded"
        }

        // Placeholders until the prompt has been consumed.
        self.y = MLXArray(Int32(0))
        self.yValue = 0
        self.lastHidden = MLXArray(Float(0))

        let start = Date.timeIntervalSinceReferenceDate
        try prefill(input.text, windowSize: parameters.prefillStepSize)
        self.promptPrefillTime = Date.timeIntervalSinceReferenceDate - start
    }

    /// Consume the prompt in windows, priming the head's cache with exact
    /// (state, next token) pairs for every prompt position whose successor is
    /// known, and sample the first token.
    private mutating func prefill(_ text: LMInput.Text, windowSize: Int?) throws {
        let tokens = text.tokens
        let count = tokens.dim(0)
        guard count > 0 else {
            throw KVCacheError(message: "MTP decoding needs at least one prompt token.")
        }
        processor?.prompt(tokens)

        let step = Swift.max(1, windowSize ?? 512)
        let useHead = passthroughReason == nil
        var carried: MLXArray? = nil
        var lastLogits: MLXArray? = nil
        var start = 0
        while start < count {
            let end = Swift.min(count, start + step)
            let length = end - start
            let chunk = tokens[start ..< end]
            let out = model.qwenMTPBackbone(
                chunk[.newAxis], cache: cache, logitsForLastPositionOnly: true)
            if useHead {
                // The carried state pairs with this window's first token; each
                // state in the window pairs with the token after it. The last
                // state waits for the token that will be sampled.
                var states = [MLXArray]()
                var nextTokens = [MLXArray]()
                if let carried {
                    states.append(carried)
                    nextTokens.append(chunk[0 ..< 1])
                }
                if length > 1 {
                    states.append(out.hidden[0..., ..<(length - 1), 0...])
                    nextTokens.append(chunk[1 ..< length])
                }
                if !states.isEmpty {
                    let hidden = states.count == 1 ? states[0] : concatenated(states, axis: 1)
                    let next =
                        (nextTokens.count == 1 ? nextTokens[0] : concatenated(nextTokens))[.newAxis]
                    _ = model.qwenMTPHead(hidden: hidden, nextTokens: next, cache: headCache)
                }
            }
            let tail = out.hidden[0..., (length - 1)..., 0...]
            carried = tail
            lastLogits = out.logits
            eval(cacheArrays(cache) + cacheArrays(headCache) + [tail])
            start = end
        }

        var logits = lastLogits![0..., -1, 0...]
        logits = processor?.process(logits: logits) ?? logits
        let token = sampler.sample(logits: logits)
        processor?.didSample(token: token)
        y = token
        yValue = token.item(Int.self)
        lastHidden = carried!
        pendingTokens = [yValue]
        pendingIndex = 0
    }

    private func cacheArrays(_ caches: [KVCache]) -> [MLXArray] {
        caches.flatMap { $0.innerState() }
    }

    /// Exact head inputs owed from the previous round, followed by the input
    /// for the first draft of this round.
    private func commitHidden() -> MLXArray {
        if let pendingHeadHidden {
            return concatenated([pendingHeadHidden, lastHidden], axis: 1)
        }
        return lastHidden
    }

    private func commitTokens() -> MLXArray {
        MLXArray(pendingHeadTokens + [Int32(yValue)])[.newAxis]
    }

    /// One round: draft k tokens through the head, verify them in a single
    /// backbone pass, accept a prefix, roll back the rest.
    private mutating func speculateRound() {
        let remaining = maxTokens.map { $0 - tokenCount } ?? Int.max
        let k = Swift.min(numDraftTokens, Swift.max(0, remaining - 1))
        guard passthroughReason == nil, k > 0 else {
            plainStep()
            return
        }

        // 1. Drafts. The first head call also commits the exact entries owed
        //    from the previous round; the rest chain through the head.
        var draftProcessor = processor
        var draftTokens = [MLXArray]()
        var draftLogits = [MLXArray]()
        var step = model.qwenMTPHead(
            hidden: commitHidden(), nextTokens: commitTokens(), cache: headCache)
        pendingHeadHidden = nil
        pendingHeadTokens.removeAll()
        for depth in 0 ..< k {
            var logits = step.logits[0..., -1, 0...]
            logits = draftProcessor?.process(logits: logits) ?? logits
            let token = sampler.sample(logits: logits)
            draftProcessor?.didSample(token: token)
            draftTokens.append(token)
            draftLogits.append(logits)
            if depth + 1 < k {
                let depthState = step.hidden
                step = model.qwenMTPHead(
                    hidden: depthState[0..., (depthState.dim(1) - 1)..., 0...],
                    nextTokens: token[.newAxis],
                    cache: headCache)
            }
        }

        // Let the GPU start on the head chain while the CPU builds the much
        // larger verify graph.
        asyncEval(draftTokens)

        // 2. Verify every draft in one backbone pass. Linear-attention caches
        //    record the state after every position so a rejected tail rolls back.
        for layerCache in cache {
            (layerCache as? MambaCache)?.speculativeWindowArmed = true
        }
        let window = concatenated([y] + draftTokens)[.newAxis]
        let out = model.qwenMTPBackbone(window, cache: cache, logitsForLastPositionOnly: false)
        backbonePasses += 1

        var mainTokens = [MLXArray]()
        var mainLogits = [MLXArray]()
        if var verifyProcessor = processor {
            for i in 0 ... k {
                var logits = out.logits[0..., i, 0...]
                logits = verifyProcessor.process(logits: logits)
                let token = sampler.sample(logits: logits)
                verifyProcessor.didSample(token: token)
                mainTokens.append(token)
                mainLogits.append(logits)
            }
        } else {
            let logits = out.logits[0]
            let sampled = sampler.sample(logits: logits)
            for i in 0 ... k {
                mainTokens.append(sampled[i ..< i + 1])
                mainLogits.append(logits[i ..< i + 1])
            }
        }
        let mainValues = concatenated(mainTokens).asArray(Int.self)
        let draftValues = concatenated(draftTokens).asArray(Int.self)

        // 3. Accept a prefix of the drafts. The backbone's own token after it
        //    is always emitted: the correction, or the bonus token.
        var accepted = 0
        let finalToken: MLXArray
        let finalValue: Int
        let temperature = parameters.temperature
        if temperature == 0 {
            while accepted < k, mainValues[accepted] == draftValues[accepted] {
                accepted += 1
            }
            finalToken = mainTokens[accepted]
            finalValue = mainValues[accepted]
        } else {
            // Rejection sampling against the draft distribution (Leviathan et al.).
            var resampled: MLXArray? = nil
            while accepted < k {
                let x = draftValues[accepted]
                let pTarget = MLX.softmax(mainLogits[accepted] / temperature, axis: -1)
                let pDraft = MLX.softmax(draftLogits[accepted] / temperature, axis: -1)
                let pTargetX = pTarget[0, x].item(Float.self)
                let pDraftX = pDraft[0, x].item(Float.self)
                if Float.random(in: 0 ..< 1) < Swift.min(1, pTargetX / Swift.max(pDraftX, 1e-9)) {
                    accepted += 1
                    continue
                }
                var residual = MLX.maximum(pTarget - pDraft, MLXArray(Float(0)))
                let mass = residual.sum().item(Float.self)
                if mass > 1e-6 {
                    residual = residual / mass
                    resampled = MLXRandom.categorical(
                        MLX.log(MLX.maximum(residual, MLXArray(Float(1e-9)))))
                } else {
                    resampled = mainTokens[accepted]
                }
                break
            }
            finalToken = resampled ?? mainTokens[accepted]
            finalValue = finalToken.item(Int.self)
        }
        for i in 0 ..< accepted {
            processor?.didSample(token: draftTokens[i])
        }
        processor?.didSample(token: finalToken)
        proposedDraftTokens += k
        acceptedDraftTokens += accepted
        pendingTokens.append(contentsOf: draftValues[0 ..< accepted])
        pendingTokens.append(finalValue)

        // 4. Roll back the rejected tail: backbone caches by k - accepted, the
        //    head cache by its k - 1 in-flight drafts.
        trimPromptCache(cache, numTokens: k - accepted)
        for layerCache in cache {
            (layerCache as? MambaCache)?.clearSpeculativeWindow()
        }
        trimPromptCache(headCache, numTokens: k - 1)
        quantizeKVCache(&cache)
        quantizeKVCache(&headCache)

        // 5. Carry state into the next round.
        y = finalToken
        yValue = finalValue
        lastHidden = out.hidden[0..., accepted ... accepted, 0...]
        if accepted > 0 {
            pendingHeadHidden = out.hidden[0..., ..<accepted, 0...]
            pendingHeadTokens = draftValues[0 ..< accepted].map { Int32($0) }
        }
        // Everything this round produced was materialised by the token readback;
        // the trimmed states are slices that the next round's graph picks up.
    }

    /// One token without drafting: passthrough for checkpoints without a head,
    /// and the last token before `maxTokens`.
    private mutating func plainStep() {
        if passthroughReason == nil {
            _ = model.qwenMTPHead(
                hidden: commitHidden(), nextTokens: commitTokens(), cache: headCache)
            pendingHeadHidden = nil
            pendingHeadTokens.removeAll()
        }
        let out = model.qwenMTPBackbone(y[.newAxis], cache: cache, logitsForLastPositionOnly: true)
        backbonePasses += 1
        var logits = out.logits[0..., -1, 0...]
        logits = processor?.process(logits: logits) ?? logits
        let token = sampler.sample(logits: logits)
        processor?.didSample(token: token)
        y = token
        yValue = token.item(Int.self)
        lastHidden = out.hidden[0..., (out.hidden.dim(1) - 1)..., 0...]
        pendingTokens.append(yValue)
        quantizeKVCache(&cache)
        quantizeKVCache(&headCache)
        eval(cacheArrays(cache) + cacheArrays(headCache) + [y, lastHidden])
    }

    public mutating func next() -> Int? {
        if let maxTokens, tokenCount >= maxTokens {
            return nil
        }
        if pendingIndex < pendingTokens.count {
            let token = pendingTokens[pendingIndex]
            pendingIndex += 1
            tokenCount += 1
            return token
        }
        pendingTokens.removeAll(keepingCapacity: true)
        pendingIndex = 0
        speculateRound()
        guard !pendingTokens.isEmpty else { return nil }
        let token = pendingTokens[0]
        pendingIndex = 1
        tokenCount += 1
        return token
    }
}
