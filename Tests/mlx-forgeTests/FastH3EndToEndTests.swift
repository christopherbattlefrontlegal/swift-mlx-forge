import XCTest

@testable import mlx_forge

/// Renders one real FastH3 clip through FastH3Runtime. Opt in with
/// FORGE_FASTH3_E2E=1; the paths come from the stored defaults. Takes about
/// twelve minutes at 832x480 on an M3 Ultra. Set FORGE_FASTH3_E2E_OUT to keep the MP4.
final class FastH3EndToEndTests: XCTestCase {
    func testRendersAClipWithProgress() async throws {
        guard ProcessInfo.processInfo.environment["FORGE_FASTH3_E2E"] == "1" else {
            throw XCTSkip("FORGE_FASTH3_E2E not set")
        }
        if let reason = FastH3Runtime.unavailableReason() {
            throw XCTSkip(reason)
        }

        final class Statuses: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let statuses = Statuses()

        let data = try await FastH3Runtime.generate(
            prompt: "(S1) A presenter says <d>[English] FastVideo runs FastH3 inside Forge.</d>",
            size: "832x480", seed: 2026
        ) { statuses.append($0) }

        XCTAssertGreaterThan(data.count, 100_000)
        XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp")
        let seen = statuses.all
        XCTAssertTrue(seen.contains("denoising step 1 of 8"), "statuses: \(seen)")
        XCTAssertTrue(seen.contains("decoding video and audio"), "statuses: \(seen)")
        XCTAssertTrue(seen.contains("muxing"), "statuses: \(seen)")

        if let keep = ProcessInfo.processInfo.environment["FORGE_FASTH3_E2E_OUT"] {
            try data.write(to: URL(fileURLWithPath: keep))
        }
    }
}
