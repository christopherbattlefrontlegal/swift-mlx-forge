// Copyright © 2024 Apple Inc.

import ArgumentParser
import CoreImage
import Darwin
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

@main
struct LLMTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mlx-runtime",
        abstract:
            "Swift-native, headless MLX runtime for in-process LLM/VLM inference on Apple Silicon.",
        subcommands: [
            EvaluateCommand.self, BatchCommand.self, ChatCommand.self, LoRACommand.self,
            ListCommands.self, ServeCommand.self,
        ],
        defaultSubcommand: EvaluateCommand.self)
}

/// Command line arguments for loading a model.
struct ModelArguments: ParsableArguments, Sendable {

    @Option(name: .long, help: "Name of the Hugging Face model or absolute path to directory")
    var model: String?

    @Option(help: "Hub download directory")
    var download: URL?

    var downloader: any Downloader {
        let client =
            if let download {
                HubClient(cache: HubCache(cacheDirectory: download))
            } else {
                HubClient()
            }
        let downloader = #hubDownloader(client)
        return downloader
    }

    @Sendable
    func load(defaultModel: String, modelFactory: any ModelFactory) async throws -> ModelContainer {
        let modelConfiguration: ModelConfiguration

        let modelName = self.model ?? defaultModel

        print("Loading \(modelName)...")

        if modelName.hasPrefix("/") {
            // path
            modelConfiguration = ModelConfiguration(directory: URL(filePath: modelName))
        } else {
            // identifier
            modelConfiguration = modelFactory.configuration(id: modelName)
        }

        return try await modelFactory.loadContainer(
            from: self.downloader,
            using: #huggingFaceTokenizerLoader(),
            configuration: modelConfiguration)
    }
}

struct PromptArguments: ParsableArguments, Sendable {
    @Option(
        name: .shortAndLong,
        help:
            "The message to be processed by the model. Use @path,@path to load from files, e.g. @/tmp/prompt.txt"
    )
    var prompt: String?

    func resolvePrompt(configuration: ModelConfiguration) throws -> String {
        let prompt = self.prompt ?? configuration.defaultPrompt
        if prompt.hasPrefix("@") {
            let names = prompt.split(separator: ",").map { String($0.dropFirst()) }
            return try names.map { try String(contentsOfFile: $0) }.joined(separator: "\n")
        } else {
            return prompt
        }
    }
}

/// Argument package for supplying media files
struct MediaArguments: ParsableArguments, Sendable {

    @Option(parsing: .upToNextOption, help: "Resize images to this size (width, height)")
    var resize: [Int] = []

    @Option(parsing: .upToNextOption, help: "Paths or URLs for input images")
    var image: [URL] = []

    @Option(parsing: .upToNextOption, help: "Paths or URLs for input videos")
    var video: [URL] = []

    var images: [UserInput.Image] {
        image.map { UserInput.Image.url($0) }
    }
    var videos: [UserInput.Video] {
        video.map { UserInput.Video.url($0) }
    }

    var processing: UserInput.Processing {
        var processing = UserInput.Processing()
        if !resize.isEmpty {
            let size: CGSize
            if resize.count == 1 {
                // Single value represents width/height
                let v = resize[0]
                size = CGSize(width: v, height: v)
            } else {
                let v0 = resize[0]
                let v1 = resize[1]
                size = CGSize(width: v0, height: v1)
            }
            processing.resize = size
        }
        return processing
    }
}

/// Command line arguments for controlling generation of text.
struct GenerateArguments: ParsableArguments, Sendable {

    @Option(
        name: .shortAndLong,
        help:
            "The system prompt"
    )
    var system: String = ""

    @Option(name: .shortAndLong, help: "Maximum number of tokens to generate")
    var maxTokens = 100

    @Option(name: .shortAndLong, help: "The sampling temperature")
    var temperature: Float = 0.6

    @Option(name: .long, help: "The top p sampling")
    var topP: Float = 1.0

