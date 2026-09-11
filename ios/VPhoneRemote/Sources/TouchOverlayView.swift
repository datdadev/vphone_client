import SwiftUI
import UIKit

/// Raw UIKit touch handling, forwarding every finger to the guest.
///
/// Three reasons this exists rather than SwiftUI gestures:
///  - Latency: SwiftUI arbitrates between recognizers before delivering a
///    value. `touchesBegan/Moved/Ended` fire as soon as UIKit has the event.
///  - Measurement: UITouch carries a `timestamp` on the same clock as
///    `systemUptime`, so the glass-to-handler delay can be measured.
///  - Real multitouch: every finger arrives with its own identity, instead of
///    a scale factor that has to be reverse-engineered into finger positions.
final class TouchOverlayUIView: UIView {
    var connection: ConnectionManager?

    private struct Tracked {
        let slot: Int
        var location: CGPoint
        var phase: String
    }

    /// Every finger currently down. UIKit hands us only the touches that
    /// *changed* in a given event, but a multitouch frame has to describe all
    /// active contacts -- sending a partial set makes the guest see the
    /// untouched fingers lift and land again, which breaks pinch outright.
    private var active: [ObjectIdentifier: Tracked] = [:]

    /// Where each finger started, for recognising the home gesture.
    private var startLocations: [ObjectIdentifier: CGPoint] = [:]
    /// One home per gesture, however far the fingers keep travelling.
    private var homeSent = false

    /// Guided Access stops iOS claiming the bottom edge, so the real one-finger
    /// swipe up reaches the app and can be used exactly as on a real phone.
    /// The zone is shallow there, matching how iOS reserves only its very
    /// bottom edge: scrolling a list up from near the bottom is ordinary, and a
    /// deep zone would fire home constantly.
    private static let guidedHomeZone: CGFloat = 26
    private static let guidedHomeTravel: CGFloat = 55

    /// Without Guided Access, iOS takes single-finger edge swipes for itself
    /// and backgrounds the app before the guest sees anything. Multi-finger
    /// edge swipes it ignores, so two fingers is the fallback that survives.
    private static let fallbackHomeZone: CGFloat = 160
    private static let fallbackHomeTravel: CGFloat = 70

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let location = touch.location(in: self)
            active[ObjectIdentifier(touch)] = Tracked(
                slot: nextFreeSlot(), location: location, phase: "down"
            )
            startLocations[ObjectIdentifier(touch)] = location
        }
        emit(latency: oldestTimestamp(touches))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard var tracked = active[key] else { continue }
            tracked.location = touch.location(in: self)
            tracked.phase = "move"
            active[key] = tracked
        }

        if !homeSent, detectHomeGesture() {
            homeSent = true
            connection?.pressKey(.home)
            // Release the fingers on the guest: they were a command to us, not
            // a drag for it, and leaving them down would scroll whatever is
            // underneath.
            liftAllOnGuest()
            return
        }

        emit(latency: oldestTimestamp(touches))
    }

    /// A swipe up from the bottom edge. One finger when Guided Access is on
    /// (iOS isn't competing for that edge), two fingers otherwise.
    private func detectHomeGesture() -> Bool {
        let height = bounds.height
        guard height > 0, !active.isEmpty else { return false }

        let guided = UIAccessibility.isGuidedAccessEnabled
        let zone = guided ? Self.guidedHomeZone : Self.fallbackHomeZone
        let travel = guided ? Self.guidedHomeTravel : Self.fallbackHomeTravel

        // Multi-finger gestures are pinches and pans; only claim them when the
        // single-finger swipe isn't available to us.
        guard guided ? active.count == 1 : active.count >= 2 else { return false }

        for (key, tracked) in active {
            guard let start = startLocations[key] else { return false }
            guard start.y > height - zone else { return false }
            guard start.y - tracked.location.y > travel else { return false }
        }
        return true
    }

    private func liftAllOnGuest() {
        guard let connection, !active.isEmpty else { return }
        let payload = active.values.sorted { $0.slot < $1.slot }.map { tracked in
            let mapped = Self.mapToVM(tracked.location, viewSize: bounds.size, screen: connection.screenSize)
            return (id: tracked.slot, phase: "up", x: mapped.x, y: mapped.y)
        }
        connection.multiTouch(payload)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Must still lift, or the guest keeps a finger pressed forever.
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard var tracked = active[key] else { continue }
            tracked.location = touch.location(in: self)
            tracked.phase = "up"
            active[key] = tracked
        }
        // A consumed home gesture already released these on the guest.
        if !homeSent { emit(latency: oldestTimestamp(touches)) }
        for touch in touches {
            active.removeValue(forKey: ObjectIdentifier(touch))
            startLocations.removeValue(forKey: ObjectIdentifier(touch))
        }
        if active.isEmpty { homeSent = false }
    }

    private func nextFreeSlot() -> Int {
        let used = Set(active.values.map(\.slot))
        var slot = 0
        while used.contains(slot) { slot += 1 }
        return slot
    }

    private func oldestTimestamp(_ touches: Set<UITouch>) -> Double? {
        touches.map(\.timestamp).min()
    }

    /// Sends the complete state of every finger, not just the changed ones.
    private func emit(latency touchTimestamp: Double?) {
        guard let connection, !active.isEmpty else { return }

        let payload = active.values
            .sorted { $0.slot < $1.slot }
            .map { tracked -> (id: Int, phase: String, x: CGFloat, y: CGFloat) in
                let mapped = Self.mapToVM(
                    tracked.location, viewSize: bounds.size, screen: connection.screenSize
                )
                return (id: tracked.slot, phase: tracked.phase, x: mapped.x, y: mapped.y)
            }

        if let touchTimestamp {
            let delayMs = (ProcessInfo.processInfo.systemUptime - touchTimestamp) * 1000
            connection.reportInputLatency(delayMs)
        }

        // Only rate-limit frames where every finger is merely moving: a frame
        // carrying a down or up changes which contacts exist and can't be
        // dropped. Because each frame is now complete state rather than a
        // delta, dropping a move frame loses nothing but an intermediate
        // position.
        let allMoving = payload.allSatisfy { $0.phase == "move" }
        connection.multiTouch(payload, isMove: allMoving)

        // A finger reported as "down" is continuing from the next frame on.
        for (key, var tracked) in active where tracked.phase == "down" {
            tracked.phase = "move"
            active[key] = tracked
        }
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
