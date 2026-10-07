import XCTest

@testable import mlx_forge

final class FastH3RuntimeTests: XCTestCase {
    func testDenoiseStepLinesBecomeProgress() {
        XCTAssertEqual(
            FastH3Runtime.status(
                fromLogLine:
                    "INFO 10-05 15:31:16.325 [minimax_h3_pipeline.py:557] H3 denoise step 2/8 (sigma_video=0.9858, sigma_audio=0.9541) in 75.22s"
            ),
            "denoising step 2 of 8")
        XCTAssertEqual(
            FastH3Runtime.status(
                fromLogLine:
                    "INFO 10-05 15:39:00.000 [minimax_h3_pipeline.py:557] H3 denoise step 8/8 (sigma_video=0.5882, sigma_audio=0.3000) in 74.61s"
            ),
            "decoding video and audio")
    }

    func testPhaseLinesBecomeProgress() {
        XCTAssertEqual(
            FastH3Runtime.status(
                fromLogLine:
                    "INFO 10-05 15:28:26.788 [minimax_h3_pipeline.py:833] Geometry: output=832x480x124 model=832x480x124 audio_frames=124 fast=None fast_spatial=None"
            ),
            "encoding prompt")
        XCTAssertEqual(
            FastH3Runtime.status(
                fromLogLine:
                    "INFO 10-05 15:30:00.000 [minimax_h3_pipeline.py:486] Loaded MLX H3 DiT from /x/int8 in 0.0s"
            ),
            "loading DiT")
        XCTAssertEqual(
            FastH3Runtime.status(
                fromLogLine:
                    "INFO 10-05 15:39:52.781 [minimax_h3_pipeline.py:970] Generation complete: /x/out.mp4 | timings={}"
            ),
            "muxing")
        XCTAssertNil(
            FastH3Runtime.status(
                fromLogLine: "INFO 10-05 15:27:43.086 [__init__.py:60] MPS (Metal Performance Shaders) is available"))
        XCTAssertNil(FastH3Runtime.status(fromLogLine: ""))
    }

    func testDimensionsParseWidthByHeight() {
        XCTAssertEqual(FastH3Runtime.dimensions(from: "832x480")?.width, 832)
        XCTAssertEqual(FastH3Runtime.dimensions(from: "832x480")?.height, 480)
        XCTAssertEqual(FastH3Runtime.dimensions(from: "1280X720")?.height, 720)
        XCTAssertNil(FastH3Runtime.dimensions(from: "default"))
        XCTAssertNil(FastH3Runtime.dimensions(from: "0x480"))
    }

    func testArgumentsFollowTheMaintainedRecipe() {
        let paths = FastH3Paths(
            fastVideoRoot: "/src", checkpointRoot: "/ckpt", mlxCheckpoint: "/mlx/int8")
        let args = FastH3Runtime.arguments(
            paths: paths, prompt: "(S1) Hi <d>[English] Hello.</d>", width: 832, height: 480,
            seed: 2026, outputPath: "/tmp/out.mp4")
        XCTAssertEqual(
            args,
            [
                "/src/examples/inference/basic/mlx_fasth3_8step.py",
                "--model-root", "/ckpt",
                "--mlx-checkpoint", "/mlx/int8",
                "--prompt", "(S1) Hi <d>[English] Hello.</d>",
                "--height", "480",
                "--width", "832",
                "--num-frames", "124",
                "--seed", "2026",
                "--output-path", "/tmp/out.mp4",
            ])
    }

    func testPathsFallBackToDefaultsForBlankOrUnsetKeys() throws {
        let suite = "FastH3RuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let unset = FastH3Paths.load(defaults: defaults)
        XCTAssertEqual(unset.fastVideoRoot, FastH3Paths.defaultFastVideoRoot)
        XCTAssertEqual(unset.checkpointRoot, FastH3Paths.defaultCheckpointRoot)
        XCTAssertEqual(unset.mlxCheckpoint, FastH3Paths.defaultMLXCheckpoint)

        defaults.set("  ", forKey: FastH3Paths.checkpointRootKey)
        defaults.set("/custom/mlx", forKey: FastH3Paths.mlxCheckpointKey)
        let stored = FastH3Paths.load(defaults: defaults)
        XCTAssertEqual(stored.checkpointRoot, FastH3Paths.defaultCheckpointRoot)
        XCTAssertEqual(stored.mlxCheckpoint, "/custom/mlx")
        XCTAssertEqual(stored.ditWeights, "/custom/mlx/mlx_h3_dit.safetensors")
    }

    func testMissingListsRequiredFilesThatAreAbsent() {
        let paths = FastH3Paths(
            fastVideoRoot: "/nonexistent/src", checkpointRoot: "/nonexistent/ckpt",
            mlxCheckpoint: "/nonexistent/mlx")
        XCTAssertEqual(
            paths.missing(),
            [paths.python, paths.script, paths.inferenceContract, paths.ditWeights])
    }
}
