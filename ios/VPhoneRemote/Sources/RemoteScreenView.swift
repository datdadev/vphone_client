import SwiftUI

struct RemoteScreenView: View {
    @EnvironmentObject var connection: ConnectionManager
    @State private var keyboardActive = false
    @State private var showControls = false

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

    /// Everything the guest can't do for itself, kept out of the way: a single
    /// dot until tapped. Home and lock are deliberately absent -- the guest
    /// handles those through its own gestures and hardware behaviour.
    private var overlay: some View {
        VStack {
            HStack(alignment: .top) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showControls.toggle() }
                } label: {
                    Image(systemName: showControls ? "xmark" : "ellipsis")
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(showControls ? 0.55 : 0.25), in: Circle())
                }

                if showControls {
                    controls
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Spacer()

                if showControls { statsReadout }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Spacer()
        }
    }

    /// Volume stays here too: interception needs an audio session that iOS can
    /// refuse, so there has to be a way to work without it.
    private var controls: some View {
        HStack(spacing: 8) {
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
            Text(connection.isUsingUDP ? "udp" : "tcp")
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.white)
        .padding(5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        .allowsHitTesting(false)
    }
}
