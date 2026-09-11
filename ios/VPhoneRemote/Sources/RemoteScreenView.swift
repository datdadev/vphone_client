import SwiftUI

struct RemoteScreenView: View {
    @EnvironmentObject var connection: ConnectionManager
    @State private var keyboardActive = false
    @State private var showStats = false

    var body: some View {
        VStack(spacing: 0) {
            // The guest screen gets its own space rather than sitting under the
            // controls: at the VM's aspect ratio there's no letterbox to hide
            // buttons in, so overlaying them covered real content.
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

                    if showStats {
                        VStack {
                            HStack {
                                Spacer()
                                statsReadout
                            }
                            Spacer()
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                    }
                }
            }

            controlBar
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onDisappear { connection.stopStreaming() }
        .overlay {
            // Zero-sized: it exists only to own the keyboard and receive keystrokes.
            KeyboardInput(isActive: $keyboardActive, connection: connection)
                .frame(width: 0, height: 0)
        }
    }

    private var statsReadout: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("net \(Int(connection.networkRTT))ms")
            Text("touch \(Int(connection.touchRTT))ms")
            Text("input \(Int(connection.inputLatency))ms")
            Text("video \(Int(connection.videoLatency))ms")
            Text(connection.isUsingUDP ? "udp" : "tcp")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            barButton("xmark") { connection.disconnect() }
            keyButton("lock.fill", .power)
            keyButton("house.fill", .home)
            keyButton("speaker.wave.1.fill", .voldown)
            keyButton("speaker.wave.3.fill", .volup)
            barButton(keyboardActive ? "keyboard.chevron.compact.down" : "keyboard") {
                keyboardActive.toggle()
            }
            barButton("chart.bar") { showStats.toggle() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func barButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(.thinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
    }

    private func keyButton(_ systemImage: String, _ key: HardwareKey) -> some View {
        barButton(systemImage) { connection.pressKey(key) }
    }
}
