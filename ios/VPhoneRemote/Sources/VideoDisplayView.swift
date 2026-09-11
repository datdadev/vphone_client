import AVFoundation
import SwiftUI
import UIKit

/// Hardware-decoded HEVC output surface.
final class VideoDisplayUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // A decode error leaves the layer permanently failed -- flush and let
        // the next keyframe restart it rather than showing a frozen picture.
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        // Backpressure: if the layer isn't draining, enqueueing anyway just
        // grows its internal queue, and the picture falls steadily further
        // behind while still looking smooth. Skip the frame instead.
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sampleBuffer)
    }
}

struct VideoDisplayView: UIViewRepresentable {
    let connection: ConnectionManager

    func makeUIView(context: Context) -> VideoDisplayUIView {
        let view = VideoDisplayUIView()
        connection.videoPipeline.attach(displayView: view)
        return view
    }

    func updateUIView(_ uiView: VideoDisplayUIView, context: Context) {}

    static func dismantleUIView(_ uiView: VideoDisplayUIView, coordinator: ()) {
        uiView.displayLayer.flushAndRemoveImage()
    }
}
