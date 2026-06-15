// Forge — global MLX/Metal turn gate.
//
// MLX evaluation is not safe to run concurrently from multiple tasks: two
// generations (or a generation overlapping a weight load, or a cache purge
// mid-stream) race in the Metal scheduler and can fault the GPU. Everything
// that touches the GPU — generation (UI and API server), model loading, and
// `Memory.clearCache()` after unload — takes one turn through this gate, so
// at most one MLX workload is in flight at a time. Turns are FIFO.
//
// Do NOT call `withTurn` from inside another turn (e.g. don't `load()` from
// within a generation body) — the gate is not reentrant and will deadlock.

actor MLXGate {

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` as the sole MLX workload, waiting FIFO behind any turn
    /// already in flight. The body is `@MainActor` because every caller
    /// (engine, server) lives there; the heavy compute itself runs inside
    /// MLX's own tasks regardless.
    func withTurn<T: Sendable>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by release(); `busy` stays true — the turn was handed to us.
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
