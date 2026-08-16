import Foundation
import XCTest

@testable import mlx_forge

@MainActor
final class HeadlessLauncherTests: XCTestCase {
    func testSafePresetClearsDangerousStateDeterministically() {
        let launcher = makeLauncher()
        launcher.dangerouslySkipPermissions = true
        launcher.allowDangerouslySkipPermissions = true
        launcher.permissionMode = .bypassPermissions
        launcher.maxTurns = "99"

        launcher.applyPreset(.safeCodeEdit)

        XCTAssertEqual(launcher.permissionMode, .acceptEdits)
        XCTAssertFalse(launcher.dangerouslySkipPermissions)
        XCTAssertFalse(launcher.allowDangerouslySkipPermissions)
        XCTAssertEqual(launcher.maxTurns, "")
        XCTAssertFalse(launcher.isDangerous)
        XCTAssertTrue(launcher.commandText.contains("--allowedTools"))
        XCTAssertFalse(launcher.commandText.contains("--dangerously-skip-permissions"))
    }

    func testCommandAlwaysEntersSelectedProject() {
        let launcher = makeLauncher()
        launcher.prompt = "Review the project"
        launcher.workingDirectory = FileManager.default.currentDirectoryPath

        XCTAssertTrue(launcher.validationMessages.isEmpty)
        XCTAssertTrue(
            launcher.commandText.hasPrefix("cd '\(FileManager.default.currentDirectoryPath)' && \\\n")
        )
        XCTAssertTrue(launcher.commandText.contains("claude -p 'Review the project'"))
    }

    func testRelativeOutputFolderIsCreatedWithoutRedundantAddDir() {
        let launcher = makeLauncher()
        launcher.prompt = "Write a report"
        launcher.workingDirectory = FileManager.default.currentDirectoryPath
        launcher.outputFolder = "artifacts/report"

        XCTAssertTrue(launcher.commandText.contains("mkdir -p 'artifacts/report'"))
        XCTAssertFalse(launcher.commandText.contains("--add-dir 'artifacts/report'"))
        XCTAssertTrue(launcher.commandText.contains("Output folder: artifacts/report"))
    }

    func testOutsideOutputFolderIsCreatedAndGrantedAccess() {
        let launcher = makeLauncher()
        launcher.prompt = "Write a report"
        launcher.workingDirectory = FileManager.default.currentDirectoryPath
        launcher.outputFolder = "/tmp/forge-headless-output"

        XCTAssertTrue(launcher.commandText.contains("mkdir -p '/tmp/forge-headless-output'"))
        XCTAssertTrue(launcher.commandText.contains("--add-dir '/tmp/forge-headless-output'"))
    }

    func testStructuredOutputValidationExplainsRequiredFormatAndBadJSON() {
        let launcher = makeLauncher()
        launcher.prompt = "Return fields"
        launcher.workingDirectory = FileManager.default.currentDirectoryPath
        launcher.jsonSchema = "{not json}"

        XCTAssertTrue(launcher.validationMessages.contains("Structured output requires --output-format json."))
        XCTAssertTrue(launcher.validationMessages.contains("The JSON Schema is not valid JSON."))

        launcher.outputFormat = .json
        launcher.jsonSchema = "{\"type\":\"object\"}"
        XCTAssertTrue(launcher.validationMessages.isEmpty)
    }

    func testMissionScaffoldWrapsAnExistingTaskWithoutDuplicatingItself() {
        let launcher = makeLauncher()
        launcher.prompt = "Fix the failing parser tests."

        launcher.insertMissionScaffold()

        XCTAssertTrue(launcher.hasMissionScaffold)
        XCTAssertTrue(launcher.prompt.hasPrefix(HeadlessLauncher.missionScaffoldHeading))
        XCTAssertTrue(launcher.prompt.hasSuffix("Fix the failing parser tests."))
        XCTAssertTrue(launcher.hasMeaningfulPrompt)

        let firstInsertion = launcher.prompt
        launcher.insertMissionScaffold()
        XCTAssertEqual(launcher.prompt, firstInsertion)
    }

