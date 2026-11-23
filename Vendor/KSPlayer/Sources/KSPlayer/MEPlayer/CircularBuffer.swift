//
//  CircularBuffer.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import Foundation

/// 这个是单生产者，多消费者的阻塞队列和单生产者，多消费者的阻塞环形队列。并且环形队列还要有排序的能力。
/// 因为seek需要清空队列，所以导致他是多消费者。后续可以看下能不能改成单消费者的。
public class CircularBuffer<Item: ObjectQueueItem> {
    private var _buffer = ContiguousArray<Item?>()
//    private let semaphore = DispatchSemaphore(value: 0)
    private let condition = NSCondition()
    private var headIndex = UInt(0)
    private var tailIndex = UInt(0)
    private let expanding: Bool
    private let sorted: Bool
    private var destroyed = false
    private var wakePending = false
    private let sizeOf: (Item) -> Int64
    private let durationOf: (Item) -> TimeInterval
    private var queuedBytes: Int64 = 0
    private var queuedDuration: TimeInterval = 0
    public var byteCount: Int64 {
        condition.lock()
        defer { condition.unlock() }
        return queuedBytes
    }
    public var bufferedDuration: TimeInterval {
        condition.lock()
        defer { condition.unlock() }
        return max(0, queuedDuration)
    }
    private var _generation: UInt64 = 0
    var generation: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return _generation
    }

    @discardableResult func perform(ifGeneration generation: UInt64, _ body: () -> Void) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyed, generation == _generation else { return false }
        body()
        return true
    }
    @inline(__always)
    private var _count: Int { Int(tailIndex &- headIndex) }
    @inline(__always)
    public var count: Int {
//        condition.lock()
//        defer { condition.unlock() }
        Int(tailIndex &- headIndex)
    }

    public internal(set) var fps: Float = 24
    public private(set) var maxCount: Int
    private var mask: UInt
    public init(initialCapacity: Int = 256, sorted: Bool = false, expanding: Bool = true,
                sizeOf: @escaping (Item) -> Int64 = { _ in 0 },
                durationOf: @escaping (Item) -> TimeInterval = { _ in 0 }) {
        self.expanding = expanding
        self.sorted = sorted
        self.sizeOf = sizeOf
        self.durationOf = durationOf
        let capacity = initialCapacity.nextPowerOf2()
        _buffer = ContiguousArray<Item?>(repeating: nil, count: Int(capacity))
        maxCount = Int(capacity)
        mask = UInt(maxCount - 1)
        assert(_buffer.count == capacity)
    }

    public func push(_ value: Item, generation: UInt64? = nil, accepting: (() -> Bool)? = nil) {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyed, generation == nil || generation == _generation,
              accepting?() != false else { return }
        if _buffer[Int(tailIndex & mask)] != nil {
            assertionFailure("value is not nil of headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
        }
        _buffer[Int(tailIndex & mask)] = value
        queuedBytes += max(0, sizeOf(value))
        queuedDuration += measuredDuration(value)
        if sorted {
            // 不用sort进行排序，这个比较高效
            var index = tailIndex
            while index > headIndex {
                guard let item = _buffer[Int((index - 1) & mask)] else {
                    assertionFailure("value is nil of index: \((index - 1) & mask) headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count),  mask: \(mask)")
                    break
                }
                if item.timestamp <= _buffer[Int(index & mask)]!.timestamp {
                    break
                }
                _buffer.swapAt(Int((index - 1) & mask), Int(index & mask))
                index -= 1
            }
        }
        tailIndex &+= 1
        if _count >= maxCount {
            if expanding {
                // No more room left for another append so grow the buffer now.
                _doubleCapacity()
            } else {
                condition.wait()
            }
        } else {
            // 只有数据了。就signal。因为有可能这是最后的数据了。
            if _count == 1 {
                condition.signal()
            }
        }
    }

    public func pop(wait: Bool = false, where predicate: ((Item, Int) -> Bool)? = nil) -> Item? {
        condition.lock()
        defer { condition.unlock() }
        if destroyed {
            return nil
        }
        if headIndex == tailIndex {
            if wait {
                if wakePending { wakePending = false; return nil }
                condition.wait()
                wakePending = false
                if destroyed || headIndex == tailIndex {
                    return nil
                }
            } else {
                return nil
            }
        }
        let index = Int(headIndex & mask)
        guard let item = _buffer[index] else {
            assertionFailure("value is nil of index: \(index) headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
            return nil
        }
        if let predicate, !predicate(item, _count) {
            return nil
        } else {
            headIndex &+= 1
            _buffer[index] = nil
            queuedBytes -= max(0, sizeOf(item))
            queuedDuration -= measuredDuration(item)
            if _count == maxCount >> 1 {
                condition.signal()
            }
            return item
        }
    }

    /// A decoder-control callback can arrive before the worker begins waiting.
    /// Preserve that wake until pop observes it, even with no media packet.
    func wake() {
        condition.lock()
        wakePending = true
        condition.signal()
        condition.unlock()
    }

    public func search(where predicate: (Item) -> Bool) -> [Item] {
        condition.lock()
        defer { condition.unlock() }
        var i = headIndex
        var result = [Item]()
        while i < tailIndex {
            if let item = _buffer[Int(i & mask)] {
                if predicate(item) {
                    result.append(item)
                    // Free every slot the head advances over, not only the match.
                    //
                    // Skipped items end up *behind* `headIndex`, so nothing reads
                    // them again — but leaving them non-nil permanently occupies
                    // their ring slot. After `initialCapacity` such leaks
                    // `tailIndex` wraps onto a still-occupied slot and `push`
                    // trips its "value is not nil" assertion.
                    //
                    // Reachable from ordinary playback: `FFmpegAssetTrack.search(for:)`
                    // matches only the subtitle cues due at the polled instant, so
                    // every cue stepped over leaks a slot. On a film with embedded
                    // subtitles the 255-slot queue fills within 10-15 minutes and
                    // the app traps on KSPlayer_MEPlayerItem_read.
                    while headIndex <= i {
                        if let removed = _buffer[Int(headIndex & mask)] {
                            queuedBytes -= max(0, sizeOf(removed))
                            queuedDuration -= measuredDuration(removed)
                        }
                        _buffer[Int(headIndex & mask)] = nil
                        headIndex &+= 1
                    }
                }
            } else {
                assertionFailure("value is nil of index: \(i) headIndex: \(headIndex), tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
                return result
            }
            i += 1
        }
        return result
    }

    /// Samples timed cues without consuming cues that are still on screen. Expired cues are
    /// compacted out even when they overlap a longer active cue, releasing their ring slots.
    /// Ordinary `search(where:)` keeps its consuming behavior for its existing callers.
    public func search(inspecting inspect: ((Item) -> Void)? = nil,
                       removing expired: (Item) -> Bool, where predicate: (Item) -> Bool) -> [Item] {
        condition.lock()
        defer { condition.unlock() }
        // Observe the complete locked snapshot before discarding anything. A timed display
        // update can replace an indefinite predecessor even when that update already ended
        // before the first poll; dropping it first would lose the replacement boundary.
        if let inspect {
            for index in headIndex ..< tailIndex {
                if let item = _buffer[Int(index & mask)] { inspect(item) }
            }
        }
        var result = [Item]()
        var writeIndex = headIndex
        let previousTail = tailIndex
        for readIndex in headIndex ..< previousTail {
            let readSlot = Int(readIndex & mask)
            guard let item = _buffer[readSlot] else { continue }
            if expired(item) {
                queuedBytes -= max(0, sizeOf(item))
                queuedDuration -= measuredDuration(item)
                _buffer[readSlot] = nil
                continue
            }
            if predicate(item) { result.append(item) }
            if writeIndex != readIndex {
                _buffer[Int(writeIndex & mask)] = item
                _buffer[readSlot] = nil
            }
            writeIndex &+= 1
        }
        tailIndex = writeIndex
        if writeIndex != previousTail { condition.broadcast() }
        return result
    }

    public func flush(advanceGeneration: Bool = false, updating update: (() -> Void)? = nil) {
        condition.lock()
        defer { condition.unlock() }
        if advanceGeneration { _generation &+= 1 }
        update?()
        headIndex = 0
        tailIndex = 0
        queuedBytes = 0
        queuedDuration = 0
        _buffer.removeAll(keepingCapacity: !destroyed)
        _buffer.append(contentsOf: ContiguousArray<Item?>(repeating: nil, count: destroyed ? 1 : maxCount))
        condition.broadcast()
    }

    public func shutdown() {
        destroyed = true
        flush()
    }

    private func measuredDuration(_ item: Item) -> TimeInterval {
        let value = durationOf(item)
        return value.isFinite && value > 0 ? value : 0
    }

    private func _doubleCapacity() {
        var newBacking: ContiguousArray<Item?> = []
        let newCapacity = maxCount << 1 // Double the storage.
        precondition(newCapacity > 0, "Can't double capacity of \(_buffer.count)")
        assert(newCapacity % 2 == 0)
        newBacking.reserveCapacity(newCapacity)
        let head = Int(headIndex & mask)
        newBacking.append(contentsOf: _buffer[head ..< maxCount])
        if head > 0 {
            newBacking.append(contentsOf: _buffer[0 ..< head])
        }
        let repeatitionCount = newCapacity &- newBacking.count
        newBacking.append(contentsOf: repeatElement(nil, count: repeatitionCount))
        headIndex = 0
        tailIndex = UInt(newBacking.count &- repeatitionCount)
        _buffer = newBacking
        maxCount = newCapacity
        mask = UInt(maxCount - 1)
    }
}

extension FixedWidthInteger {
    /// Returns the next power of two.
    @inline(__always)
    func nextPowerOf2() -> Self {
        guard self != 0 else {
            return 1
        }
        return 1 << (Self.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
