import XCTest

@testable import mlx_forge

final class MLXGenRuntimeTests: XCTestCase {
    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func testBerniniArgumentsKeepReferenceOrder() {
        let args = MLXGenRuntime.arguments(
            route: .berniniReference, prompt: "the band on the floor", width: 848, height: 480,
            frames: 81, steps: 40, seed: 7, images: ["/refs/singer.png", "/refs/guitarist.png"],
            outputPath: "/tmp/out.mp4")
        XCTAssertEqual(Array(args.prefix(3)), ["generate", "--model", "bernini-r-1.3b"])
        XCTAssertFalse(args.contains("--family"))
        let references = args.indices
            .filter { args[$0] == "--reference-image" }
            .map { args[$0 + 1] }
        XCTAssertEqual(references, ["/refs/singer.png", "/refs/guitarist.png"])
        XCTAssertEqual(value(after: "--prompt", in: args), "the band on the floor")
        XCTAssertEqual(value(after: "--reference-guidance", in: args), "6.0")
        XCTAssertEqual(value(after: "--width", in: args), "848")
        XCTAssertEqual(value(after: "--height", in: args), "480")
        XCTAssertEqual(value(after: "--frames", in: args), "81")
        XCTAssertEqual(value(after: "--fps", in: args), "16")
        XCTAssertEqual(value(after: "--steps", in: args), "40")
        XCTAssertEqual(value(after: "--seed", in: args), "7")
        XCTAssertEqual(value(after: "--output", in: args), "/tmp/out.mp4")
        XCTAssertTrue(args.contains("--json-events"))
        XCTAssertTrue(args.contains("--no-progress"))
        XCTAssertFalse(args.contains("--quantize"))
        XCTAssertFalse(args.contains("--image-path"))
    }

    func testH3ArgumentsUseTheFirstFrameAndQuantize() {
        let args = MLXGenRuntime.arguments(
            route: .h3FirstFrame, prompt: "she sings", width: 960, height: 544, frames: 124,
            steps: 8, seed: 3, images: ["/refs/keyframe.png"], outputPath: "/tmp/h3.mp4")
        XCTAssertEqual(Array(args.prefix(3)), ["generate", "--model", "minimax-h3-turbo-544p"])
        XCTAssertEqual(value(after: "--image-path", in: args), "/refs/keyframe.png")
        XCTAssertEqual(value(after: "--quantize", in: args), "8")
        XCTAssertEqual(value(after: "--frames", in: args), "124")
        XCTAssertEqual(value(after: "--steps", in: args), "8")
        XCTAssertFalse(args.contains("--reference-image"))
        XCTAssertFalse(args.contains("--family"))
        XCTAssertFalse(args.contains("--fps"))
    }

