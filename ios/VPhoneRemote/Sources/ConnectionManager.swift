import AVFoundation
import CoreMedia
import Foundation
import UIKit

@MainActor
final class ConnectionManager: NSObject, ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    @Published var status: Status = .disconnected
    @Published var latestImage: UIImage?
    /// Coordinate space for touch commands, as reported by the host with each
    /// screenshot. Deliberately NOT inferred from the received image size: the
    /// host downscales frames by a factor it's free to change, and duplicating
    /// that constant here silently breaks every touch coordinate when it does.
    @Published var screenSize: CGSize = CGSize(width: 1290, height: 2796)

    var host: String {
        get { UserDefaults.standard.string(forKey: "vphone.bridge.host") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vphone.bridge.host") }
    }
    var port: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "vphone.bridge.port")
            return value == 0 ? 8787 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: "vphone.bridge.port") }
    }

    /// Two independent connections on purpose. Sharing one TCP socket with the
    /// 5.5Mbps video stream meant a single lost video packet head-of-line
    /// blocked touch input for a full retransmission timeout (~260ms observed),
    /// delivering a whole gesture in one late burst.
    private var controlTask: URLSessionWebSocketTask?
    private var videoTask: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var manuallyDisconnected = false
    private var isStreaming = false
    /// Command type of the status frame we're waiting to pair with an
    /// incoming binary image frame (see the bridge's two-frame protocol).
    private var pendingImageFrameType: String?

    /// Hardware HEVC path. Frames go straight to an AVSampleBufferDisplayLayer
    /// via this sink rather than through @Published (a UIImage per frame at
    /// 60fps would thrash SwiftUI's diffing for no benefit).
    let videoPipeline = VideoPipeline()
    @Published var isVideoActive = false
    /// True once video is arriving over UDP rather than the WebSocket fallback.
    @Published var isUsingUDP = false

    private var udpReceiver: UDPVideoReceiver?
    private let udpSessionId = UUID().uuidString

    /// Live diagnostics so latency questions get answered with numbers instead
    /// of guesses: networkRTT is phone<->bridge only (no VM work), touchRTT is
    /// the full path including injection into the guest.
    @Published var networkRTT: Double = 0
    @Published var touchRTT: Double = 0
    /// Glass-to-handler delay measured from UITouch.timestamp -- catches delay
    /// that happens before we ever timestamp and send the event.
    @Published var inputLatency: Double = 0
    /// End-to-end video latency: host capture -> ready to display on screen.
    @Published var videoLatency: Double = 0
    private var pingTimer: Timer?
    private var pendingTouchSentAt: Double?

    func connect(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        KeychainStore.save(token: token)
        manuallyDisconnected = false
        reconnectAttempt = 0
        openSocket(host: host, port: port, token: token)
    }

    func disconnect() {
        manuallyDisconnected = true
        isStreaming = false
        pingTimer?.invalidate()
        pingTimer = nil
        reconnectWorkItem?.cancel()
        udpReceiver?.stop()
        udpReceiver = nil
        isUsingUDP = false
        controlTask?.cancel(with: .goingAway, reason: nil)
        videoTask?.cancel(with: .goingAway, reason: nil)
        controlTask = nil
        videoTask = nil
        status = .disconnected
    }

    /// Continuously requests the next frame as soon as the previous one arrives,
    /// self-paced by round-trip latency instead of a fixed timer -- gives the
    /// fastest feed the current link can sustain without a request backlog.
    func startStreaming() {
        guard !isStreaming else { return }
        isStreaming = true
        requestScreenshot()
    }

    func stopStreaming() {
        isStreaming = false
    }

    /// Requests the host's hardware HEVC stream: native resolution at 60fps for
    /// a fraction of the bandwidth the JPEG still path needed, because a phone
    /// UI barely changes between frames and interframe compression exploits that.
    func startVideo() {
        videoPipeline.reset()
        startUDPReceiver()
        videoPipeline.onNeedKeyFrame = { [weak self] in
            DispatchQueue.main.async { self?.requestKeyFrame() }
        }
        videoPipeline.onVideoLatency = { [weak self] ms in
            DispatchQueue.main.async {
                guard let self else { return }
                self.videoLatency = self.videoLatency == 0 ? ms : (self.videoLatency * 0.9 + ms * 0.1)
            }
        }
        videoPipeline.onStillImage = { [weak self] image in
            guard let self else { return }
            self.latestImage = image
            if self.isStreaming { self.requestScreenshot() }
        }
        sendOnVideo([
            "t": "videoStream", "fps": videoFrameRate, "scale": videoScale,
            "bitrate": videoBitRate, "udpSession": udpSessionId,
        ])
    }

    func reportInputLatency(_ ms: Double) {
        // Smoothed: per-event values are noisy, the trend is what matters.
        inputLatency = inputLatency == 0 ? ms : (inputLatency * 0.8 + ms * 0.2)
    }

    /// Video prefers UDP; the bridge keeps using the WebSocket until our hellos
    /// start arriving, so a network that blocks UDP degrades instead of failing.
    private func startUDPReceiver() {
        udpReceiver?.stop()
        let receiver = UDPVideoReceiver(sessionId: udpSessionId)
        receiver.onActive = { [weak self] in
            DispatchQueue.main.async { self?.isUsingUDP = true }
        }
        receiver.onFrame = { [weak self] type, captureMs, sequence, payload in
            // Rebuild the framing the decoder expects, matching the WS path.
            // The real sequence is passed through so the decoder's own gap
            // detection still works as a second line of defence behind the
            // receiver's reassembly timeout.
            guard let self else { return }
            var packet = Data([type])
            withUnsafeBytes(of: captureMs.bigEndian) { packet.append(contentsOf: $0) }
            withUnsafeBytes(of: sequence.bigEndian) { packet.append(contentsOf: $0) }
            packet.append(payload)
            self.videoPipeline.handleBinary(packet)
        }
        receiver.onUnrecoverableLoss = { [weak self] in
            DispatchQueue.main.async { self?.requestKeyFrame() }
        }
        receiver.start(host: host, port: UInt16(port + 1))
        udpReceiver = receiver
    }

    private func sendOnVideo(_ command: [String: Any]) {
        guard let videoTask, let data = try? JSONSerialization.data(withJSONObject: command),
              let text = String(data: data, encoding: .utf8)
        else { return }
        videoTask.send(.string(text)) { _ in }
    }

    private func startPinging() {
        pingTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.send(["t": "ping", "ts": Date().timeIntervalSince1970 * 1000])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func openSocket(host: String, port: Int, token: String) {
        guard var components = URLComponents(string: "ws://\(host):\(port)") else {
            status = .error("invalid host")
            return
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            status = .error("invalid host")
            return
        }

        status = .connecting
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        let control = session.webSocketTask(with: url)
        controlTask = control
        control.resume()

        let video = session.webSocketTask(with: url)
        videoTask = video
        video.resume()
    }

    /// Runs entirely off the main actor. Binary (video) frames go straight to
    /// the decode queue; only status frames and error handling hop to main.
    /// Routing every frame through @MainActor previously starved SwiftUI's
    /// gesture callbacks, which made touch input lag behind the video stream.
    private nonisolated static func receiveLoop(
        task: URLSessionWebSocketTask,
        pipeline: VideoPipeline?,
        manager: ConnectionManager?
    ) {
        task.receive { result in
            switch result {
            case .failure(let error):
                Task { @MainActor in manager?.handleReceiveFailure(error) }
            case .success(let message):
                switch message {
                case .data(let data):
                    pipeline?.handleBinary(data)
                case .string(let text):
                    Task { @MainActor in manager?.handleStatusFrame(text) }
                @unknown default:
                    break
                }
                receiveLoop(task: task, pipeline: pipeline, manager: manager)
            }
        }
    }

    fileprivate func handleReceiveFailure(_ error: Error) {
        isStreaming = false
        status = .error(error.localizedDescription)
        scheduleReconnect()
    }

    fileprivate func handleStatusFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let response = try? JSONDecoder().decode(BridgeResponse.self, from: data)
        else { return }

        if let width = response.screenWidth, let height = response.screenHeight,
           width > 0, height > 0 {
            screenSize = CGSize(width: width, height: height)
        }

        if response.t == "pong", let sent = response.ts {
            networkRTT = Date().timeIntervalSince1970 * 1000 - sent
            return
        }

        if response.t == "touch" || response.t == "multiTouch", let sentAt = pendingTouchSentAt {
            touchRTT = Date().timeIntervalSince1970 * 1000 - sentAt
            pendingTouchSentAt = nil
            return
        }

        if response.t == "videoStream" {
            isVideoActive = response.ok
            videoPipeline.isVideoActive = response.ok
            if !response.ok {
                // Host refused or the stream died -- fall back to JPEG stills so
                // the user still gets a picture rather than a black screen.
                isVideoActive = false
                startStreaming()
            }
            return
        }

        if response.hasImage == true {
            // Binary frame with the actual JPEG bytes follows immediately;
            // continuing the stream happens once that frame lands.
            pendingImageFrameType = response.t
        } else if response.t == "screenshot", isStreaming {
            requestScreenshot()
        }
    }

    private func scheduleReconnect() {
        guard !manuallyDisconnected else { return }
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1
        let delay = min(Double(reconnectAttempt) * 1.5, 10)
        let host = self.host
        let port = self.port
        guard let token = KeychainStore.load() else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.openSocket(host: host, port: port, token: token)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Commands

    func send(_ command: [String: Any]) {
        guard let task = controlTask, let data = try? JSONSerialization.data(withJSONObject: command),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.status = .error(error.localizedDescription)
                self?.scheduleReconnect()
            }
        }
    }

    /// HEVC stream settings. scale 1 = native resolution, affordable now that
    /// frames are interframe-compressed instead of standalone JPEGs.
    @Published var videoScale: Int = 1
    /// Fixed at 60. Capture reads the guest's IOSurface, which costs the guest
    /// nothing, and the pipeline delivers every frame the guest produces (~60fps
    /// during animation) -- so a lower rate would only drop frames, and a higher
    /// one would poll for frames that don't exist.
    let videoFrameRate: Int = 60
    @Published var videoBitRate: Int = 12_000_000

    /// Retained for the JPEG fallback path (see requestScreenshot).
    @Published var streamScale: Int = 2
    @Published var streamQuality: Double = 0.5

    func requestScreenshot() {
        send(["t": "screenshot", "screen": true, "scale": streamScale, "quality": streamQuality])
    }

    /// screen:false on these -- the continuous stream (see startStreaming) already
    /// keeps the view current, so we skip paying for a redundant capture+encode
    /// on every single touch.
    ///
    /// Live single-finger touch (tap/scroll/pan): send down once, move on every
    /// finger update, up once -- instead of batching one canned swipe replay at
    /// gesture end, which is what made scrolling feel disconnected from the
    /// actual finger motion. Requires vphone-cli's "touch" command (patched in;
    /// see the accompanying host patch notes).
    func touchDown(x: CGFloat, y: CGFloat) {
        pendingTouchSentAt = Date().timeIntervalSince1970 * 1000
        send(["t": "touch", "phase": "down", "x": x, "y": y, "screen": false,
              "ts": Date().timeIntervalSince1970 * 1000])
    }

    /// Caps outgoing "move" frames. Matched to the touch digitizer's sampling
    /// rate rather than below it: pinch is judged on the relative positions of
    /// two fingers, so under-sampling shows up as jerky zooming. Frames
    /// carrying a down or up are never throttled.
    private var lastMoveSentAt: CFAbsoluteTime = 0
    private let minMoveInterval: CFAbsoluteTime = 1.0 / 120.0

    private func throttledMove(_ body: () -> Void) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMoveSentAt >= minMoveInterval else { return }
        lastMoveSentAt = now
        body()
    }

    func touchMove(x: CGFloat, y: CGFloat) {
        throttledMove {
            send(["t": "touch", "phase": "move", "x": x, "y": y, "screen": false,
                  "ts": Date().timeIntervalSince1970 * 1000])
        }
    }

    func touchUp(x: CGFloat, y: CGFloat) {
        send(["t": "touch", "phase": "up", "x": x, "y": y, "screen": false,
              "ts": Date().timeIntervalSince1970 * 1000])
    }

    /// Simultaneous multi-finger touch (pinch/rotate) -- all touches in the
    /// array move together in a single combined event on the host side.
    func multiTouch(
        _ touches: [(id: Int, phase: String, x: CGFloat, y: CGFloat)],
        isMove: Bool = false
    ) {
        let payload = touches.map { ["id": $0.id, "phase": $0.phase, "x": $0.x, "y": $0.y] as [String: Any] }
        let command: [String: Any] = [
            "t": "multiTouch", "touches": payload, "screen": false,
            "ts": Date().timeIntervalSince1970 * 1000,
        ]
        if !isMove { pendingTouchSentAt = Date().timeIntervalSince1970 * 1000 }
        // down/up must never be dropped -- a swallowed "up" strands the finger.
        if isMove {
            throttledMove { send(command) }
        } else {
            send(command)
        }
    }

    func pressKey(_ key: HardwareKey) {
        send(["t": "key", "name": key.rawValue, "screen": false])
    }

    /// Real keystrokes into the guest's virtual keyboard. Distinct from
    /// setClipboard, which only stages text for a manual paste.
    func typeText(_ text: String) {
        send(["t": "typeText", "text": text])
    }

    /// Rate-limited: a burst of dropped frames would otherwise fire one request
    /// per lost frame, and a keyframe is expensive.
    private var lastKeyFrameRequest: Date = .distantPast
    func requestKeyFrame() {
        guard Date().timeIntervalSince(lastKeyFrameRequest) > 0.25 else { return }
        lastKeyFrameRequest = Date()
        send(["t": "requestKeyFrame"])
    }

    func typeBackspace() {
        send(["t": "typeText", "text": "\u{8}"])
    }

    func setClipboard(text: String) {
        send(["t": "type", "text": text, "screen": false])
    }
}

extension ConnectionManager: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // Fires once per connection now that control and video are separate.
        Task { @MainActor in
            if webSocketTask === self.controlTask {
                self.status = .connected
                self.reconnectAttempt = 0
                Self.receiveLoop(task: webSocketTask, pipeline: nil, manager: self)
                self.startPinging()
            } else if webSocketTask === self.videoTask {
                Self.receiveLoop(task: webSocketTask, pipeline: self.videoPipeline, manager: self)
                self.startVideo()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        Task { @MainActor in
            self.isStreaming = false
            guard !self.manuallyDisconnected else { return }
            self.status = .error("connection closed (\(closeCode.rawValue))")
            self.scheduleReconnect()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.isStreaming = false
            guard !self.manuallyDisconnected else { return }
            self.status = .error(error.localizedDescription)
            self.scheduleReconnect()
        }
    }
}
