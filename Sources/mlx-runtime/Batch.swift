// Swift-native MLX runtime — batch command.
//
// Loads an MLX model from disk a single time and evaluates many prompts in one
// process, without reloading the weights between prompts. This realizes the
// "repeated prompt execution without reloading the model" requirement and the
// "run batch jobs" deliverable while reusing the existing ModelContainer /
// ChatSession architecture from the llm-tool sources.

import ArgumentParser
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

struct BatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract:
            "Load a model once and run many prompts from a file (one prompt per line, or '-' for stdin)."
    )

    @OptionGroup var args: ModelArguments
    @OptionGroup var memory: MemoryArguments
    @OptionGroup var generate: GenerateArguments

    @Option(
        name: [.short, .long],
        help:
            "Path to a prompts file (one prompt per line) or '-' to read prompts from stdin. Blank lines are skipped."
    )
    var input: String

    @Flag(
        name: .long,
        help:
            "Emit one JSON object per line ({\"index\",\"prompt\",\"completion\",\"tokens\",\"tokens_per_second\"}) instead of plain text."
    )
    var json = false

    @Flag(
        name: .long,
        help: "Reset the chat context between prompts so prompts are independent (default: on)."
    )
    var independent = true

    @MainActor
    mutating func run() async throws {
        // Read prompts up front so a missing/unreadable file fails before the
        // (expensive) model load.
        let prompts = try readPrompts()
        if prompts.isEmpty {
            throw ValidationError("No prompts found in input '\(input)'.")
        }

        let defaultModel = MLXLLM.LLMRegistry.mistral7B4bit

        let modelContainer = try await memory.start { [args] in
            do {
                return try await args.load(
                    defaultModel: defaultModel.name, modelFactory: VLMModelFactory.shared)
            } catch ModelFactoryError.unsupportedModelType {
                return try await args.load(
                    defaultModel: defaultModel.name, modelFactory: LLMModelFactory.shared)
            }
        }

        await modelContainer.update { [generate] context in
            generate.prepare(&context)
        }

        if !generate.quiet {
            let name = await modelContainer.configuration.name
            FileHandle.standardError.write(
                Data("Loaded \(name). Running \(prompts.count) prompt(s)...\n".utf8))
        }

        let session = ChatSession(
            modelContainer,
            instructions: generate.system,
            generateParameters: generate.generateParameters
        )

        for (index, prompt) in prompts.enumerated() {
            if independent {
                await session.clear()
            }

            var completion = ""
            var info: GenerateCompletionInfo?

            for try await item in session.streamDetails(to: prompt, images: [], videos: []) {
                switch item {
                case .chunk(let chunk):
                    completion += chunk
                    if !json {
                        print(chunk, terminator: "")
                    }
                case .info(let i):
                    info = i
                default:
                    break
                }
            }

            if json {
                emitJSON(index: index, prompt: prompt, completion: completion, info: info)
            } else {
                // Separator between prompt outputs in plain-text mode.
                print("\n\u{1E}", terminator: "")  // ASCII record separator on its own line
                print()
            }
        }

        if !generate.quiet {
            memory.reportMemoryStatistics()
        }
    }

    private func readPrompts() throws -> [String] {
        let raw: String
        if input == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            raw = String(decoding: data, as: UTF8.self)
        } else {
            raw = try String(contentsOfFile: input, encoding: .utf8)
        }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func emitJSON(
        index: Int, prompt: String, completion: String, info: GenerateCompletionInfo?
    ) {
        var object: [String: Any] = [
            "index": index,
            "prompt": prompt,
            "completion": completion,
        ]
        if let info {
            object["tokens"] = info.generationTokenCount
            object["tokens_per_second"] = info.tokensPerSecond
        }
        if let data = try? JSONSerialization.data(withJSONObject: object),
            let line = String(data: data, encoding: .utf8)
        {
            print(line)
        }
    }
}
