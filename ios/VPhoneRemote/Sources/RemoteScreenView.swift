import SwiftUI
import UIKit

struct RemoteScreenView: View {
    @EnvironmentObject var connection: ConnectionManager
    @State private var keyboardActive = false
    @State private var showControls = false
    @State private var guidedAccess = UIAccessibility.isGuidedAccessEnabled

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if connection.isVideoActive {
                    VideoDisplayView(connection: connection)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let image = connection.latestImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView("Connecting to virtual phone…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }

                TouchOverlay(connection: connection)
                    .frame(width: geo.size.width, height: geo.size.height)

                overlay
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // The guest is itself an iPhone, so its own gestures should reach it:
        // a swipe up from the bottom is the guest's home gesture, not ours.
        // Without this iOS swallows that edge for its own app switcher.
        .defersSystemGestures(on: .bottom)
        .onDisappear { connection.stopStreaming() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.guidedAccessStatusDidChangeNotification
        )) { _ in
            guidedAccess = UIAccessibility.isGuidedAccessEnabled
        }
        .overlay {
            // Zero-sized hosts: one owns the keyboard and receives keystrokes,
            // the other redirects the phone's volume buttons to the guest.
            ZStack {
                KeyboardInput(isActive: $keyboardActive, connection: connection)
                VolumeButtonBridge(connection: connection)
            }
            .frame(width: 0, height: 0)
        }
    }

    /// The window's own safe area. `geo.safeAreaInsets` reports zero here --
    /// the whole hierarchy ignores the safe area so the video can run edge to
    /// edge -- so it has to be read from UIKit instead.
    private static var windowSafeArea: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first { $0.isKeyWindow }?.safeAreaInsets
            ?? scene?.windows.first?.safeAreaInsets
            ?? .zero
    }

    /// Clearance for the display's rounded corners. The safe area does not
    /// cover this: in portrait the leading inset is zero, so a button pinned
    /// to the top left still lands inside the curve.
    ///
    /// Applied to both axes, and deliberately *not* the safe area's top inset.
    /// The notch is centred, so a button in the corner never has to clear it --
    /// insetting by the full notch height only pushed the controls needlessly
    /// far down the screen. For a ~55pt corner radius the curve admits a point
    /// at roughly 18pt on the diagonal, so this leaves a little margin.
    private static let cornerClearance: CGFloat = 20

    /// Everything the guest can't do for itself, kept out of the way behind a
    /// single button. Video and touches deliberately cover the whole screen,
    /// so this row has to inset itself -- see `cornerClearance`.
    private var overlay: some View {
        VStack {
            HStack(alignment: .top) {
                // Home is the one control reached for constantly, so it gets
                // the always-visible button rather than being two taps deep.
                // The rest stay behind a long press: a menu toggle here would
                // put the common case behind the rare one.
                Image(systemName: showControls ? "xmark" : "house.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(showControls ? 0.55 : 0.25), in: Circle())
                    .contentShape(Circle())
                    .onTapGesture {
                        if showControls {
                            withAnimation(.easeOut(duration: 0.15)) { showControls = false }
                        } else {
                            connection.pressKey(.home)
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.35) {
                        withAnimation(.easeOut(duration: 0.15)) { showControls.toggle() }
                    }

                if showControls {
                    controls
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Spacer()

                if showControls { statsReadout }
            }
            .padding(.leading, Self.windowSafeArea.left + Self.cornerClearance)
            .padding(.trailing, Self.windowSafeArea.right + Self.cornerClearance)
            .padding(.top, Self.cornerClearance)

            Spacer()
        }
    }

    /// Volume stays here too: interception needs an audio session that iOS can
    /// refuse, so there has to be a way to work without it.
    private var controls: some View {
        HStack(spacing: 8) {
            controlButton("square.on.square") { connection.pressKey(.appSwitcher) }
            controlButton("speaker.wave.1.fill") { connection.pressKey(.voldown) }
            controlButton("speaker.wave.3.fill") { connection.pressKey(.volup) }
            controlButton(keyboardActive ? "keyboard.chevron.compact.down" : "keyboard") {
                keyboardActive.toggle()
            }
            controlButton("xmark.circle") { connection.disconnect() }
        }
    }

    private func controlButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.55), in: Circle())
        }
    }

    private var statsReadout: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("net \(Int(connection.networkRTT))ms")
            Text("input \(Int(connection.inputLatency))ms")
            Text("video \(Int(connection.videoLatency))ms")
            // arrived/decoded: a low first number means frames never reached
            // us, a gap between them means we dropped them to stay current.
            Text("fps \(connection.arrivedFPS)/\(connection.decodedFPS)")
            // Skipped intervals: src came from the guest, dsp was added after.
            Text("hitch \(connection.sourceHitches)/\(connection.displayHitches)")
            Text("worst \(connection.worstGapMs)ms")
            Text(connection.isUsingUDP ? "udp" : "tcp")
            // Which home gesture is live right now.
            Text(guidedAccess ? "home: 1-finger" : "home: 2-finger")
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.white)
        .padding(5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        .allowsHitTesting(false)
    }
}
