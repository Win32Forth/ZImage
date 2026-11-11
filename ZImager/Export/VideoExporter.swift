import AVFoundation
import Foundation

/// Fraction of a video export, written from the export queue and read on the main actor.
nonisolated final class VideoExportMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction = 0.0

    func store(_ value: Double) {
        lock.lock()
        fraction = value
        lock.unlock()
    }

    func load() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return fraction
    }
}

nonisolated enum VideoExportError: LocalizedError {
    case cannotExport

    var errorDescription: String? {
        "This video could not be exported."
    }
}

/// Writes a new MPEG-4 movie. Tone is baked into the picture. The source file is not changed.
nonisolated enum VideoExporter {
    static func write(
        source: URL,
        tone: ToneState,
        to destination: URL,
        meter: VideoExportMeter
    ) async throws {
        let asset = AVURLAsset(url: source)
        let preset = try await preset(for: asset)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoExportError.cannotExport
        }
        let grade = VideoGradeBox()
        grade.store(tone)
        let filter = VideoFrameFilter(grade: grade)
        let composition = try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            filter.apply(parameters)
        }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        let states = session.states(updateInterval: 0.5)
        let watch = Task {
            for await state in states {
                if case .exporting(let progress) = state {
                    meter.store(progress.fractionCompleted)
                }
            }
        }
        defer { watch.cancel() }
        let scratch = destination.deletingLastPathComponent()
            .appendingPathComponent(".zimage-\(UUID().uuidString).mp4")
        do {
            try await session.export(to: scratch, as: .mp4)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        meter.store(1)
    }

    /// HEVC at the source size when the file can take it, otherwise the highest H.264 preset.
    private static func preset(for asset: AVAsset) async throws -> String {
        if await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetHEVCHighestQuality,
            with: asset,
            outputFileType: .mp4
        ) {
            return AVAssetExportPresetHEVCHighestQuality
        }
        if await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetHighestQuality,
            with: asset,
            outputFileType: .mp4
        ) {
            return AVAssetExportPresetHighestQuality
        }
        throw VideoExportError.cannotExport
    }
}
