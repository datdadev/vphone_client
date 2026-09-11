import SwiftUI
import UIKit

/// Raw UIKit touch handling, replacing SwiftUI's DragGesture/MagnifyGesture.
///
/// Three reasons this exists:
///  - Latency: SwiftUI's gesture system arbitrates between recognizers before
///    delivering a value. `touchesBegan/Moved/Ended` fire as soon as UIKit has
///    the event, which is the shortest path from glass to socket.
///  - Measurement: UITouch carries a `timestamp` on the same clock as
///    `systemUptime`, so we can report the true glass-to-handler delay rather
///    than inferring it.
///  - Real multitouch: every finger arrives with its own identity, so pinch is
///    actual two-finger tracking instead of synthesizing symmetric points
///    around an anchor from a scale factor.
final class TouchOverlayUIView: UIView {
    var connection: ConnectionManager?

    /// Stable per-finger index for the host's multi-touch protocol. UITouch
    /// instances are the identity UIKit gives us; they're reused, so slots are
    /// freed on end/cancel.
    private var touchSlots: [ObjectIdentifier: Int] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: "down")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: "move")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: "up")
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Must still release, or the guest is left with a finger pressed down.
        send(touches, phase: "up")
        release(touches)
    }

    private func slot(for touch: UITouch) -> Int {
        let key = ObjectIdentifier(touch)
        if let existing = touchSlots[key] { return existing }
        let used = Set(touchSlots.values)
        var index = 0
        while used.contains(index) { index += 1 }
        touchSlots[key] = index
        return index
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches { touchSlots.removeValue(forKey: ObjectIdentifier(touch)) }
    }

    private func send(_ touches: Set<UITouch>, phase: String) {
        guard let connection else { return }

        var payload: [(id: Int, phase: String, x: CGFloat, y: CGFloat)] = []
        var oldestTimestamp = Double.greatestFiniteMagnitude

        for touch in touches {
            let location = touch.location(in: self)
            let mapped = Self.mapToVM(location, viewSize: bounds.size, screen: connection.screenSize)
            payload.append((id: slot(for: touch), phase: phase, x: mapped.x, y: mapped.y))
            oldestTimestamp = min(oldestTimestamp, touch.timestamp)
        }
        guard !payload.isEmpty else { return }

        // Glass-to-handler delay: how long UIKit took to deliver this event.
        if oldestTimestamp < .greatestFiniteMagnitude {
            let delayMs = (ProcessInfo.processInfo.systemUptime - oldestTimestamp) * 1000
            connection.reportInputLatency(delayMs)
        }

        connection.multiTouch(payload, isMove: phase == "move")
    }

    /// Matches the aspect-fit letterbox of the video layer beneath this overlay.
    static func mapToVM(_ point: CGPoint, viewSize: CGSize, screen: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0, screen.width > 0, screen.height > 0 else {
            return .zero
        }
        let screenAspect = screen.width / screen.height
        let viewAspect = viewSize.width / viewSize.height

        let displayed: CGSize = screenAspect > viewAspect
            ? CGSize(width: viewSize.width, height: viewSize.width / screenAspect)
            : CGSize(width: viewSize.height * screenAspect, height: viewSize.height)

        let originX = (viewSize.width - displayed.width) / 2
        let originY = (viewSize.height - displayed.height) / 2

        let nx = (point.x - originX) / displayed.width
        let ny = (point.y - originY) / displayed.height

        return CGPoint(
            x: min(max(nx, 0), 1) * screen.width,
            y: min(max(ny, 0), 1) * screen.height
        )
    }
}

struct TouchOverlay: UIViewRepresentable {
    let connection: ConnectionManager

    func makeUIView(context: Context) -> TouchOverlayUIView {
        let view = TouchOverlayUIView()
        view.connection = connection
        return view
    }

    func updateUIView(_ uiView: TouchOverlayUIView, context: Context) {
        uiView.connection = connection
    }
}