    @Option(name: .long, help: "The penalty factor for repeating tokens")
    var repetitionPenalty: Float?

    @Option(name: .long, help: "The number of tokens to consider for repetition penalty")
    var repetitionContextSize: Int = 20

    @Option(name: .long, help: "Additive penalty for tokens that appear in recent context (presence penalty)")
    var presencePenalty: Float?

    @Option(name: .long, help: "Number of tokens to consider for presence penalty")
    var presenceContextSize: Int = 20

    @Option(name: .long, help: "Additive penalty that scales with token frequency in recent context (frequency penalty)")
    var frequencyPenalty: Float?

    @Option(name: .long, help: "Number of tokens to consider for frequency penalty")
    var frequencyContextSize: Int = 20

    @Option(name: .long, help: "Additional end-of-sequence token to stop generation")
    var extraEosToken: String?

    @Option(name: .long, help: "The PRNG seed")
    var seed: UInt64 = 0

    @Option(name: .long, help: "Number of bits for KV cache quantization (nil = no quantization)")
    var kvBits: Int?

    @Option(name: .long, help: "Group size for KV cache quantization")
    var kvGroupSize: Int = 64

    @Option(name: .long, help: "Step to begin using quantized KV cache when kv-bits is set")
    var quantizedKvStart: Int = 0

    @Flag(name: .shortAndLong, help: "If true only print the generated output")
    var quiet = false

    @Flag(name: .customLong("tool-time"), help: "Enable time telling tool")
    var useTimeTool = false

    var generateParameters: GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            kvBits: kvBits,
            kvGroupSize: kvGroupSize,
            quantizedKVStart: quantizedKvStart,
            temperature: temperature, topP: topP,
            repetitionPenalty: repetitionPenalty, repetitionContextSize: repetitionContextSize,
            presencePenalty: presencePenalty, presenceContextSize: presenceContextSize,
            frequencyPenalty: frequencyPenalty, frequencyContextSize: frequencyContextSize)
    }

    var toolSpecs: [MLXLMCommon.ToolSpec] {
        var tools = [MLXLMCommon.ToolSpec]()

        if useTimeTool {
            tools.append(timeTool.schema)
        }

        return tools
    }

    func call(toolCall: ToolCall) async throws -> String {
        if useTimeTool && toolCall.function.name == timeTool.name {
            return try await toolCall.execute(with: timeTool).toolResult
        }
        return "Unknown tool: \(toolCall.function.name)"
    }

    func prepare(
        _ context: inout ModelContext
    ) {
        if let extraEosToken {
            context.configuration.extraEOSTokens.insert(extraEosToken)
        }
    }

    func generate(
        input: LMInput, context: ModelContext
    ) async throws -> (GenerateCompletionInfo, String) {
        var output = ""
        for await item in try MLXLMCommon.generate(
            input: input, parameters: generateParameters, context: context)
        {
            switch item {
            case .chunk(let string):
                output += string
                print(string, terminator: "")
            case .info(let info):
                return (info, output)
            case .toolCall(let toolCall):
                do {
                    // TODO maybe just use ChatSession here?
                    let x = try await call(toolCall: toolCall)
                    print("TOOL RESULT: \(x)")
                } catch {
                    print("\nError executing tool: \(error.localizedDescription)")
                }
                break
            }
        }
        fatalError("exited loop without seeing .info")
    }
}

/// Argument package for adjusting and reporting memory use.
struct MemoryArguments: ParsableArguments, Sendable {

    @Flag(name: .long, help: "Show memory stats")
    var memoryStats = false

    @Option(name: .long, help: "Maximum cache size in M")
    var cacheSize: Int?

    @Option(name: .long, help: "Maximum memory size in M")
    var memorySize: Int?

    var startMemory: Memory.Snapshot?

    mutating func start<L>(_ load: @Sendable () async throws -> L) async throws -> L {
        if let cacheSize {
            Memory.cacheLimit = cacheSize * 1024 * 1024
        }

        if let memorySize {
            Memory.memoryLimit = memorySize * 1024 * 1024
        }

        let result = try await load()
        startMemory = Memory.snapshot()

        return result
    }

