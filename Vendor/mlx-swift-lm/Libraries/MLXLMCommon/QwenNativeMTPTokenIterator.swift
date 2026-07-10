import Foundation
import MLX

public struct QwenNativeMTPTokenIterator: TokenIteratorProtocol {

    var y: LMInput.Text
    let model: any QwenNativeMTPModel

    var state: LMOutput.State?
    var cache: [KVCache]
    var mtpCaches: [[KVCache]]
    let quantizeKVCache: (inout [KVCache]) -> Void

    var processor: LogitProcessor?
    let sampler: LogitSampler
    let parameters: GenerateParameters

    public var tokenCount = 0
    public let maxTokens: Int?

    // Number of tokens the MTP heads predict (k)
    let numMTPTokens: Int

    // Logits from the previous step's MTP heads
    var mtpLogits: [MLXArray]?

    // Buffer of accepted tokens from the current speculation round
    private var pendingTokens = [Int]()
    private var pendingIndex = 0

    // Internal metrics
    public var acceptedDraftTokens: Int = 0
    public var totalDraftTokens: Int = 0
    public var promptPrefillTime: TimeInterval = 0.0

    /// Initialize a `QwenNativeMTPTokenIterator` with the given input.
    public init(
        input: LMInput,
        model: any QwenNativeMTPModel,
        cache: [KVCache]? = nil,
        parameters: GenerateParameters,
        numMTPTokens: Int = 1
    ) throws {
        self.y = input.text
        self.model = model
        self.cache = cache ?? model.newCache(parameters: parameters)
        self.mtpCaches = model.makeQwenMTPCaches(parameters: parameters)

        guard canTrimPromptCache(self.cache) else {
            throw KVCacheError(message: "MTP Speculative decoding requires trimmable KV caches.")
        }

        self.sampler = parameters.sampler()
        self.processor = parameters.processor()
        self.parameters = parameters

        self.maxTokens = parameters.maxTokens
        self.numMTPTokens = numMTPTokens

        self.quantizeKVCache = { cache in
            maybeQuantizeKVCache(
                cache: &cache,
                kvBits: parameters.kvBits,
                kvGroupSize: parameters.kvGroupSize,
                quantizedKVStart: parameters.quantizedKVStart
            )
        }

        let prefillStart = Date.timeIntervalSinceReferenceDate
        try prepare(input: input, windowSize: parameters.prefillStepSize)
        self.promptPrefillTime = Date.timeIntervalSinceReferenceDate - prefillStart
    }

    /// Prefill the main model with the prompt, priming caches for generation
    mutating func prepare(input: LMInput, windowSize: Int? = nil) throws {
        processor?.prompt(input.text.tokens)

        // Prefill main model
        switch try model.prepare(input, cache: cache, windowSize: windowSize) {
        case .tokens(let tokens):
            y = tokens
        case .logits(let result):
            var logits = result.logits[0..., -1, 0...]
            logits = processor?.process(logits: logits) ?? logits
            let token = sampler.sample(logits: logits)
            processor?.didSample(token: token)
            y = .init(tokens: token)
            state = result.state
        }
    }