    func testEmptyMissionScaffoldStillRequiresAnActualTask() {
        let launcher = makeLauncher()

        launcher.insertMissionScaffold()

        XCTAssertFalse(launcher.hasMeaningfulPrompt)
        XCTAssertFalse(launcher.canCompose)
        XCTAssertTrue(launcher.validationMessages.contains("Describe what you want Claude to do."))

        launcher.prompt += "Run the tests and fix failures caused by this change."
        XCTAssertTrue(launcher.hasMeaningfulPrompt)
        XCTAssertTrue(launcher.validationMessages.isEmpty)
        XCTAssertTrue(launcher.canCompose)
    }

    func testDocumentedMCPIntegrationIsAddedOnceAndPreapproved() {
        let launcher = makeLauncher()
        launcher.prompt = "Read the workspace."
        let notion = HeadlessLauncher.documentedMCPIntegrations.first { $0.id == "notion" }!

        launcher.includeMCPIntegration(notion)
        launcher.includeMCPIntegration(notion)

        XCTAssertTrue(launcher.isMCPIncluded("notion"))
        XCTAssertEqual(launcher.manualMCPConfig.components(separatedBy: .newlines).count, 1)
        XCTAssertTrue(launcher.commandText.contains("https://mcp.notion.com/mcp"))
        XCTAssertTrue(launcher.commandText.contains("mcp__notion__*"))
    }

    func testRemoteMCPBuilderValidatesAndCreatesHTTPConfig() {
        let launcher = makeLauncher()

        XCTAssertNotNil(launcher.addRemoteMCP(name: "bad name", urlString: "https://example.com/mcp"))
        XCTAssertNotNil(launcher.addRemoteMCP(name: "example", urlString: "http://example.com/mcp"))
        XCTAssertNil(launcher.addRemoteMCP(name: "example", urlString: "https://example.com/mcp"))

        XCTAssertTrue(launcher.isMCPIncluded("example"))
        let data = Data(launcher.manualMCPConfig.utf8)
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let servers = root["mcpServers"] as! [String: Any]
        let example = servers["example"] as! [String: Any]
        XCTAssertEqual(example["type"] as? String, "http")
        XCTAssertEqual(example["url"] as? String, "https://example.com/mcp")
    }

    func testMCPRegistryParserCreatesRemoteAndPackageConfigurations() throws {
        let fixture = #"""
        {"servers":[
          {"server":{"name":"io.example/legal-research","title":"Legal Research","description":"Search cases","remotes":[{"type":"streamable-http","url":"https://legal.example/mcp"}]}},
          {"server":{"name":"io.example/database-tools","description":"Query a database","packages":[{"registryType":"npm","identifier":"database-mcp","version":"1.2.3","transport":{"type":"stdio"},"environmentVariables":[{"name":"DATABASE_URL","isRequired":true,"isSecret":true}]}]}}
        ]}
        """#

        let results = HeadlessLauncher.parseMCPRegistryResults(data: Data(fixture.utf8))

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, "legal-research")
        let remoteData = Data(results[0].configJSON!.utf8)
        let remoteRoot = try JSONSerialization.jsonObject(with: remoteData) as! [String: Any]
        let remoteServers = remoteRoot["mcpServers"] as! [String: Any]
        let remote = remoteServers["legal-research"] as! [String: Any]
        XCTAssertEqual(remote["url"] as? String, "https://legal.example/mcp")
        XCTAssertEqual(results[1].transport, "NPM")
        XCTAssertTrue(results[1].configJSON?.contains("database-mcp@1.2.3") == true)
        XCTAssertTrue(results[1].configJSON?.contains("<REQUIRED: DATABASE_URL>") == true)
    }

    private func makeLauncher() -> HeadlessLauncher {
        let suite = "HeadlessLauncherTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let launcher = HeadlessLauncher(defaults: defaults)
        launcher.workingDirectory = FileManager.default.currentDirectoryPath
        return launcher
    }
}