    mutating func start() {
        if let cacheSize {
            Memory.cacheLimit = cacheSize * 1024 * 1024
        }

        if let memorySize {
            Memory.memoryLimit = memorySize * 1024 * 1024
        }

        startMemory = Memory.snapshot()
    }

    func reportCurrent() {
        if memoryStats {
            let memory = Memory.snapshot()
            print(memory.description)
        }
    }

    func reportMemoryStatistics() {
        if memoryStats, let startMemory {
            let endMemory = Memory.snapshot()

            print("=======")
            print("Memory size: \(Memory.memoryLimit / 1024)K")
            print("Cache size:  \(Memory.cacheLimit / 1024)K")

            print("")
            print("=======")
            print("Starting memory")
            print(startMemory.description)

            print("")
            print("=======")
            print("Ending memory")
            print(endMemory.description)

            print("")
            print("=======")
            print("Growth")
            print(startMemory.delta(endMemory).description)

        }
    }
}

struct EvaluateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "evaluate prompt and generate text"
    )

    @OptionGroup var args: ModelArguments
    @OptionGroup var memory: MemoryArguments
    @OptionGroup var generate: GenerateArguments
    @OptionGroup var prompt: PromptArguments
    @OptionGroup var media: MediaArguments

    @MainActor
    mutating func run() async throws {
        let modelFactory: any ModelFactory
        let defaultModel: ModelConfiguration

        // Switch between LLM and VLM based on presence of media
        let vlm = !media.image.isEmpty || !media.video.isEmpty
        if vlm {
            modelFactory = VLMModelFactory.shared
            defaultModel = MLXVLM.VLMRegistry.qwen2VL2BInstruct4Bit
        } else {
            modelFactory = LLMModelFactory.shared
            defaultModel = MLXLLM.LLMRegistry.mistral7B4bit
        }

        // Load the model
        let modelContainer = try await memory.start { [args] in
            try await args.load(defaultModel: defaultModel.name, modelFactory: modelFactory)
        }

        // update the context/configuration with any command line parameters
        await modelContainer.update { [generate] context in
            generate.prepare(&context)
        }

        // Get the resolved configuration (this has the default prompt)
        let modelConfiguration = await modelContainer.configuration

        let prompt =
            (try? self.prompt.resolvePrompt(configuration: modelConfiguration))
            ?? modelConfiguration.defaultPrompt

        if !generate.quiet {
            print("Loaded \(modelConfiguration.name)")
        }

        let session = ChatSession(
            modelContainer,
            instructions: generate.system,
            generateParameters: generate.generateParameters,
            processing: media.processing,
            tools: generate.toolSpecs
        )

        if !generate.quiet {
            print("Starting generation ...")
            print(prompt, terminator: " ")
        }

        // use the `stream` variant as we want to capture the generation statistics as well
        var completionInfo: GenerateCompletionInfo?

        for try await item in session.streamDetails(
            to: prompt, images: media.images, videos: media.videos
        ) {
            switch item {
            case .chunk(let chunk): print(chunk, terminator: "")
            case .info(let info): completionInfo = info
            default: break
            }
        }

        if !generate.quiet, let completionInfo {
            print("------")
            print(completionInfo.summary())

            memory.reportMemoryStatistics()
        }
    }
}