    /// Run one round of MTP speculative decoding: draft from MTP heads, verify via main, accept/reject
    mutating func speculateRound() {
        let remaining = maxTokens.map { $0 - tokenCount } ?? numMTPTokens
        let numDraft = Swift.min(remaining, numMTPTokens)
        guard numDraft > 0 else {
            return
        }

        // Draft generation: Use MTP logits from the previous step
        var draftTokens = [MLXArray]()
        var draftProcessedLogits = [MLXArray]()
        if let previousMTP = mtpLogits, !previousMTP.isEmpty {
            let countToSample = Swift.min(numDraft, previousMTP.count)
            var draftProcessor = processor
            for i in 0 ..< countToSample {
                var draftLogit = previousMTP[i]
                draftLogit = draftProcessor?.process(logits: draftLogit) ?? draftLogit
                let draftToken = sampler.sample(logits: draftLogit)
                draftProcessor?.didSample(token: draftToken)
                draftTokens.append(draftToken)
                draftProcessedLogits.append(draftLogit)
            }
        }

        // If no draft tokens were generated (e.g. first step), fallback to regular generation
        if draftTokens.isEmpty {
            let mtpResult = model.callQwenMTP(y.tokens[.newAxis], cache: cache, mtpCaches: mtpCaches)
            guard !mtpResult.isEmpty else { return }

            let mainLogits = mtpResult[0]
            var logits = mainLogits[0..., -1, 0...]
            logits = processor?.process(logits: logits) ?? logits
            let token = sampler.sample(logits: logits)
            processor?.didSample(token: token)

            pendingTokens.append(token.item(Int.self))
            y = .init(tokens: token)

            // Save future MTP logits for next iteration (slice to single position)
            self.mtpLogits = mtpResult.count > 1 ? mtpResult.dropFirst().map { $0[0..., -1, 0...] } : nil

            // Force evaluation of MTP state to prevent graph collapse
            var evalArrays = [token]
            if let mtpLogits = self.mtpLogits { evalArrays.append(contentsOf: mtpLogits) }
            eval(evalArrays)

            quantizeKVCache(&cache)
            for i in mtpCaches.indices {
                quantizeKVCache(&mtpCaches[i])
            }
            return
        }

        // Verification: main model processes proposals in one pass
        for layer in cache {
            if let mamba = layer as? MambaCache { mamba.checkpointForMTP() }
        }

        let verifyTokens = [y.tokens] + draftTokens
        let verifyInput = LMInput.Text(tokens: concatenated(verifyTokens))
        let verifyStart = verifyInput.tokens.dim(0) - (draftTokens.count + 1)

        let mtpResult = model.callQwenMTP(verifyInput.tokens[.newAxis], cache: cache, mtpCaches: mtpCaches)
        guard !mtpResult.isEmpty else { return }

        let mainLogits = mtpResult[0]

        let mainTokens: MLXArray
        var mainProcessedLogits = [MLXArray]()
        if var verifyProcessor = processor {
            // Process sequentially
            var sampled = [MLXArray]()
            for i in 0 ..< (draftTokens.count + 1) {
                var logits = mainLogits[0..., verifyStart + i, 0...]
                logits = verifyProcessor.process(logits: logits)
                let token = sampler.sample(logits: logits)
                verifyProcessor.didSample(token: token)
                sampled.append(token)
                mainProcessedLogits.append(logits)
            }
            mainTokens = concatenated(sampled)
        } else {
            // Batch sample
            let verifyLogits = mainLogits[0..., verifyStart..., 0...].squeezed(axis: 0)
            mainTokens = sampler.sample(logits: verifyLogits)
            for i in 0 ..< (draftTokens.count + 1) {
                mainProcessedLogits.append(verifyLogits[i ..< i + 1])
            }
        }

        // We defer eval() until after we compute mtpLogits to force the graph
        let mainTokensList = mainTokens.asArray(Int.self)
        let draftTokensList = concatenated(draftTokens).asArray(Int.self)
        var accepted = 0

        let temp = parameters.temperature
        let finalTokenOut: MLXArray

        if temp == 0.0 {
            // Greedy Decoding (Exact Match = Rejection Sampling at temp 0)
            for i in 0 ..< draftTokens.count {
                guard mainTokensList[i] == draftTokensList[i] else {
                    break
                }
                processor?.didSample(token: draftTokens[i])
                pendingTokens.append(mainTokensList[i])
                accepted += 1
            }
            finalTokenOut = mainTokens[accepted ... accepted]
            processor?.didSample(token: finalTokenOut)
            pendingTokens.append(mainTokensList[accepted])
        } else {
            // Probabilistic Speculative Rejection Sampling (Leviathan et al.)
            var finalToken: MLXArray? = nil
            for i in 0 ..< draftTokens.count {
                let x = draftTokensList[i]

                // Force evaluation of distributions for this step
                let pTarget = MLX.softmax(mainProcessedLogits[i] / temp, axis: -1)
                let pDraft = MLX.softmax(draftProcessedLogits[i] / temp, axis: -1)
                eval(pTarget, pDraft)

                // Access scalar probability (assuming logits are [1, Vocab] or [Vocab])
                let pTargetX: Float
                let pDraftX: Float
                if pTarget.ndim == 2 {
                    pTargetX = pTarget[0, x].item(Float.self)
                    pDraftX = pDraft[0, x].item(Float.self)
                } else {
                    pTargetX = pTarget[x].item(Float.self)
                    pDraftX = pDraft[x].item(Float.self)
                }

                let acceptProb = Swift.min(1.0, pTargetX / Swift.max(pDraftX, 1e-9))
                let u = Float.random(in: 0..<1)

                if u < acceptProb {
                    processor?.didSample(token: draftTokens[i])
                    pendingTokens.append(x)
                    accepted += 1
                } else {
                    // Rejected! Resample from the corrected distribution
                    var pResample = MLX.maximum(pTarget - pDraft, MLXArray(0.0))
                    let sum = pResample.sum().item(Float.self)
                    if sum > 1e-6 {
                        pResample = pResample / sum
                        // categorical takes raw logits, so we convert back
                        let resampleLogits = MLX.log(MLX.maximum(pResample, MLXArray(1e-9)))
                        finalToken = MLXRandom.categorical(resampleLogits)
                    } else {
                        // Fallback
                        finalToken = MLXArray(mainTokensList[i])
                    }
                    break
                }
            }

            if finalToken == nil {
                // All drafts accepted!
                finalToken = mainTokens[accepted ... accepted]
            }
            finalTokenOut = finalToken!
            processor?.didSample(token: finalTokenOut)
            pendingTokens.append(finalTokenOut.item(Int.self))
        }
        self.acceptedDraftTokens += accepted
        self.totalDraftTokens += draftTokens.count

        // Rewind caches for rejected tokens
        let rejectedCount = draftTokens.count - accepted
        trimPromptCache(cache, numTokens: rejectedCount)
        for mtpCache in mtpCaches {
            trimPromptCache(mtpCache, numTokens: rejectedCount)
        }

        // Apply dynamic cache quantization after rewind
        quantizeKVCache(&cache)
        for i in mtpCaches.indices {
            quantizeKVCache(&mtpCaches[i])
        }

        // Set y for the next round
        y = .init(tokens: finalTokenOut)

        // Update mtpLogits from the verification pass for the NEXT speculation round.
        // mtpResult[1..N] contains the MTP head outputs for each depth.
        // Each head output is [B, 1, vocab] — extract directly (no position indexing needed).
        // Only keep them if ALL drafts were accepted, otherwise they are invalid due to cache rewind.
        if accepted == draftTokens.count && mtpResult.count > 1 {
            self.mtpLogits = mtpResult.dropFirst().map { headLogits in
                // headLogits shape: [B, 1, vocab] — squeeze to [B, vocab] for the sampler
                headLogits[0..., headLogits.dim(1) - 1, 0...]
            }
        } else {
            self.mtpLogits = nil
        }

        // Force evaluation of MTP state to prevent graph collapse
        var evalArrays = [mainTokens] + draftTokens
        if let mtpLogits = self.mtpLogits { evalArrays.append(contentsOf: mtpLogits) }
        eval(evalArrays)
    }

    mutating public func next() -> Int? {
        if let maxTokens, tokenCount >= maxTokens {
            return nil
        }

        // Drain the pending buffer first
        if pendingIndex < pendingTokens.count {
            let token = pendingTokens[pendingIndex]
            pendingIndex += 1
            tokenCount += 1
            return token
        }

        // Run a new speculation round
        pendingTokens.removeAll(keepingCapacity: true)
        pendingIndex = 0
        speculateRound()

        if pendingTokens.isEmpty {
            return nil
        }

        let token = pendingTokens[pendingIndex]
        pendingIndex += 1
        tokenCount += 1
        return token
    }
}
