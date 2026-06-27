// Local copy of the LLM input processor (upstream type is private to MLXLLM).

import Foundation
import MLX
import MLXLMCommon
import Tokenizers

struct ForgeLLMInputProcessor: UserInputProcessor {
    let tokenizer: any MLXLMCommon.Tokenizer
    let configuration: ModelConfiguration
    let messageGenerator: MessageGenerator

    func prepare(input: UserInput) throws -> LMInput {
        let messages = messageGenerator.generate(from: input)
        do {
            let promptTokens = try tokenizer.applyChatTemplate(
                messages: messages, tools: input.tools, additionalContext: input.additionalContext)
            return LMInput(tokens: MLXArray(promptTokens))
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            let prompt =
                messages
                .compactMap { $0["content"] as? String }
                .joined(separator: "\n\n")
            let promptTokens = tokenizer.encode(text: prompt)
            return LMInput(tokens: MLXArray(promptTokens))
        }
    }
}