// MARK: - Serve command (for UI clients like mlx-studio)
// Persistent load-once mode. Model stays resident in this process.
// UI drives it over stdio with simple NDJSON command/event protocol.
// This enables "run the same way" (we invoke the mlx-runtime binary) while
// delivering LM-Studio-like speed (no reloads, no repeated builds).

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "load model once and serve generation requests over stdio (JSON lines) for UIs"
    )

    @OptionGroup var args: ModelArguments
    @OptionGroup var memory: MemoryArguments
    @OptionGroup var generate: GenerateArguments
    @OptionGroup var media: MediaArguments

    mutating func run() async throws {
        let defaultModel = MLXLLM.LLMRegistry.mistral7B4bit

        // Load exactly like ChatCommand (supports local /abs/path via hasPrefix in ModelArguments.load)
        let modelContainer: ModelContainer
        do {
            modelContainer = try await memory.start { [args] in
                do {
                    return try await args.load(
                        defaultModel: defaultModel.name, modelFactory: VLMModelFactory.shared)
                } catch ModelFactoryError.unsupportedModelType {
                    return try await args.load(
                        defaultModel: defaultModel.name, modelFactory: LLMModelFactory.shared)
                }
            }
        } catch {
            // Emit a structured "error" event over stdout (NDJSON) so the UI sees it
            // in the Activity Log even if the load throws before we ever emit "ready".
            // The "Loading <name>..." plain text will already have printed to stdout.
            let msg = "Load failed: \(error.localizedDescription)"
            let enc = JSONEncoder()
            if let d = try? enc.encode(StudioEvent(event: "error", message: msg)),
               let s = String(data: d, encoding: .utf8) {
                print(s)
                fflush(stdout)
            }
            print("✕ \(msg)")
            // Exit directly so ArgumentParser doesn't add its own "Error: ..." wrapper
            // on the thrown error. The UI only needs the protocol event + our plain line.
            Darwin.exit(1)
        }

        await modelContainer.update { [generate] context in
            generate.prepare(&context)
        }

        // State for the long-lived session (recreated only on system change / reset).
        // We immediately hand ownership to ServeState (file-scope type) so the detached reader
        // and generation tasks can safely mutate under MainActor dispatch.
        let usedModel = args.model ?? defaultModel.name
        let initialSystem = generate.system
        let initialSession = ChatSession(
            modelContainer,
            instructions: initialSystem,
            generateParameters: generate.generateParameters,
            processing: media.processing
        )

        let state = ServeState(
            modelContainer: modelContainer,
            currentSystem: initialSystem,
            chatSession: initialSession,
            processing: media.processing
        )

        // Signal UI that load succeeded and we are ready for commands. Model is now resident.
        state.emit(StudioEvent(event: "ready", model: usedModel))

        // Reader on detached thread so we can receive sets/stop/reset while a generation stream is in flight.
        let reader = Task.detached {
            while let line = readLine() {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if let data = line.data(using: .utf8),
                   let cmd = try? JSONDecoder().decode(StudioCommand.self, from: data) {
                    // state is @unchecked Sendable (see safety invariant on ServeState).
                    // Dispatch to @MainActor for serialized mutation of the MLX container/session.
                    Task { @MainActor in
                        state.handle(command: cmd)
                    }
                }
            }
        }

        // Stay alive until stdin EOF (UI closed pipes) or explicit quit.
        await reader.value
    }
}

// File-scope state holder for serve loop (owns the container + session so command reader + streaming tasks
// can coordinate safely when dispatched to @MainActor).
//
// SAFETY (for @unchecked Sendable): All mutations to currentSystem / chatSession / generationTask
// are performed on @MainActor (via handle(command:) dispatched from the detached reader, or
// directly inside handle for "set"/"reset"/"prompt"). The detached reader *only* decodes and
// dispatches to @MainActor; it never touches the fields itself. Generation tasks (detached for
// non-blocking) are *canceled* before any new prompt/reset/stop, and only *read* the live
// chatSession reference to consume its async stream, calling back exclusively through emit()
// (which does nothing but JSON print + fflush(stdout) — thread-safe). The weak-self pattern +
// "cancel before replace" ensures no concurrent mutation of the held ModelContainer/ChatSession
// from MLXLMCommon. We document this serialized-access invariant and take responsibility for
// Sendable (per swift-concurrency skill guidance: documented safety + follow-up to revisit
// if the MLX types become Sendable or we move state to a real actor).
private final class ServeState: @unchecked Sendable {
    let modelContainer: ModelContainer
    var currentSystem: String
    var chatSession: ChatSession
    var generationTask: Task<Void, Never>?
    let processing: UserInput.Processing

