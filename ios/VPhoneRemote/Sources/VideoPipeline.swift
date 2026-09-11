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

    /// Frames queued for decode. Unbounded async enqueueing is a latency trap:
    /// if decode falls behind even slightly, the backlog grows forever and the
    /// picture drifts seconds into the past while still looking perfectly
    /// smooth. Dropping is the only way to stay current.
    private var _queuedPackets = 0
    private static let maxQueuedPackets = 2

    init() {
        decoder.onCaptureTimestamp = { [weak self] captureMs in
            guard let self else { return }
            let nowMs = Date().timeIntervalSince1970 * 1000
            self.onVideoLatency?(nowMs - Double(captureMs))
        }
        decoder.onSampleBuffer = { [weak self] sampleBuffer in
            guard let self else { return }
            self.lock.lock()
            let view = self._displayView
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
