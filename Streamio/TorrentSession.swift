import Foundation
import Observation

/// UI-facing wrapper around `TorrentStreamer`.
@MainActor
@Observable
final class TorrentSession {
    var progress = TorrentProgress(stage: "Starting…")
    private var streamer: TorrentStreamer?
    private var cancelled = false

    func start(infoHash: String, fileIdx: Int?, trackers: [String] = [], resumeFraction: Double? = nil) async throws -> URL {
        let s = try TorrentStreamer(infoHashHex: infoHash, fileIdx: fileIdx, extraTrackers: trackers)
        streamer = s
        let url = try await s.start(onProgress: { [weak self] p in
            Task { @MainActor in if self?.cancelled == false { self?.progress = p } }
        }, resumeFraction: resumeFraction)
        if cancelled { await s.stop(); throw TorrentError.cancelled }
        return url
    }

    func stop() {
        cancelled = true
        if let s = streamer { Task { await s.stop() } }
        streamer = nil
    }
}