    init(modelContainer: ModelContainer, currentSystem: String, chatSession: ChatSession, processing: UserInput.Processing) {
        self.modelContainer = modelContainer
        self.currentSystem = currentSystem
        self.chatSession = chatSession
        self.processing = processing
    }

    func emit(_ e: StudioEvent) {
        let enc = JSONEncoder()
        if let d = try? enc.encode(e), let s = String(data: d, encoding: .utf8) {
            print(s)
            fflush(stdout)
        }
    }

    func handle(command: StudioCommand) {
        switch command.cmd.lowercased() {
        case "prompt":
            guard let p = command.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return }
            generationTask?.cancel()
            // Capture only the (now @unchecked Sendable) self; access chatSession inside the
            // detached task. All command-driven mutations remain serialized on @MainActor;
            // this task is canceled before any new handle() can replace the session.
            generationTask = Task.detached { [weak self] in
                guard let self else { return }
                do {
                    for try await item in self.chatSession.streamDetails(to: p, images: [], videos: []) {
                        if Task.isCancelled { break }
                        switch item {
                        case .chunk(let string):
                            self.emit(StudioEvent(event: "token", text: string))
                        case .info(let info):
                            self.emit(StudioEvent(event: "info", promptTime: info.promptTime, tokensPerSecond: info.tokensPerSecond))
                        case .toolCall:
                            break
                        }
                    }
                } catch {
                    self.emit(StudioEvent(event: "error", message: error.localizedDescription))
                }
            }

        case "set":
            guard let k = command.key?.lowercased(), let v = command.value else { return }
            switch k {
            case "temperature":
                if let f = Float(v) { chatSession.generateParameters.temperature = f }
            case "topp", "top_p", "topP":
                if let f = Float(v) { chatSession.generateParameters.topP = f }
            case "maxtokens", "max_tokens", "maxTokens":
                if let i = Int(v) { chatSession.generateParameters.maxTokens = i }
            case "repetitionpenalty", "repetition_penalty", "repetitionPenalty":
                if let f = Float(v) { chatSession.generateParameters.repetitionPenalty = f }
            case "presencepenalty", "presence_penalty", "presencePenalty":
                if let f = Float(v) { chatSession.generateParameters.presencePenalty = f }
            case "frequencypenalty", "frequency_penalty", "frequencyPenalty":
                if let f = Float(v) { chatSession.generateParameters.frequencyPenalty = f }
            case "system":
                currentSystem = v
                let live = chatSession.generateParameters
                chatSession = ChatSession(modelContainer, instructions: currentSystem, generateParameters: live, processing: processing)
            default:
                break
            }

        case "reset":
            generationTask?.cancel()
            let live = chatSession.generateParameters
            chatSession = ChatSession(modelContainer, instructions: currentSystem, generateParameters: live, processing: processing)

        case "stop":
            generationTask?.cancel()
            emit(StudioEvent(event: "stopped"))

        case "quit":
            generationTask?.cancel()
            emit(StudioEvent(event: "bye"))
            exit(0)

        default:
            emit(StudioEvent(event: "error", message: "unknown cmd: \(command.cmd)"))
        }
    }
}

// Simple NDJSON protocol types (no external deps).
struct StudioCommand: Codable, Sendable {
    let cmd: String
    let prompt: String?
    let key: String?
    let value: String?
}

struct StudioEvent: Codable, Sendable {
    let event: String
    let text: String?
    let model: String?
    let promptTime: Double?
    let tokensPerSecond: Double?
    let message: String?

    init(event: String, text: String? = nil, model: String? = nil, promptTime: Double? = nil, tokensPerSecond: Double? = nil, message: String? = nil) {
        self.event = event
        self.text = text
        self.model = model
        self.promptTime = promptTime
        self.tokensPerSecond = tokensPerSecond
        self.message = message
    }
}
