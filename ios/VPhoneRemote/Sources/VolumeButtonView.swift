import SwiftUI
import UIKit

/// Hosts the volume interceptor, which needs a real view in the hierarchy for
/// its hidden MPVolumeView to suppress the system volume HUD.
struct VolumeButtonBridge: UIViewRepresentable {
    let connection: ConnectionManager

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false

        let interceptor = VolumeButtonInterceptor()
        interceptor.onVolumeUp = { connection.pressKey(.volup) }
        interceptor.onVolumeDown = { connection.pressKey(.voldown) }
        context.coordinator.interceptor = interceptor

        // The view has no window until it's in the hierarchy, and MPVolumeView
        // only suppresses the HUD once it is.
        DispatchQueue.main.async { interceptor.start(in: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.interceptor?.stop()
    }

    final class Coordinator {
        var interceptor: VolumeButtonInterceptor?
    }
}
