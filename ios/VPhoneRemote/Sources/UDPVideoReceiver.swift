import Foundation
import Network

/// Receives video over UDP, reassembling fragments and repairing losses with
/// the parity the sender includes.
///
/// UDP because a lost packet on TCP stalls everything behind it while it
/// retransmits — and by the time that data lands it's stale anyway. Here a loss
/// is just a hole: usually filled by parity, and otherwise handled by asking
/// for a keyframe rather than by waiting.
///
/// The connection dials *out* to the bridge and keeps itself alive with hello
/// datagrams, so the phone never needs to be reachable. That's what makes this
/// work on cellular and behind NAT.
final class UDPVideoReceiver {
    private static let headerBytes = 23
    private static let fragmentPayload = 1100
    private static let fecGroupSize = 10
    private static let fecGroupSizeCritical = 4
    private static let deltaFrameType: UInt8 = 3

    /// Mirrors `fecGroupSize` in the bridge's videoPackets.ts: keyframes and
    /// parameter sets are sent with smaller groups, so they carry more parity.
    /// Both sides derive it from the frame type in the header -- if this ever
    /// disagrees with the sender, groups misalign and repair silently stops
    /// working, so the two must change together.
    private static func groupSize(forFrameType frameType: UInt8) -> Int {
        frameType == deltaFrameType ? fecGroupSize : fecGroupSizeCritical
    }
    /// Frames older than this are never going to complete; holding them just
    /// grows memory and delays the keyframe request that actually fixes things.
    private static let frameTimeout: TimeInterval = 0.25

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "vphone.udp.video", qos: .userInteractive)
    private var helloTimer: DispatchSourceTimer?
    private let sessionId: String

    private var frames: [UInt32: PendingFrame] = [:]
    private var lastCompleted: UInt32 = 0

    /// A fully reassembled frame: type, capture timestamp, sequence, payload.
    var onFrame: ((UInt8, UInt64, UInt32, Data) -> Void)?
    /// A frame was lost beyond repair; the decoder needs a keyframe.
    var onUnrecoverableLoss: (() -> Void)?
    /// First successful datagram — the caller can stop using the fallback.
    var onActive: (() -> Void)?

    private var sawTraffic = false

    private struct PendingFrame {
        var fragments: [Int: Data] = [:]
        var parity: [Int: Data] = [:]
        var fragCount: Int
        var frameLen: Int
        var frameType: UInt8
        var captureMs: UInt64
        let startedAt: Date
    }

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func start(host: String, port: UInt16) {
        let endpoint = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let connection = NWConnection(host: endpoint, port: nwPort, using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.sendHello() }
        }
        connection.start(queue: queue)
        receiveNext()

        // Repeated because the mapping the bridge learns from our source
        // address is what NAT keeps open; it expires if we go quiet.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.sendHello()
            self?.expireStaleFrames()
        }
        timer.resume()
        helloTimer = timer
    }

    func stop() {
        helloTimer?.cancel()
        helloTimer = nil
        connection?.cancel()
        connection = nil
        frames.removeAll()
    }

    private func sendHello() {
        let hello = Data("VPHONE1 \(sessionId)".utf8)
        connection?.send(content: hello, completion: .contentProcessed { _ in })
    }

    private func receiveNext() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(datagram: data) }
            if error == nil { self.receiveNext() }
        }
    }

    private static let helloPrefix = Data("VPHONE1".utf8)

    private func handle(datagram: Data) {
        // The bridge echoes our hello back to confirm the path. Identify it by
        // prefix, never by length: a hello is longer than the video header, so
        // a length check parses it as a frame, and its leading bytes ("VPHO")
        // read as sequence 1448101967 -- which then rejects every real frame
        // as stale and freezes the picture permanently.
        if datagram.starts(with: Self.helloPrefix) {
            if !sawTraffic {
                sawTraffic = true
                onActive?()
            }
            return
        }
        guard datagram.count >= Self.headerBytes else { return }

        let base = datagram.startIndex
        func u16(_ offset: Int) -> Int {
            Int(datagram[base + offset]) << 8 | Int(datagram[base + offset + 1])
        }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(datagram[base + offset + $1]) }
        }

        let frameSeq = u32(0)
        let fragIndex = u16(4)
        let fragCount = u16(6)
        let groupIndex = u16(8)
        let flags = datagram[base + 10]
        let isParity = (flags & 1) == 1
        let frameType = (flags >> 1) & 0x3
        let frameLen = Int(u32(11))
        let captureMs = (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(datagram[base + 15 + $1]) }
        let payload = Data(datagram[(base + Self.headerBytes)...])

        guard fragCount > 0, frameLen > 0 else { return }
        // Frames already delivered would otherwise be rebuilt by late stragglers.
        guard frameSeq > lastCompleted || lastCompleted == 0 else { return }

        if !sawTraffic {
            sawTraffic = true
            onActive?()
        }

        var pending = frames[frameSeq] ?? PendingFrame(
            fragCount: fragCount, frameLen: frameLen,
            frameType: frameType, captureMs: captureMs, startedAt: Date()
        )
        if isParity { pending.parity[groupIndex] = payload }
        else { pending.fragments[fragIndex] = payload }
        frames[frameSeq] = pending

        tryComplete(frameSeq)
    }

    private func tryComplete(_ frameSeq: UInt32) {
        guard var pending = frames[frameSeq] else { return }

        if pending.fragments.count < pending.fragCount {
            repairGroups(&pending)
            frames[frameSeq] = pending
        }
        guard pending.fragments.count == pending.fragCount else { return }

        var frame = Data(capacity: pending.fragCount * Self.fragmentPayload)
        for index in 0..<pending.fragCount {
            guard let fragment = pending.fragments[index] else { return }
            frame.append(fragment)
        }
        frames.removeValue(forKey: frameSeq)
        lastCompleted = frameSeq

        // Older frames still pending are already dead: `handle` drops anything
        // at or below `lastCompleted`, so their missing fragments can never be
        // accepted even if they show up. Leaving them for `expireStaleFrames`
        // only delays the keyframe request that unfreezes the picture -- by the
        // 250ms timeout plus up to a second of waiting for that timer to tick.
        // Reporting it here costs nothing and makes recovery immediate.
        let abandoned = frames.keys.filter { $0 < frameSeq }
        for seq in abandoned { frames.removeValue(forKey: seq) }

        onFrame?(pending.frameType, pending.captureMs, frameSeq, frame.prefix(pending.frameLen))
        if !abandoned.isEmpty { onUnrecoverableLoss?() }
    }

    /// XOR parity recovers exactly one missing fragment per group.
    private func repairGroups(_ pending: inout PendingFrame) {
        let size = Self.groupSize(forFrameType: pending.frameType)
        let groupCount = Int((Double(pending.fragCount) / Double(size)).rounded(.up))
        for group in 0..<groupCount {
            let first = group * size
            let last = min(first + size, pending.fragCount)
            let missing = (first..<last).filter { pending.fragments[$0] == nil }
            guard missing.count == 1, let parity = pending.parity[group] else { continue }

            var recovered = [UInt8](parity)
            for index in first..<last where index != missing[0] {
                guard let fragment = pending.fragments[index] else { continue }
                for byte in 0..<min(recovered.count, fragment.count) {
                    recovered[byte] ^= fragment[fragment.startIndex + byte]
                }
            }
            pending.fragments[missing[0]] = Data(recovered)
        }
    }

    private func expireStaleFrames() {
        let now = Date()
        let stale = frames.filter { now.timeIntervalSince($0.value.startedAt) > Self.frameTimeout }
        guard !stale.isEmpty else { return }
        for (seq, _) in stale {
            frames.removeValue(forKey: seq)
            lastCompleted = max(lastCompleted, seq)
        }
        onUnrecoverableLoss?()
    }
}
