import SwiftUI
import VLCKit

/// VLC-backed player for torrent-served URLs (127.0.0.1 local HTTP server)
/// and direct https URLs in containers AVPlayer cannot play (MKV, AVI, ...).
/// Failures surface via alert — silent black screens are banned.
struct VLCPlayerView: UIViewControllerRepresentable {
    let url: URL
    @Binding var errorMessage: String?
    /// Seconds to resume from (Continue Watching). Nil = start at 0.
    var resumeFrom: Double? = nil
    /// Called periodically with (positionSeconds, durationSeconds).
    var onProgress: ((Double, Double) -> Void)? = nil
    /// For OpenSubtitles lookup: (catalog type, video id, e.g. "series", "tt26545992:1:8").
    var subtitleVideo: (type: String, videoId: String)? = nil
    /// Called when the Done button is tapped — must nil out the presented item.
    var onDone: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> VLCPlayerViewController {
        let vc = VLCPlayerViewController()
        vc.errorMessage = Binding(
            get: { errorMessage },
            set: { errorMessage = $0 }
        )
        // Store the URL; playback starts in viewDidAppear. Starting playback
        // or timers inside makeUIViewController (during SwiftUI's layout pass)
        // traps (Timer.publish EXC_BREAKPOINT, seen 2026-10-12).
        vc.pendingURL = url
        vc.resumeFrom = resumeFrom
        vc.onProgress = onProgress
        vc.subtitleVideo = subtitleVideo
        // Done button must dismiss the cover: without this the tap stops the
        // player but playURL stays non-nil and the screen never closes
        // (bug seen 2026-10-12).
        vc.onDismiss = onDone
        vc.loadViewIfNeeded()
        return vc
    }

    func updateUIViewController(_ vc: VLCPlayerViewController, context: Context) {}
}

