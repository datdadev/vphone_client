import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Receives and decodes video off the main thread.
///
/// Deliberately not `@MainActor`: SwiftUI gesture callbacks run on the main
/// thread, so doing 60fps of packet parsing and CMSampleBuffer construction
/// there put every touch behind a queue of video work. Nothing here needs the
/// main thread -- `AVSampleBufferDisplayLayer.enqueue` is safe to call from a
/// background queue.
final class VideoPipeline: @unchecked Sendable {
    private let decodeQueue = DispatchQueue(label: "vphone.video.decode", qos: .userInteractive)
    private let decoder = VideoDecoder()
    private let lock = NSLock()

    private var _isVideoActive = false
    private var _displayView: VideoDisplayUIView?

    /// Fallback path: JPEG stills still need the main actor to publish a UIImage.
    var onStillImage: ((UIImage) -> Void)?
    /// Reports measured end-to-end video latency (capture -> about to display).
    var onVideoLatency: ((Double) -> Void)?
    /// Frames were lost; the host needs to send a keyframe to resync.
    var onNeedKeyFrame: (() -> Void)?

    /// Frames queued for decode. Unbounded async enqueueing is a latency trap:
    /// if decode falls behind even slightly, the backlog grows forever and the
    /// picture drifts seconds into the past while still looking perfectly
    /// smooth. Dropping is the only way to stay current.
    private var _queuedPackets = 0
    private static let maxQueuedPackets = 2

    /// Counted at both ends of the pipeline, because "the picture looks like
    /// 30fps" doesn't say whether frames are missing before they arrive or
    /// being dropped here to stay current -- and those have opposite fixes.
    private var _framesIn = 0
    private var _framesDecoded = 0

    /// Stutter is about spacing, not count: 60 evenly spaced frames look smooth,
    /// 60 bunched ones don't. Gaps are measured twice -- between host capture
    /// times and between our own display calls -- because a gap present in both
    /// came from the guest, while one that appears only in the second was added
    /// by the network or by us.
    private var _pendingCaptureMs: UInt64 = 0
    private var _lastCaptureMs: UInt64 = 0
    private var _lastShownMs: Double = 0
    private var _sourceHitches = 0
    private var _displayHitches = 0
    private var _worstGapMs = 0
    /// Well past the 16.7ms a 60fps frame gets, so only a skipped beat counts.
    private static let hitchThresholdMs = 25.0

    struct FrameStats {
        var arrived = 0
        var decoded = 0
        var sourceHitches = 0
        var displayHitches = 0
        var worstGapMs = 0
    }

    /// Stats since the last call, which this resets.
    func drainFrameStats() -> FrameStats {
        lock.withLock {
            defer {
                _framesIn = 0; _framesDecoded = 0
                _sourceHitches = 0; _displayHitches = 0; _worstGapMs = 0
            }
            return FrameStats(
                arrived: _framesIn, decoded: _framesDecoded,
                sourceHitches: _sourceHitches, displayHitches: _displayHitches,
                worstGapMs: _worstGapMs
            )
        }
    }

    init() {
        decoder.onCaptureTimestamp = { [weak self] captureMs in
            guard let self else { return }
            let nowMs = Date().timeIntervalSince1970 * 1000
            self.lock.withLock { self._pendingCaptureMs = captureMs }
            self.onVideoLatency?(nowMs - Double(captureMs))
        }
        decoder.onFrameGap = { [weak self] in
            self?.onNeedKeyFrame?()
        }
        decoder.onSampleBuffer = { [weak self] sampleBuffer in
            guard let self else { return }
            let nowMs = Date().timeIntervalSince1970 * 1000
            self.lock.lock()
            let view = self._displayView
            self._framesDecoded += 1

            let capture = self._pendingCaptureMs
            if self._lastShownMs > 0 {
                let gap = nowMs - self._lastShownMs
                if gap > Self.hitchThresholdMs { self._displayHitches += 1 }
                self._worstGapMs = max(self._worstGapMs, Int(gap.rounded()))
            }
            if self._lastCaptureMs > 0, capture > self._lastCaptureMs,
               Double(capture - self._lastCaptureMs) > Self.hitchThresholdMs {
                self._sourceHitches += 1
            }
            self._lastShownMs = nowMs
            self._lastCaptureMs = capture
            self.lock.unlock()
            view?.enqueue(sampleBuffer)
        }
    }

    var isVideoActive: Bool {
        get { lock.withLock { _isVideoActive } }
        set { lock.withLock { _isVideoActive = newValue } }
    }

    func attach(displayView: VideoDisplayUIView?) {
        lock.withLock { _displayView = displayView }
    }

    func reset() {
        decodeQueue.async { [weak self] in self?.decoder.reset() }
    }

    /// Called straight from the WebSocket receive callback -- never hops to main.
    func handleBinary(_ data: Data) {
        if isVideoActive {
            // Keyframes and parameter sets are never dropped -- losing them
            // breaks decoding until the next GOP.
            let isCritical = data.first.map { $0 != 3 } ?? true
            lock.lock()
            _framesIn += 1
            let backlogged = _queuedPackets >= Self.maxQueuedPackets
            if backlogged && !isCritical {
                lock.unlock()
                return
            }
            _queuedPackets += 1
            lock.unlock()

            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.decoder.handlePacket(data)
                self.lock.lock()
                self._queuedPackets -= 1
                self.lock.unlock()
            }
            return
        }
        decodeQueue.async { [weak self] in
            guard let self, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { self.onStillImage?(image) }
        }
    }
}
