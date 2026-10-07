// Forge — Z.AI Coding Plan provider backed by the account already signed into ZCode.
//
// Forge never persists a duplicate Z.AI credential. It reads ZCode's selected
// provider at request time and passes the credential only to the isolated child
// process environment.

import Foundation

enum ZAICodingPlanError: LocalizedError {
    case zcodeMissing
    case accountUnavailable
    case launchFailed(String)
    case requestFailed(String)
    case unreadableResponse
    case emptyResponse
    case unavailableTool

    var errorDescription: String? {
        switch self {
        case .zcodeMissing:
            return "Install ZCode, sign in to your Z.AI Coding Plan account, and retry."
        case .accountUnavailable:
            return "ZCode must be signed into Z.AI Coding Plan with GLM-5.3 available."
        case .launchFailed(let detail):
            return "Forge could not launch ZCode: \(detail)"
        case .requestFailed(let detail):
            return detail.isEmpty
                ? "ZCode could not complete the GLM-5.3 request."
                : "ZCode could not complete the GLM-5.3 request: \(detail)"
        case .unreadableResponse:
            return "ZCode returned an unreadable GLM-5.3 response."
        case .emptyResponse:
            return "GLM-5.3 returned no output."
        case .unavailableTool:
            return "GLM-5.3 requested an unavailable Forge MCP tool."
        }
    }
}

final class ZAIRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    func track(_ process: Process) {
        lock.lock()
        let shouldStop = stopped
        if !shouldStop { self.process = process }
        lock.unlock()
        if shouldStop, process.isRunning { process.terminate() }
    }

    func untrack(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let active = process
        process = nil
        lock.unlock()
        if active?.isRunning == true { active?.terminate() }
    }

    func throwIfStopped() throws {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        if isStopped || Task.isCancelled { throw CancellationError() }
    }
}

struct ZAICodingPlanClient {
    static let modelID = "GLM-5.3"
    static let label = "Z.AI GLM-5.3"

    struct ConfigurationStatus: Equatable, Sendable {
        let isConfigured: Bool
        let summary: String
        let detail: String
    }

    struct Message: Sendable {
        let role: String
        let text: String
    }

    struct Tool: Sendable {
        let name: String
        let serverID: String
        let toolName: String
        let description: String
        let inputSchemaJSON: String?
    }

    private struct AccountConfiguration {
        let providerID: String
        let baseURL: String
        let credential: String
    }

    private final class ProcessResult: @unchecked Sendable {
        var output = Data()
        var errors = Data()
        var status: Int32 = -1
        var launchError: Error?
    }

    static func configurationStatus() -> ConfigurationStatus {
        guard executableURL() != nil else {
            return ConfigurationStatus(
                isConfigured: false,
                summary: "ZCode not found",
                detail: "Install ZCode, then sign in to Z.AI Coding Plan.")
        }
        do {
            _ = try accountConfiguration()
            return ConfigurationStatus(
                isConfigured: true,
                summary: "GLM-5.3 ready",
                detail: "Uses the Z.AI Coding Plan account already signed into ZCode. Forge stores no duplicate credential.")
        } catch {
            return ConfigurationStatus(
                isConfigured: false,
                summary: "Z.AI account needs attention",
                detail: error.localizedDescription)
        }
    }

