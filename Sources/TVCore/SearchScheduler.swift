import Foundation

/// One bounded queue shared by all runtimes. A slow Python source consumes only its own
/// lane; round-robin admission gives every other runtime a chance before filling another slot.
/// The task group retains a slot until the operation actually returns, including cancellation.
enum SearchScheduler {
    enum Lane: CaseIterable, Sendable { case native, python, quickJS, node, jar }
    private static let admission = Admission()

    /// Cancellation of an old query must not let a replacement query double its native
    /// workers while those old calls are still unwinding. These permits span search runs.
    private actor Admission {
        private final class Ticket: @unchecked Sendable {
            let id = UUID()
            private let lock = NSLock()
            private var stopped = false
            var cancelled: Bool { lock.withLock { stopped } }
            func cancel() { lock.withLock { stopped = true } }
        }
        private struct Pending {
            let ticket: Ticket
            let lane: Lane
            let continuation: CheckedContinuation<Bool, Never>
        }
        private let limits: [Lane: Int] = [.native: 6, .python: 4, .quickJS: 4, .node: 8, .jar: 5]
        private var running: [Lane: Int] = [:]
        private var pending: [Pending] = []

        func acquire(_ lane: Lane) async -> Bool {
            let ticket = Ticket()
            return await withTaskCancellationHandler {
                if Task.isCancelled { ticket.cancel() }
                return await withCheckedContinuation { continuation in
                    guard !ticket.cancelled else { continuation.resume(returning: false); return }
                    pending.append(Pending(ticket: ticket, lane: lane, continuation: continuation))
                    drain()
                }
            } onCancel: {
                ticket.cancel()
                Task { await self.cancel(ticket.id) }
            }
        }
        private func cancel(_ id: UUID) {
            guard let index = pending.firstIndex(where: { $0.ticket.id == id }) else { return }
            pending.remove(at: index).continuation.resume(returning: false)
            drain()
        }
        func release(_ lane: Lane) {
            running[lane, default: 0] -= 1
            drain()
        }
        private func drain() {
            var index = 0
            while index < pending.count {
                let candidate = pending[index]
                if candidate.ticket.cancelled {
                    pending.remove(at: index).continuation.resume(returning: false); continue
                }
                guard running.values.reduce(0, +) < 12,
                      running[candidate.lane, default: 0] < limits[candidate.lane, default: 1] else { index += 1; continue }
                running[candidate.lane, default: 0] += 1
                pending.remove(at: index).continuation.resume(returning: true)
            }
        }
    }

    static func request(site: Site, lane: Lane,
                        operation: @escaping @Sendable () async -> SearchSourceResult) async -> SearchSourceResult {
        guard await admission.acquire(lane) else {
            return SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription)
        }
        let result: SearchSourceResult
        if Task.isCancelled { result = SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription) }
        else { result = await operation() }
        await admission.release(lane)
        return result
    }

    static func search(sites: [Site], maximumConcurrent: Int, limits: [Lane: Int],
                       lane: @Sendable (Site) -> Lane,
                       operation: @escaping @Sendable (Site) async -> SearchSourceResult,
                       onResult: @escaping @Sendable (SearchSourceResult) async -> Void) async {
        let queues = Dictionary(grouping: sites, by: lane)
        let lanes = Lane.allCases.filter { queues[$0]?.isEmpty == false }
        guard !lanes.isEmpty, !Task.isCancelled else { return }
        let maximum = max(1, maximumConcurrent)
        await withTaskGroup(of: (Lane, SearchSourceResult).self) { group in
            var offsets: [Lane: Int] = [:], running: [Lane: Int] = [:]
            var active = 0, cursor = 0
            func fill() {
                while active < maximum, !Task.isCancelled {
                    var next: (Lane, Site)?
                    for _ in lanes.indices {
                        let candidate = lanes[cursor]
                        cursor = (cursor + 1) % lanes.count
                        let index = offsets[candidate, default: 0]
                        guard running[candidate, default: 0] < max(1, limits[candidate, default: 1]),
                              let queue = queues[candidate], index < queue.count else { continue }
                        offsets[candidate] = index + 1
                        next = (candidate, queue[index]); break
                    }
                    guard let (sourceLane, site) = next else { break }
                    running[sourceLane, default: 0] += 1; active += 1
                    group.addTask {
                        let result = await request(site: site, lane: sourceLane) { await operation(site) }
                        return (sourceLane, result)
                    }
                }
            }
            fill()
            for await (sourceLane, result) in group {
                running[sourceLane, default: 0] -= 1; active -= 1
                guard !Task.isCancelled else { group.cancelAll(); break }
                await onResult(result)
                fill()
            }
        }
    }
}
