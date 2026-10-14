import SwiftUI
import AVKit

struct PlayerView: UIViewControllerRepresentable {
    let url: URL
    /// Seconds to resume from (Continue Watching). Nil = start at 0.
    var resumeFrom: Double? = nil
    /// Called periodically with (positionSeconds, durationSeconds).
    var onProgress: ((Double, Double) -> Void)? = nil
    /// Called when the item fails to load (e.g. an expired debrid link), so
    /// the host can surface the error and refresh the stream list. Before
    /// build 18 a dead URL here was a silent black screen.
    var onError: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let player = AVPlayer(url: url)
        vc.player = player
        let coordinator = context.coordinator
        coordinator.onProgress = onProgress
        coordinator.onError = onError
        // One status observer serves both jobs: apply the resume seek when
        // the item is ready, and surface load failures.
        var pendingSeek: Double? = (resumeFrom ?? 0) > 0 ? resumeFrom : nil
        coordinator.seekApplied = pendingSeek == nil
        coordinator.seekObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak player] item, _ in
            switch item.status {
            case .readyToPlay:
                if let seek = pendingSeek {
                    pendingSeek = nil
                    player?.seek(to: CMTime(seconds: seek, preferredTimescale: 600)) { _ in
                        coordinator.seekApplied = true
                    }
                }
            case .failed:
                coordinator.onError?(item.error?.localizedDescription ?? "Playback failed")
            default:
                break
            }
        }
        // Periodic progress for Continue Watching (~every 5s). While a
        // resume seek is unapplied the clock sits near 0; reporting it
        // would erase the saved position, so hold reports until it lands.
        let interval = CMTime(seconds: 5, preferredTimescale: 600)
        context.coordinator.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak player] time in
            guard let player, let item = player.currentItem else { return }
            let dur = item.duration.seconds
            guard dur.isFinite, dur > 0 else { return }
            guard coordinator.seekApplied else { return }
            onProgress?(time.seconds, dur)
        }
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        if let player = vc.player, let obs = coordinator.timeObserver {
            player.removeTimeObserver(obs)
        }
        coordinator.seekObserver?.invalidate()
        // Final progress save (skipped while a resume seek never landed —
        // saving ~0 would erase the stored position).
        if coordinator.seekApplied, let player = vc.player, let item = player.currentItem {
            let dur = item.duration.seconds
            if dur.isFinite, dur > 0 {
                coordinator.onProgress?(player.currentTime().seconds, dur)
            }
        }
        vc.player?.pause()
    }

    final class Coordinator {
        var timeObserver: Any?
        var seekObserver: NSKeyValueObservation?
        var onProgress: ((Double, Double) -> Void)?
        var onError: ((String) -> Void)?
        var seekApplied = true
    }
}