final class VLCPlayerViewController: UIViewController {
    private let player = VLCMediaPlayer()
    private let delegateProxy = VLCDelegateProxy()
    private let videoView = UIView()
    /// Full-screen transparent UIControl between the video and the chrome.
    /// THE tap target for overlay toggling (see setupControls).
    private let tapCatcher = UIControl()
    private let controlsView = UIView()
    private let playPauseButton = UIButton(type: .system)
    #if os(iOS)
    private let scrubSlider = UISlider()
    #else
    // UISlider does not exist on tvOS: a progress bar shows position,
    // and seeking happens with Left/Right remote presses (see
    // pressesBegan) while the overlay is hidden.
    private let progressBar = UIProgressView(progressViewStyle: .default)
    #endif
    private let timeLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let subtitleButton = UIButton(type: .system)
    private let hideButton = UIButton(type: .system)
    private var didApplyTrackPrefs = false
    private var lastAudioCount = 0
    private var lastTextCount = 0
    private var timeObserver: Timer?
    var errorMessage: Binding<String?> = .constant(nil)
    var onDismiss: (() -> Void)?
    /// URL to play once the view appears (set by makeUIViewController).
    var pendingURL: URL?
    /// Resume position in seconds (Continue Watching). Applied after playback starts.
    var resumeFrom: Double?
    /// Periodic progress reports (positionSeconds, durationSeconds).
    var onProgress: ((Double, Double) -> Void)?
    /// For OpenSubtitles lookup: (catalog type, video id).
    var subtitleVideo: (type: String, videoId: String)?
    private var pendingSeek: Double?
    /// Confirmed-seek tracking (build 18): a seek counts as applied only
    /// when the player's clock lands within 2s of the target. A one-shot
    /// position set against a slow torrent source can be silently dropped
    /// while VLC opens (simulator-verified: clock parked at the seek
    /// target, no new HTTP request ever issued, playback never resumes —
    /// Barklee's "press play / scrub and it doesn't come back").
    private var seekTarget: Double?
    private var seekRequestedAt: Date?
    private var seekRebuilt = false
    private var lastSeekClock: Double = -1
    #if os(tvOS)
    /// Siri Remote touch-surface scrub state (build 19): the position
    /// where the current pan began, and the live preview target while
    /// dragging (nil when not scrubbing).
    private var panScrubStart: Double = 0
    private var panScrubTarget: Double?
    #endif
    /// The URL currently loaded, kept for input rebuilds.
    private var currentURL: URL?
    private var progressTick = 0
    /// Explicit overlay state — the single source of truth for show/hide.
    /// Build 16 bug: toggle direction was read from `controlsView.alpha`
    /// and the tap recognizer sat on `videoView` (the VLC drawable); once
    /// hidden, taps never brought the overlay back. Direction now comes
    /// only from this flag, taps come from the UIControl catcher, and
    /// every show/hide path goes through `setOverlayVisible`.
    private var overlayVisible = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideoView()
        setupControls()
        delegateProxy.vc = self
        player.delegate = delegateProxy
        player.drawable = videoView
    }

    private func setupVideoView() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupControls() {
        // Tap-to-toggle catcher (iOS). A transparent UIControl layered
        // ABOVE the video view and BELOW all chrome (added first in this
        // method; every control added after sits on top of it).
        //
        // Why not a UITapGestureRecognizer (builds 16–17)? VERIFIED DEAD
        // in the simulator 2026-10-12: with the recognizer on videoView
        // (16) and then on the root view (17), the delegate's
        // shouldReceive fired for every tap (hit view =
        // VLCSampleBufferSubpictureView) yet the recognizer NEVER
        // recognized — a competing recognizer in the VLC/SwiftUI subview
        // chain wins exclusivity and forces ancestor tap recognizers to
        // fail. UIControls don't use the recognizer system at all: they
        // receive touches by direct hit-test delivery (the Done/hide
        // buttons always worked), so a UIControl catcher toggles
        // deterministically on sim and device alike.
        #if os(iOS)
        tapCatcher.backgroundColor = .clear
        tapCatcher.translatesAutoresizingMaskIntoConstraints = false
        tapCatcher.addTarget(self, action: #selector(toggleControls), for: .touchUpInside)
        view.addSubview(tapCatcher)
        NSLayoutConstraint.activate([
            tapCatcher.topAnchor.constraint(equalTo: view.topAnchor),
            tapCatcher.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tapCatcher.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tapCatcher.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        #endif

        // Top bar: Done button + hide-overlay button
        doneButton.setTitle("Done", for: .normal)
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(doneButton)

        hideButton.setImage(UIImage(systemName: "eye.slash"), for: .normal)
        hideButton.tintColor = .white
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        hideButton.addTarget(self, action: #selector(hideOverlayTapped), for: .touchUpInside)
        view.addSubview(hideButton)

        // Bottom controls
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.addSubview(controlsView)

        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        controlsView.addSubview(playPauseButton)

        #if os(iOS)
        scrubSlider.translatesAutoresizingMaskIntoConstraints = false
        scrubSlider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        controlsView.addSubview(scrubSlider)
        #else
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.progressTintColor = .white
        progressBar.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        controlsView.addSubview(progressBar)
        #endif

        timeLabel.textColor = .white
        timeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.text = "0:00 / 0:00"
        controlsView.addSubview(timeLabel)

        subtitleButton.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        subtitleButton.tintColor = .white
        subtitleButton.translatesAutoresizingMaskIntoConstraints = false
        subtitleButton.addTarget(self, action: #selector(subtitleTapped), for: .touchUpInside)
        controlsView.addSubview(subtitleButton)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = .white
        activityIndicator.isUserInteractionEnabled = false
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            hideButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hideButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hideButton.widthAnchor.constraint(equalToConstant: 32),
            hideButton.heightAnchor.constraint(equalToConstant: 32),

            controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            controlsView.heightAnchor.constraint(equalToConstant: 64),

            playPauseButton.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 12),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsView.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 32),

            timeLabel.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: controlsView.centerYAnchor),

            subtitleButton.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),
            subtitleButton.centerYAnchor.constraint(equalTo: controlsView.centerYAnchor),
            subtitleButton.widthAnchor.constraint(equalToConstant: 32),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // Scrub control constraints: #if can't split the array literal
        // above, so these activate at statement level.
        #if os(iOS)
        NSLayoutConstraint.activate([
            scrubSlider.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 8),
            scrubSlider.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -8),
            scrubSlider.centerYAnchor.constraint(equalTo: controlsView.centerYAnchor),
        ])
        #else
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 8),
            progressBar.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -8),
            progressBar.centerYAnchor.constraint(equalTo: controlsView.centerYAnchor),
        ])
        // Siri Remote touch-surface scrub (build 19): pan gestures from
        // the remote's touch surface land on this view; see handlePanScrub.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanScrub(_:)))
        view.addGestureRecognizer(pan)
        #endif
    }

    func startPlayback(url: URL) {
        activityIndicator.startAnimating()
        currentURL = url
        guard let media = VLCMedia(url: url) else { return }
        // Resume (build 18): register the target with the confirmed-seek
        // driver in updateTime(), and set the position BEFORE play when
        // the duration is already known. NOTE: the start-time media
        // option is ignored by this VLCKit build (simulator seek matrix,
        // Oct 12 2026) — position sets are the mechanism that lands.
        if let from = pendingSeek, from > 1 {
            seekTarget = from
            seekRequestedAt = Date()
            seekRebuilt = false
            lastSeekClock = -1
            pendingSeek = nil
        }
        player.media = media
        if let target = seekTarget {
            let len = Double(media.length.intValue) / 1000
            if len > 0 { player.position = min(max(target / len, 0), 0.99) }
        }
        player.play()
        startTimeObserver()
        fetchExternalSubtitles()
    }

    /// Re-opens the current URL, positioning the new input BEFORE play.
    /// Escape hatch for a seek that never lands: the wedged input issues
    /// no new requests, while a fresh input reads the target range at
    /// once (the local server serves a cold range in ~2s when asked).
    private func rebuildInput(at seconds: Double) {
        guard let url = currentURL, let media = VLCMedia(url: url) else { return }
        let len = Double(player.media?.length.intValue ?? 0) / 1000
        player.media = media
        if seconds > 1, len > 0 { player.position = min(max(seconds / len, 0), 0.99) }
        player.play()
        fetchExternalSubtitles()
    }

    private func startTimeObserver() {
        // Plain Timer, not Combine's Timer.publish: the publisher traps with
        // EXC_BREAKPOINT when created during SwiftUI's view-update pass.
        timeObserver?.invalidate()
        timeObserver = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateTime()
        }
    }

    private func updateTime() {
        let pos = player.position
        if pos.isFinite {
            #if os(iOS)
            scrubSlider.value = Float(pos)
            #else
            progressBar.progress = Float(pos)
            #endif
        }
        let cur = player.time.intValue / 1000
        let total = (player.media?.length.intValue ?? 0) / 1000
        var labelHandled = false
        #if os(tvOS)
        if let preview = panScrubTarget, total > 0 {
            // Scrub preview: show where the remote drag will land.
            timeLabel.text = "→ \(formatTime(Int32(preview))) / \(formatTime(total))"
            progressBar.progress = Float(preview / Double(total))
            labelHandled = true
        }
        #endif
        if !labelHandled, let target = seekTarget, total > 0 {
            // Buffering-the-moment-you-asked-for (build 19): while a seek
            // is unconfirmed, SAY so — spinner up and the label names the
            // target. Builds ≤18 stopped the spinner whenever VLC claimed
            // to be playing, so a wedged seek looked exactly like a frozen
            // app: no spinner, parked clock, no explanation.
            timeLabel.text = "⏳ \(formatTime(Int32(target))) / \(formatTime(total))"
        } else if !labelHandled {
            timeLabel.text = "\(formatTime(cur)) / \(formatTime(total))"
        }
        if seekTarget != nil {
            if !activityIndicator.isAnimating { activityIndicator.startAnimating() }
        } else if player.isPlaying {
            activityIndicator.stopAnimating()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
        // Confirmed-seek driver: a seek counts as applied only when the
        // clock is within 2s of the target AND advancing (or paused on
        // it). The wedge signature is a clock parked exactly AT the
        // target while playing — position alone never confirms that.
        // While unconfirmed: re-apply the position, and after 6s rebuild
        // the input (fresh input = fresh range requests).
        if let target = seekTarget, total > 0 {
            let curS = Double(player.time.intValue) / 1000
            let advanced = curS != lastSeekClock
            lastSeekClock = curS
            if abs(curS - target) <= 2, advanced || !player.isPlaying {
                seekTarget = nil
                seekRequestedAt = nil
            } else if player.isPlaying, let t0 = seekRequestedAt, !seekRebuilt {
                // Two rebuild triggers: the general one (6s unlanded) and
                // the wedge signature — clock parked exactly AT the target
                // while "playing" (build 18 evidence: the wedged input
                // never issues another request, so waiting buys nothing).
                // Rebuilding after ~2s of parked-at-target cuts the usual
                // scrub from ~7.8s to ~3.5s on this VLCKit build; a merely
                // slow seek is not harmed — the rebuilt input re-reads the
                // same range and the pieces arrive meanwhile.
                let waited = Date().timeIntervalSince(t0)
                let parkedAtTarget = abs(curS - target) <= 2 && !advanced
                if waited > 6 || (parkedAtTarget && waited > 2) {
                    seekRebuilt = true
                    seekRequestedAt = Date()
                    rebuildInput(at: target)
                } else if abs(curS - target) > 2 {
                    player.position = min(max(target / Double(total), 0), 0.99)
                }
            } else if player.isPlaying, abs(curS - target) > 2 {
                player.position = min(max(target / Double(total), 0), 0.99)
            }
        } else if let seek = pendingSeek, total > 0 {
            // Fallback: a programmatic seek startPlayback didn't consume.
            pendingSeek = nil
            seekTarget = seek
            seekRequestedAt = Date()
            seekRebuilt = false
            lastSeekClock = -1
            player.position = min(max(seek / Double(total), 0), 0.99)
        }
        // Throttled progress reports for Continue Watching (~every 5s).
        progressTick += 1
        if progressTick >= 10 {
            progressTick = 0
            reportProgress()
        }
        // Auto-select audio/subtitle tracks per Settings → Playback prefs.
        applyTrackPrefsIfNeeded()
    }

    private func reportProgress() {
        guard seekTarget == nil else { return }
        let total = (player.media?.length.intValue ?? 0) / 1000
        guard total > 0 else { return }
        let cur = Double(player.time.intValue / 1000)
        onProgress?(cur, Double(total))
    }

    // MARK: - Subtitles

    /// Fetches OpenSubtitles for the video (Stremio addon) and attaches the
    /// best English match as an external subtitle slave.
    private func fetchExternalSubtitles() {
        guard let sv = subtitleVideo else { return }
        let id = sv.videoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sv.videoId
        guard let apiURL = URL(string: "https://opensubtitles-v3.strem.io/subtitles/\(sv.type)/\(id).json") else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: apiURL)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let subs = json["subtitles"] as? [[String: Any]] else { return }
                // Prefer English; accept direct .srt/.vtt links only.
                let candidates = subs.filter { sub in
                    let url = (sub["url"] as? String ?? "").lowercased()
                    return url.hasSuffix(".srt") || url.hasSuffix(".vtt")
                }
                let pick = candidates.first { ($0["lang"] as? String ?? "").lowercased().hasPrefix("en") }
                    ?? candidates.first
                guard let chosen = pick,
                      let urlStr = chosen["url"] as? String,
                      let subURL = URL(string: urlStr) else { return }
                let (subData, _) = try await URLSession.shared.data(from: subURL)
                guard !subData.isEmpty else { return }
                let ext = urlStr.lowercased().hasSuffix(".vtt") ? "vtt" : "srt"
                let local = FileManager.default.temporaryDirectory
                    .appendingPathComponent("streamio-sub-\(UUID().uuidString).\(ext)")
                try subData.write(to: local)
                await MainActor.run {
                    // Appears in player.textTracks automatically.
                    self.player.addPlaybackSlave(local, type: .subtitle, enforce: true)
                }
            } catch {
                // Subtitles are best-effort; never fail playback over them.
            }
        }
    }

    @objc private func subtitleTapped() {
        pokeOverlay()
        let sheet = UIAlertController(title: "Subtitles", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Off", style: .default) { [weak self] _ in
            self?.player.deselectAllTextTracks()
        })
        // Embedded + external text tracks.
        let tracks = player.textTracks
        for (i, track) in tracks.enumerated() {
            let name = track.trackName.isEmpty ? "Track \(i + 1)" : track.trackName
            sheet.addAction(UIAlertAction(title: (track.isSelected ? "✓ " : "") + name, style: .default) { [weak self] _ in
                self?.player.selectTrack(at: i, type: .text)
            })
        }
        if tracks.isEmpty {
            sheet.message = "No subtitles available for this video."
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = subtitleButton
            pop.sourceRect = subtitleButton.bounds
        }
        present(sheet, animated: true)
    }

    private func formatTime(_ seconds: Int32) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @objc private func playPauseTapped() {
        if player.isPlaying {
            player.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else if player.state == .error {
            // play() on an errored input does not reliably restart it —
            // rebuild the input at the held position instead.
            activityIndicator.startAnimating()
            rebuildInput(at: seekTarget ?? Double(player.time.intValue) / 1000)
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        } else {
            player.play()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
        pokeOverlay()
    }

    #if os(iOS)
    @objc private func scrubChanged() {
        let total = Double((player.media?.length.intValue ?? 0) / 1000)
        if total > 0 {
            seekTarget = Double(scrubSlider.value) * total
            seekRequestedAt = Date()
            seekRebuilt = false
            lastSeekClock = -1
            pendingSeek = nil
        }
        player.position = Double(scrubSlider.value)
        pokeOverlay()
    }
    #endif

    #if os(tvOS)
    /// tvOS seek (no slider exists): ±10s via Left/Right remote presses.
    private func seekBy(_ seconds: Double) {
        let total = Double((player.media?.length.intValue ?? 0) / 1000)
        guard total > 0 else { return }
        let cur = Double(player.time.intValue / 1000)
        commitSeek(to: min(max(cur + seconds, 0), total * 0.99))
    }

    /// Registers a seek with the confirmed-seek driver and applies it.
    /// Every tvOS seek path (presses, pan scrub) funnels through here so
    /// they all inherit build 18's land-confirmation + input rebuild.
    private func commitSeek(to target: Double) {
        let total = Double((player.media?.length.intValue ?? 0) / 1000)
        guard total > 0 else { return }
        seekTarget = target
        seekRequestedAt = Date()
        seekRebuilt = false
        lastSeekClock = -1
        player.position = min(max(target / total, 0), 0.99)
        // Deliberately NO pokeOverlay() here: a +/-10s press while the
        // overlay is hidden used to force it visible, flipping the arrow
        // routing in pressesBegan to focus navigation and killing chained
        // seeks after the first press. The pan-scrub path pokes at .began
        // (its readout needs the overlay); presses do not.
    }

    /// Siri Remote touch-surface scrub: drag horizontally to move through
    /// the timeline with a live target readout in the time label; release
    /// commits ONE seek through the confirmed-seek driver. Builds ≤18 had
    /// no scrub at all on tvOS — only ±10s presses — so jumping to the
    /// middle of a two-hour movie took ~700 button presses.
    @objc private func handlePanScrub(_ g: UIPanGestureRecognizer) {
        let total = Double((player.media?.length.intValue ?? 0) / 1000)
        guard total > 0 else { return }
        switch g.state {
        case .began:
            panScrubStart = Double(player.time.intValue) / 1000
            panScrubTarget = panScrubStart
            pokeOverlay()
        case .changed:
            // ~800pt of drag sweeps the whole timeline.
            let delta = Double(g.translation(in: view).x) / 800.0 * total
            panScrubTarget = min(max(panScrubStart + delta, 0), total * 0.99)
        case .ended:
            if let target = panScrubTarget {
                panScrubTarget = nil
                commitSeek(to: target)
            }
        case .cancelled, .failed:
            panScrubTarget = nil
        default:
            break
        }
    }
    #endif

    @objc private func dismissTapped() {
        player.stop()
        onDismiss?()
    }

    // MARK: - Overlay show/hide (manual only — no auto-hide, no timers)

    @objc private func toggleControls() {
        #if DEBUG
        print("[overlay] toggle tapped, was visible=\(overlayVisible)")
        #endif
        setOverlayVisible(!overlayVisible)
    }

    @objc private func hideOverlayTapped() { setOverlayVisible(false) }

    private func hideOverlay() { setOverlayVisible(false) }
    private func showOverlay() { setOverlayVisible(true) }

    /// The ONE place overlay visibility changes. Sets the state flag,
    /// animates alpha to match, and — critically — disables interaction
    /// on the overlay views while hidden so they can never sit in the
    /// hit path and swallow the tap that should bring them back.
    private func setOverlayVisible(_ visible: Bool) {
        overlayVisible = visible
        #if DEBUG
        print("[overlay] setOverlayVisible(\(visible))")
        #endif
        controlsView.isUserInteractionEnabled = visible
        doneButton.isUserInteractionEnabled = visible
        hideButton.isUserInteractionEnabled = visible
        UIView.animate(withDuration: 0) {
            self.controlsView.alpha = visible ? 1 : 0
            self.doneButton.alpha = visible ? 1 : 0
            self.hideButton.alpha = visible ? 1 : 0
        }
        #if os(tvOS)
        // Focus engine: when the overlay hides, its buttons leave the
        // focus graph; when it shows, they rejoin. Nudge re-evaluation
        // so a stranded focus doesn't eat the next Select press.
        setNeedsFocusUpdate()
        #endif
    }

    /// Call on any user interaction: ensures the overlay is visible.
    private func pokeOverlay() {
        if !overlayVisible { setOverlayVisible(true) }
    }

    #if os(tvOS)
    // MARK: - Siri Remote (tvOS)

    /// Remote input: Select toggles the overlay both directions (same
    /// explicit state as touch), Play/Pause toggles playback, Menu
    /// dismisses through the same path as the Done button. Manual only —
    /// no timers, no auto show/hide, per Barklee's standing preference.
    /// Presses a focused button consumes (Select on a focused control)
    /// never reach here, so focused controls keep their own behavior.
    /// Left/Right seek ±10s only while the overlay is hidden; while it is
    /// visible those presses belong to focus navigation.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .select:
                toggleControls()
                handled = true
            case .playPause:
                playPauseTapped()
                handled = true
            case .menu:
                dismissTapped()
                handled = true
            case .leftArrow:
                if !overlayVisible { seekBy(-10); handled = true }
            case .rightArrow:
                if !overlayVisible { seekBy(10); handled = true }
            default:
                break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
    #endif

    // MARK: - Track preferences

    /// Auto-selects audio/subtitle tracks matching Settings → Playback prefs.
    /// Runs once tracks are available; re-runs if the track lists grow
    /// (external OpenSubtitles arrive a few seconds after playback starts).
    private func applyTrackPrefsIfNeeded() {
        let audioCount = player.audioTracks.count
        let textCount = player.textTracks.count
        if didApplyTrackPrefs && audioCount == lastAudioCount && textCount == lastTextCount { return }
        guard audioCount > 0 || textCount > 0 else { return }
        lastAudioCount = audioCount
        lastTextCount = textCount

        // Audio: prefer the Settings language (default English).
        let wantAudio = PlaybackPrefs.audioLanguage
        if let idx = player.audioTracks.firstIndex(where: {
            PlaybackPrefs.trackMatches($0.trackName, language: wantAudio)
        }) {
            player.selectTrack(at: idx, type: .audio)
        }

        // Subtitles: Settings language (default English), or off.
        let wantSub = PlaybackPrefs.subtitleLanguage
        if wantSub == "off" {
            player.deselectAllTextTracks()
        } else if let idx = player.textTracks.firstIndex(where: {
            PlaybackPrefs.trackMatches($0.trackName, language: wantSub)
        }) {
            // Don't fight an already-selected matching track.
            if !(player.textTracks[idx].isSelected) {
                player.selectTrack(at: idx, type: .text)
            }
        }
        // Mark applied only once both lists are non-empty, so a late-arriving
        // external subtitle still gets a chance to match.
        if audioCount > 0 && textCount > 0 { didApplyTrackPrefs = true }
    }

    // MARK: - VLCMediaPlayerDelegate

    // NOTE: The delegate is a separate non-isolated proxy (see bottom of file),
    // not this @MainActor view controller. VLCKit invokes delegate callbacks on
    // its own background thread, which traps Swift 6's MainActor executor check
    // (EXC_BREAKPOINT, seen 2026-10-12) if the delegate is MainActor-isolated.

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Start playback here, NOT in makeUIViewController: starting timers
        // during SwiftUI's layout pass traps (Timer.publish EXC_BREAKPOINT).
        if let url = pendingURL {
            pendingURL = nil
            pendingSeek = resumeFrom
            resumeFrom = nil
            startPlayback(url: url)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        reportProgress()
        player.stop()
        timeObserver?.invalidate()
        timeObserver = nil
    }
}

/// Non-isolated VLCKit delegate proxy. VLCKit invokes `mediaPlayerStateChanged`
/// on its own background thread; if the delegate were the @MainActor
/// VLCPlayerViewController, Swift 6's executor check traps with EXC_BREAKPOINT
/// (seen 2026-10-12). This proxy is not MainActor-isolated, so the callback
/// lands safely, then hops to the main actor for the SwiftUI state write.
private final class VLCDelegateProxy: NSObject, VLCMediaPlayerDelegate {
    weak var vc: VLCPlayerViewController?

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let p = aNotification.object as? VLCMediaPlayer, p.state == .error else { return }
        Task { @MainActor [weak vc] in
            vc?.errorMessage.wrappedValue = "VLC player error: unable to play this stream."
        }
    }
}
