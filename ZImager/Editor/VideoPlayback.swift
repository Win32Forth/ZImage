import AVFoundation
import CoreImage

/// The tone the player applies. The main actor writes it. The frame queue reads it.
nonisolated final class VideoGradeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tone = ToneState.identity

    func store(_ tone: ToneState) {
        lock.lock()
        self.tone = tone
        lock.unlock()
    }

    func load() -> ToneState {
        lock.lock()
        defer { lock.unlock() }
        return tone
    }
}

/// Core Image context for video frames. The composition queue is its only caller.
nonisolated final class VideoFrameFilter: @unchecked Sendable {
    let grade: VideoGradeBox
    private let context: CIContext

    init(grade: VideoGradeBox) {
        self.grade = grade
        context = TonePipeline.makeContext()
    }

    func apply(_ parameters: AVCIImageFilteringParameters) -> AVCIImageFilteringResult {
        let extent = parameters.sourceImage.extent
        guard extent.isNull == false, extent.isInfinite == false, extent.width >= 1, extent.height >= 1 else {
            return AVCIImageFilteringResult(resultImage: parameters.sourceImage, ciContext: context)
        }
        let source = parameters.sourceImage.cropped(to: extent)
        let edge = max(extent.width, extent.height)
        let graded = TonePipeline.apply(base: source, tone: grade.load(), longEdge: edge)
        return AVCIImageFilteringResult(resultImage: graded, ciContext: context)
    }
}

/// One movie in the image view. Tone changes show on the next frame.
@MainActor
final class VideoPlayback {
    let player: AVPlayer
    let sourceKey: String
    /// A small frame for the Spectrum graph and Auto.
    let poster: CIImage?
    private let grade: VideoGradeBox
    private let filter: VideoFrameFilter

    private init(player: AVPlayer, sourceKey: String, poster: CIImage?, grade: VideoGradeBox, filter: VideoFrameFilter) {
        self.player = player
        self.sourceKey = sourceKey
        self.poster = poster
        self.grade = grade
        self.filter = filter
    }

    func setTone(_ tone: ToneState) {
        grade.store(tone)
    }

    var isPlaying: Bool { player.rate > 0 }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// Nil when the file has no picture AVFoundation can play.
    static func make(url: URL, tone: ToneState) async -> VideoPlayback? {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let playable: Bool
        do {
            playable = try await asset.load(.isPlayable)
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            return nil
        }
        guard playable, !tracks.isEmpty else { return nil }
        let grade = VideoGradeBox()
        grade.store(tone)
        let filter = VideoFrameFilter(grade: grade)
        let composition: AVVideoComposition
        do {
            composition = try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
                filter.apply(parameters)
            }
        } catch {
            return nil
        }
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = composition
        let player = AVPlayer(playerItem: item)
        player.preventsDisplaySleepDuringVideoPlayback = true
        let poster = await posterFrame(of: asset)
        return VideoPlayback(
            player: player,
            sourceKey: FolderEntry.cacheKey(for: url),
            poster: poster,
            grade: grade,
            filter: filter
        )
    }

    private static func posterFrame(of asset: AVAsset) async -> CIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return CIImage(cgImage: image)
    }
}