    static func complete(
        system: String,
        messages: [Message],
        tools: [Tool],
        runControl: ZAIRunControl
    ) async throws -> String {
        try runControl.throwIfStopped()
        guard let executable = executableURL() else { throw ZAICodingPlanError.zcodeMissing }
        let account = try accountConfiguration()
        let prompt = try makePrompt(system: system, messages: messages, tools: tools)

        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-zai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        let requestURL = runDirectory.appendingPathComponent("forge-request.json")
        try Data(prompt.utf8).write(to: requestURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: requestURL.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(environment["PATH"])
        environment["ZCODE_MODEL"] = "\(account.providerID)/\(modelID)"
        environment["ZCODE_BASE_URL"] = account.baseURL
        environment["ZCODE_API_KEY"] = account.credential
        environment["ZCODE_STORAGE_DIR"] = runDirectory.path
        environment["ZCODE_SESSION_DB_PATH"] = runDirectory
            .appendingPathComponent("sessions.sqlite").path
        environment["ZCODE_LOG_FORMAT"] = "json"

        let result = await runCLI(
            executable: executable,
            arguments: [
                "--prompt",
                "Read the attached Forge inference request. Return only the requested JSON object, with no markdown or commentary.",
                "--attach", requestURL.path,
                "--json",
                "--no-color",
                "--mode", "plan",
                "--cwd", runDirectory.path,
                "--disallowedTools",
                "Bash,Read,Write,Edit,WebFetch,WebSearch,Agent,Workflow,Task,Skill"
            ],
            environment: environment,
            currentDirectory: runDirectory,
            runControl: runControl)
        try runControl.throwIfStopped()

        if let error = result.launchError {
            throw ZAICodingPlanError.launchFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            let detail = compactCLIError(
                result.errors,
                fallback: result.output,
                redacting: [account.credential])
            throw ZAICodingPlanError.requestFailed(detail)
        }
        return try decode(result.output, tools: tools)
    }

    private static func executableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [String?] = [
            environment["FORGE_ZCODE_CLI_PATH"],
            environment["STRATA_ZCODE_CLI_PATH"],
            "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ZCode.app/Contents/Resources/glm/zcode.cjs").path
        ]
        for candidate in candidates.compactMap({ $0 }) {
            let path = (candidate as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func accountConfiguration() throws -> AccountConfiguration {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2", isDirectory: true)
        let settings = try jsonObject(at: root.appendingPathComponent("setting.json"))
        let providers = try jsonObject(at: root.appendingPathComponent("config.json"))

        let selections = settings["modelProviderFamilySelectedKeys"] as? [String: Any]
        let selected = selections?["zai"] as? String ?? "builtin:zai-coding-plan"
        let providerID: String
        if let range = selected.range(of: "builtin:") {
            providerID = String(selected[range.lowerBound...])
        } else {
            providerID = selected
        }

        guard let catalog = providers["provider"] as? [String: Any],
              let provider = catalog[providerID] as? [String: Any],
              provider["enabled"] as? Bool != false,
              let models = provider["models"] as? [String: Any],
              models.keys.contains(where: { $0.caseInsensitiveCompare(modelID) == .orderedSame }),
              let options = provider["options"] as? [String: Any],
              let baseURL = options["baseURL"] as? String,
              !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let credential = options["apiKey"] as? String,
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ZAICodingPlanError.accountUnavailable
        }
        return AccountConfiguration(
            providerID: providerID, baseURL: baseURL, credential: credential)
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ZAICodingPlanError.accountUnavailable }
            return object
        } catch let error as ZAICodingPlanError {
            throw error
        } catch {
            throw ZAICodingPlanError.accountUnavailable
        }
    }

    private static func makePrompt(
        system: String, messages: [Message], tools: [Tool]
    ) throws -> String {
        var request: [String: Any] = [
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.text] }
        ]
        if !tools.isEmpty {
            request["application_tools"] = tools.map { tool -> [String: Any] in
                var value: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                    "server": tool.serverID,
                    "tool": tool.toolName
                ]
                if let schema = tool.inputSchemaJSON,
                   let data = schema.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data)
                {
                    value["input_schema"] = object
                } else {
                    value["input_schema"] = ["type": "object"]
                }
                return value
            }
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: request,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let payload = String(decoding: encoded, as: UTF8.self)
        let toolNames = tools.map(\.name)
        let actionInstruction: String
        if toolNames.isEmpty {
            actionInstruction = "Return {\"type\":\"answer\",\"text\":\"<actual answer to the user>\"}. Replace the angle-bracketed placeholder with the complete answer; never return placeholder wording literally."
        } else {
            actionInstruction = """
                Return {"type":"answer","text":"<actual answer to the user>"}, unless the latest user request requires one supplied application tool. Replace the angle-bracketed placeholder with the complete answer; never return placeholder wording literally. For a tool call, return {"type":"tool_call","tool_name":"one of \(toolNames.joined(separator: ", "))","tool_input":{}} with tool_input matching its schema. The Forge host executes it and sends the result in a later request.
                """
        }
        return """
            Execute this provider-neutral Forge inference request. Preserve all roles, ordering, and system instructions. Do not invoke ZCode tools.

            \(actionInstruction)

            REQUEST JSON
            \(payload)
            """
    }

    private static func runCLI(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        runControl: ZAIRunControl
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = currentDirectory

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let result = ProcessResult()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                result.output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                result.errors = errorPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            process.terminationHandler = { finished in
                result.status = finished.terminationStatus
                runControl.untrack(finished)
                group.leave()
            }

            do {
                try process.run()
                runControl.track(process)
            } catch {
                result.launchError = error
                process.terminationHandler = nil
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                group.leave()
            }
            group.notify(queue: .global()) { continuation.resume(returning: result) }
        }
    }

    private static func decode(_ data: Data, tools: [Tool]) throws -> String {
        let root = try decodeRoot(data)
        let raw = root["response"] as? String
            ?? root["result"] as? String
            ?? root["text"] as? String
            ?? root["content"] as? String
            ?? ""
        let envelope = decodeEnvelope(raw)

        if envelope?["type"] as? String == "tool_call" {
            guard let requestedName = envelope?["tool_name"] as? String,
                  let tool = tools.first(where: { $0.name == requestedName })
            else { throw ZAICodingPlanError.unavailableTool }
            let arguments = envelope?["tool_input"] as? [String: Any] ?? [:]
            let call: [String: Any] = [
                "server": tool.serverID,
                "tool": tool.toolName,
                "arguments": arguments
            ]
            let encoded = try JSONSerialization.data(
                withJSONObject: call, options: [.sortedKeys, .withoutEscapingSlashes])
            return "FORGE_MCP_CALL \(String(decoding: encoded, as: UTF8.self))"
        }

        let text = envelope?["text"] as? String ?? raw
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ZAICodingPlanError.emptyResponse }
        return text
    }

    private static func decodeRoot(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .reversed()
        for line in lines {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            return object
        }
        throw ZAICodingPlanError.unreadableResponse
    }

    private static func decodeEnvelope(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            trimmed,
            trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return object
        }
        return nil
    }

    private static func compactCLIError(
        _ primary: Data, fallback: Data, redacting secrets: [String]
    ) -> String {
        let source = primary.isEmpty ? fallback : primary
        var raw = String(data: source, encoding: .utf8) ?? ""
        for secret in secrets where !secret.isEmpty {
            raw = raw.replacingOccurrences(of: secret, with: "<redacted>")
        }
        let singleLine = raw
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(4)
            .joined(separator: " ")
        return String(singleLine.prefix(800))
    }

    private static func augmentedPath(_ current: String?) -> String {
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = (current ?? "").split(separator: ":").map(String.init)
        return (existing + standard).reduce(into: [String]()) { result, path in
            if !result.contains(path) { result.append(path) }
        }.joined(separator: ":")
    }
}
