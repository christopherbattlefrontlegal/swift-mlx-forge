// Forge — Foundation Models backends: Apple FM + Core AI BYOM.
//
// Both load a SystemLanguageModel and chat through FoundationSessionBridge
// (LanguageModelSession). MLX and GGUF use their own engines.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum CoreAIBackend {

    /// True when `directory` holds a Core AI compiled resource bundle.
    static func isCoreAIModel(_ directory: URL) -> Bool {
        let marker = directory.appendingPathComponent("CoreAI.manifest.json")
        if FileManager.default.fileExists(atPath: marker.path) { return true }
        return directory.pathExtension.lowercased() == "coreai"
    }

    /// Resolves the on-disk adapter bundle URL (manifest may point at a subpath).
    static func adapterURL(for directory: URL) -> URL {
        let manifest = directory.appendingPathComponent("CoreAI.manifest.json")
        guard
            let data = try? Data(contentsOf: manifest),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let relative = json["adapterPath"] as? String,
            !relative.isEmpty
        else { return directory }
        return directory.appendingPathComponent(relative)
    }

    static func loadResources(at directory: URL) async throws -> CoreAIRuntime {
        guard isCoreAIModel(directory) else {
            throw ForgeError.loadFailed(
                "Not a Core AI resource bundle: \(directory.lastPathComponent)")
        }
        return try await CoreAIRuntime.loadCoreAI(at: directory)
    }

    static func loadAppleFM() throws -> CoreAIRuntime {
        try CoreAIRuntime.loadAppleDefault()
    }
}

#if canImport(FoundationModels)

/// Holds a resident SystemLanguageModel for Apple FM or a compiled Core AI adapter.
final class CoreAIRuntime: @unchecked Sendable {

    let model: SystemLanguageModel
    let directory: URL?

    private init(model: SystemLanguageModel, directory: URL?) {
        self.model = model
        self.directory = directory
    }

    static func loadAppleDefault() throws -> CoreAIRuntime {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return CoreAIRuntime(model: model, directory: nil)
        case .unavailable:
            throw ForgeError.loadFailed(
                FoundationSessionBridge.unavailableMessage(for: model.availability))
        }
    }

    static func loadCoreAI(at directory: URL) async throws -> CoreAIRuntime {
        let bundleURL = CoreAIBackend.adapterURL(for: directory)
        let adapter = try SystemLanguageModel.Adapter(fileURL: bundleURL)
        try await adapter.compile()
        let model = SystemLanguageModel(adapter: adapter)
        switch model.availability {
        case .available:
            return CoreAIRuntime(model: model, directory: directory)
        case .unavailable:
            throw ForgeError.loadFailed(
                "\(FoundationSessionBridge.unavailableMessage(for: model.availability)) (\(directory.lastPathComponent))")
        }
    }

    func stream(
        conversation: Conversation,
        prompt: String,
        settings: GenerationSettings,
        systemPrompt: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try await FoundationSessionBridge.stream(
            model: model,
            conversation: conversation,
            prompt: prompt,
            settings: settings,
            systemPrompt: systemPrompt,
            onDelta: onDelta)
    }
}

#else

struct CoreAIRuntime: Sendable {
    static func loadCoreAI(at directory: URL) async throws -> CoreAIRuntime {
        throw ForgeError.loadFailed("FoundationModels is unavailable on this platform.")
    }

    static func loadAppleDefault() throws -> CoreAIRuntime {
        throw ForgeError.loadFailed("FoundationModels is unavailable on this platform.")
    }
}

#endif
