import AVKit
import AppKit
import SwiftUI
import XCTest

@testable import mlx_forge

/// The Media viewer shows generated video through AVKit's `VideoPlayer`. That view
/// subclasses AVKit's `AVPlayerView`, which only reaches the process if the link step
/// keeps AVKit (Package.swift links it explicitly; auto-link drops it because no app
/// code names an AVKit symbol). Without it, building the view aborts the process with
/// "failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'".
final class MediaViewerTests: XCTestCase {
    @MainActor
    func testVideoPlayerHostsWithoutAborting() throws {
        _ = try XCTUnwrap(
            NSClassFromString("AVPlayerView"),
            "AVKit is not loaded; the mlx-forge target must link AVKit explicitly.")
        _ = NSApplication.shared
        let host = NSHostingView(
            rootView: VideoPlayer(player: AVPlayer()).frame(width: 320, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.subviews.isEmpty)
    }
}
