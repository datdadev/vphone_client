import AVFoundation
import MediaPlayer
import UIKit

/// Turns the phone's hardware volume buttons into the guest's volume buttons.
///
/// iOS exposes no API for reading hardware buttons directly, so this works the
/// only way available: it watches the system output volume, infers a press from
/// the direction it moved, and immediately restores it. Keeping the volume
/// pinned mid-scale is what makes repeated presses possible — at 0 or 1 the
/// value stops changing and further presses become invisible.
///
/// Side effects worth knowing: this takes over the phone's own volume while the
/// app is foregrounded, and it needs an active audio session.
final class VolumeButtonInterceptor: NSObject {
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    /// Our own corrections change the volume too; without this they'd be read
    /// back as presses and loop.
    private var isRestoring = false
    private static let baseline: Float = 0.5

    func start(in view: UIView) {
        // Off-screen but present: an MPVolumeView in the hierarchy suppresses
        // the system volume HUD that would otherwise cover the guest's screen.
        let volumeView = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
        volumeView.alpha = 0.001
        view.addSubview(volumeView)
        self.volumeView = volumeView

        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[volume] audio session unavailable: \(error.localizedDescription)")
            return
        }

        restoreBaseline(after: 0.1)

        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self, !self.isRestoring,
                  let new = change.newValue, let old = change.oldValue
            else { return }

            let delta = new - old
            guard abs(delta) > 0.001 else { return }

            DispatchQueue.main.async {
                if delta > 0 { self.onVolumeUp?() } else { self.onVolumeDown?() }
            }
            self.restoreBaseline(after: 0.05)
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func restoreBaseline(after delay: TimeInterval) {
        isRestoring = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first {
                slider.value = Self.baseline
            }
            // Long enough for the resulting change to land and be ignored.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.isRestoring = false
            }
        }
    }
}