    func testJSONEventsBecomeStatus() {
        XCTAssertEqual(
            MLXGenRuntime.status(
                fromLine:
                    #"{"type": "runtime", "command": "mlxgen generate", "phase": "denoise", "step": 3, "total_steps": 40, "progress": 0.075}"#
            ),
            "denoise step 3 of 40")
        XCTAssertEqual(
            MLXGenRuntime.status(
                fromLine: #"{"type": "runtime", "phase": "denoise", "step": 40, "total_steps": 40}"#),
            "decoding video")
        XCTAssertEqual(
            MLXGenRuntime.status(fromLine: #"{"type": "runtime", "phase": "complete", "step": 40, "total_steps": 40}"#),
            "finishing")
        XCTAssertEqual(
            MLXGenRuntime.status(fromLine: #"{"type": "runtime", "phase": "save", "step": 40, "total_steps": 40}"#),
            "writing video")
        XCTAssertEqual(
            MLXGenRuntime.status(fromLine: #"{"type": "runtime", "phase": "load_model", "step": 0, "total_steps": 0}"#),
            "load model")
        XCTAssertNil(
            MLXGenRuntime.status(fromLine: #"{"type": "runtime", "phase": "failed", "error": "boom"}"#))
        XCTAssertNil(MLXGenRuntime.status(fromLine: #"{"type": "other", "phase": "denoise"}"#))
        XCTAssertNil(MLXGenRuntime.status(fromLine: "{not json"))
    }

    func testPlainLinesBecomeStatus() {
        XCTAssertEqual(MLXGenRuntime.status(fromLine: "Saving video to: /tmp/x.mp4"), "writing video")
        XCTAssertEqual(MLXGenRuntime.status(fromLine: "Loading transformer shards"), "loading model")
        XCTAssertNil(MLXGenRuntime.status(fromLine: "some unrelated line"))
    }

    func testFailureMessageComesFromTheFailedEvent() {
        let tail = """
            Loading transformer shards
            {"type": "runtime", "phase": "denoise", "step": 2, "total_steps": 40}
            {"type": "runtime", "phase": "failed", "error": "Out of memory while decoding", "error_type": "RuntimeError"}
            Traceback (most recent call last):
            """
        XCTAssertEqual(MLXGenRuntime.failureMessage(fromLogTail: tail), "Out of memory while decoding")
        XCTAssertNil(MLXGenRuntime.failureMessage(fromLogTail: "plain text only"))
    }

    func testBerniniProfileFollowsTheCanvas() {
        let route = MLXGenRoute.berniniReference
        XCTAssertEqual(route.sizes.first, "480x272")
        XCTAssertTrue(route.profile(width: 480, height: 272) == (49, 20))
        XCTAssertTrue(route.profile(width: 272, height: 480) == (49, 20))
        XCTAssertTrue(route.profile(width: 848, height: 480) == (81, 40))
        XCTAssertTrue(route.profile(width: 480, height: 848) == (81, 40))
        XCTAssertTrue(MLXGenRoute.h3FirstFrame.profile(width: 960, height: 544) == (124, 8))
    }

    func testCacheFolderNameMatchesHuggingFaceLayout() {
        XCTAssertEqual(MLXGenPaths.cacheFolder(for: "MiniMaxAI/MiniMax-H3"), "models--MiniMaxAI--MiniMax-H3")
    }

    func testPathsFallBackToDefaultsForBlankOrUnsetKeys() throws {
        let suite = "MLXGenRuntimeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("   ", forKey: MLXGenPaths.executableKey)
        defaults.set("/models/hf", forKey: MLXGenPaths.hfHomeKey)
        let paths = MLXGenPaths.load(defaults: defaults)
        XCTAssertEqual(paths.executable, MLXGenPaths.defaultExecutable)
        XCTAssertEqual(paths.hfHome, "/models/hf")
        XCTAssertEqual(paths.hubDirectory, "/models/hf/hub")
    }

    func testMissingListsTheExecutableAndUndownloadedRepos() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlxgen-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = MLXGenRoute.berniniReference.requiredRepos[0]
        let folder = root.appendingPathComponent("hub/" + MLXGenPaths.cacheFolder(for: repo))
        let snapshot = folder.appendingPathComponent("snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("mlxgen")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var paths = MLXGenPaths(executable: executable.path, hfHome: root.path)

        // An empty snapshot folder is not a download.
        XCTAssertEqual(paths.missing(for: .berniniReference).count, 1)

        try "{}".write(to: snapshot.appendingPathComponent("model_index.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(paths.missing(for: .berniniReference).isEmpty)

        // A blob still downloading means not ready.
        let incomplete = folder.appendingPathComponent("blobs/deadbeef.incomplete")
        try Data().write(to: incomplete)
        XCTAssertEqual(paths.missing(for: .berniniReference).count, 1)
        try FileManager.default.removeItem(at: incomplete)

        // H3 needs two repos; neither is present here.
        XCTAssertEqual(paths.missing(for: .h3FirstFrame).count, 2)

        // A missing executable is listed first, with the install hint.
        paths.executable = root.appendingPathComponent("nope").path
        let missing = paths.missing(for: .berniniReference)
        XCTAssertEqual(missing.count, 1)
        XCTAssertTrue(missing[0].contains("mlx-gen"))
    }
}
