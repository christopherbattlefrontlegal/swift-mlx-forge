// Forge — unified LanguageModelSession path for Foundation Models backends.
//
// Apple FM, Core AI BYOM, and (later) PCC share one transcript + streaming API.
// MLX and GGUF keep their native engines until an adapter exists.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoundationSessionBridge {
    static let isEnabled = true
}

#if canImport(FoundationModels)

extension FoundationSessionBridge {

    static func transcript(
        from conversation: Conversation,
        systemPrompt: String,
        prompt: String
    ) -> Transcript {
        var entries: [Transcript.Entry] = []
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            entries.append(
                .instructions(
                    Transcript.Instructions(
                        segments: [.text(Transcript.TextSegment(content: trimmedSystem))],
                        toolDefinitions: [])))
        }
        for message in conversation.messages {
            switch message.role {
            case .user:
                entries.append(
                    .prompt(
                        Transcript.Prompt(
                            segments: [.text(Transcript.TextSegment(content: message.content))])))
            case .assistant:
                guard !message.isErrorMessage else { continue }
                entries.append(
                    .response(
                        Transcript.Response(
                            assetIDs: [],
                            segments: [.text(Transcript.TextSegment(content: message.content))])))
            case .system:
                continue
            }
        }
        entries.append(
            .prompt(
                Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: prompt))])))
        return Transcript(entries: entries)
    }

    static func generationOptions(from settings: GenerationSettings) -> GenerationOptions {
        GenerationOptions(
            temperature: settings.temperature,
            maximumResponseTokens: settings.maxTokens > 0 ? settings.maxTokens : nil)
    }

    /// Stream a reply through LanguageModelSession — shared by Apple FM and Core AI.
    static func stream(
        model: SystemLanguageModel,
        conversation: Conversation,
        prompt: String,
        settings: GenerationSettings,
        systemPrompt: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let transcript = transcript(
            from: conversation, systemPrompt: systemPrompt, prompt: prompt)
        let session = LanguageModelSession(model: model, transcript: transcript)
        let options = generationOptions(from: settings)

        var emitted = ""
        let stream = session.streamResponse(to: prompt, options: options)
        for try await snapshot in stream {
            if Task.isCancelled { break }
            let text = snapshot.content
            guard text.count > emitted.count else { continue }
            let start = text.index(text.startIndex, offsetBy: emitted.count)
            let delta = String(text[start...])
            emitted = text
            await onDelta(delta)
        }
        return emitted
    }

    static func unavailableMessage(for reason: SystemLanguageModel.Availability) -> String {
        switch reason {
        case .available:
            return ""
        case .unavailable(.deviceNotEligible):
            return "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled. Turn it on in System Settings."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading or initializing."
        case .unavailable:
            return "The Foundation Model is unavailable."
        }
    }
}

#endif
