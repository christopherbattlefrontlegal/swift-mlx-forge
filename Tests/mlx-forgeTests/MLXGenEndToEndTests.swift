import XCTest

@testable import mlx_forge

/// Renders a short Bernini-R clip from one reference photo through the real
/// mlx-gen runtime. Opt in with FORGE_MLXGEN_E2E=1 and FORGE_MLXGEN_E2E_REF
/// pointing at a photo; set FORGE_MLXGEN_E2E_OUT to keep the MP4. Uses the
/// bounded 320x192, 17-frame, 8-step smoke profile so it finishes in minutes.
final class MLXGenEndToEndTests: XCTestCase {
    func testBerniniRendersFromAReferencePhoto() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FORGE_MLXGEN_E2E"] == "1" else {
            throw XCTSkip("FORGE_MLXGEN_E2E not set")
        }
        if let reason = MLXGenRuntime.unavailableReason(for: .berniniReference) {
            throw XCTSkip(reason)
        }
        guard let reference = environment["FORGE_MLXGEN_E2E_REF"] else {
            throw XCTSkip("FORGE_MLXGEN_E2E_REF not set")
        }

        let statuses = StatusLog()
        let data: Data
        do {
            data = try await MLXGenRuntime.generate(
                route: .berniniReference,
                prompt: "The person from the photo turns toward the camera and smiles, soft window light, handheld.",
                size: "320x192", seed: 43, images: [URL(fileURLWithPath: reference)],
                frames: 17, steps: 8
            ) { statuses.append($0) }
        } catch {
            XCTFail("generate failed: \(String(reflecting: error))\nstatuses: \(statuses.lines)")
            return
        }

        XCTAssertGreaterThan(data.count, 10_000, "MP4 is too small to be a clip")
        XCTAssertTrue(
            statuses.lines.contains { $0.contains("step") },
            "no step progress was reported: \(statuses.lines)")
        if let keep = environment["FORGE_MLXGEN_E2E_OUT"] {
            try data.write(to: URL(fileURLWithPath: keep))
        }
    }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
