import AVKit
import SwiftUI

/// The system player, fitted in the image view, with play, pause, and the scrub bar.
struct VideoCanvasPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.updatesNowPlayingInfoCenter = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard view.player !== player else { return }
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}
