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

import Foundation

actor MLXGate {

    private var busy = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []
    private var cancelledWaiterIDs: Set<UUID> = []
    private var registeringWaiterIDs: Set<UUID> = []

    /// Runs `body` as the sole MLX workload, waiting FIFO behind any turn
    /// already in flight. The body is `@MainActor` because every caller
    /// (engine, server) lives there; the heavy compute itself runs inside
    /// MLX's own tasks regardless.
    func withTurn<T: Sendable>(_ body: @MainActor () async throws -> T) async throws -> T {
        guard await acquire() else { throw CancellationError() }
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    /// Same FIFO exclusive turn as ``withTurn``, but `body` runs on a
    /// background thread (off the main actor). Used by the API server so a
    /// long MLX generation doesn't freeze the app UI while it serves a
    /// request. The gate still serializes GPU work — only one turn runs at
    /// a time — but the main thread is free to keep the interface live.
    func withTurnDetached<T: Sendable>(
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        guard await acquire() else { throw CancellationError() }
        defer { release() }
        try Task.checkCancellation()
        // body is nonisolated; called from this (non-MainActor) gate it runs on
        // the cooperative pool — off the main thread — so the UI stays live.
        return try await body()
    }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !busy {
            busy = true
            return true
        }
        let id = UUID()
        registeringWaiterIDs.insert(id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registeringWaiterIDs.remove(id)
                if Task.isCancelled || cancelledWaiterIDs.remove(id) != nil {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Resumed by release(); `busy` stays true — the turn was handed to us.
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else if registeringWaiterIDs.contains(id) {
            cancelledWaiterIDs.insert(id)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}
