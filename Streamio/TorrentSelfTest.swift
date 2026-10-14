#if DEBUG
import Foundation
import AVFoundation
import VLCKit

/// DEBUG-only end-to-end check used for simulator verification (never compiled into Release/IPA).
enum TorrentSelfTest {
    static func run(infoHash: String) async {
        @Sendable func out(_ s: String) { print("[TORRENT-TEST] \(s)"); fflush(stdout) }
        let t0 = Date()
        do {
            let s = try TorrentStreamer(infoHashHex: infoHash, fileIdx: nil)
            let url = try await s.start { p in out("progress: \(p.stage) \(p.piecesDone)/\(p.piecesTotal) peers=\(p.peers)") }
            out("READY url=\(url.absoluteString) after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

            // What AVPlayer's loader sees: probe via AVURLAsset.
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            let dur = try await asset.load(.duration)
            out("AVURLAsset isPlayable=\(playable) duration=\(CMTimeGetSeconds(dur))s")

            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.play()
            for i in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let p = await s.progress()
                out("t+\(i + 1)s player.time=\(String(format: "%.2f", CMTimeGetSeconds(player.currentTime())))s rate=\(player.rate) status=\(item.status.rawValue) pieces=\(p.piecesDone)/\(p.piecesTotal) peers=\(p.peers)")
            }
            out("DONE (server stays up 10 min for external curl)")
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            await s.stop()
        } catch {
            out("FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Exit / re-entry cycle (resume-bug repro)

    private static func out(_ s: String) { print("[CYCLE] \(s)"); fflush(stdout) }
    private static func f1(_ d: Double) -> String { String(format: "%.1f", d) }
    private static func stateName(_ p: VLCMediaPlayer) -> String {
        switch p.state {
        case .stopped: return "stopped"
        case .opening: return "opening"
        case .playing: return "playing"
        case .paused: return "paused"
        case .error: return "error"
        default: return "state(\(p.state.rawValue))"
        }
    }

    /// HTTP range probe against the local server, mirroring a player read.
    /// Returns the file total from Content-Range when present.
    @discardableResult
    private static func probe(_ url: URL, _ label: String, _ start: Int, _ len: Int) async -> Int? {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(start + len - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 45
        let t = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let total = http?.value(forHTTPHeaderField: "Content-Range")
                .flatMap { $0.split(separator: "/").last }
                .flatMap { Int($0) }
            out("probe \(label): HTTP \(http?.statusCode ?? -1) bytes=\(data.count) in \(f1(Date().timeIntervalSince(t)))s")
            return total
        } catch {
            out("probe \(label): ERROR \(error.localizedDescription) after \(f1(Date().timeIntervalSince(t)))s")
            return nil
        }
    }

    /// Full user cycle on a raw VLCMediaPlayer driven with the SAME seek
    /// policy VLCPlayerViewController uses in build 18 (confirmed seeks:
    /// player.position re-applied while playing until the clock lands
    /// within 2s of the target; an input rebuild positioned pre-play is
    /// the escape hatch — the start-time media option is ignored by this
    /// VLCKit build, per the seek matrix):
    /// play -> pause (sit) -> resume -> exit -> re-enter (resume) -> scrub.
    @MainActor
    static func runCycle(infoHash: String) async {
        let hash = infoHash.lowercased()
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("streamio-torrents", isDirectory: true)
        let partURL = cacheDir.appendingPathComponent("streamio-\(hash).part")
        let indexURL = cacheDir.appendingPathComponent("streamio-\(hash).json")
        func partInfo(_ label: String) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path)
            let size = (attrs?[.size] as? Int) ?? -1
            let idx = FileManager.default.fileExists(atPath: indexURL.path)
            out("\(label): .part exists=\(attrs != nil) size=\(size) index=\(idx ? "present" : "ABSENT")")
        }
        do {
            // ---------- Phase A: first entry ----------
            let tA = Date()
            let s1 = try TorrentStreamer(infoHashHex: hash, fileIdx: nil)
            let url = try await s1.start { p in
                if p.stage != "Streaming" { out("A progress: \(p.stage) \(p.piecesDone)/\(p.piecesTotal) peers=\(p.peers)") }
            }
            out("A-READY in \(f1(Date().timeIntervalSince(tA)))s url=\(url.absoluteString)")
            let total = await probe(url, "A byte0", 0, 262_144) ?? 0
            if total > 0 { await probe(url, "A tail", total - 262_144, 262_144) }

            let player = VLCMediaPlayer()
            player.media = VLCMedia(url: url)
            player.play()
            // Play until media time >= 30s (a real, saveable resume point).
            var playedTo = 0.0
            for i in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let t = Double(player.time.intValue) / 1000
                playedTo = t
                if i % 5 == 0 || t >= 30 {
                    let p = await s1.progress()
                    out("A play t+\(i + 1)s state=\(stateName(player)) time=\(f1(t)) pieces=\(p.piecesDone)/\(p.piecesTotal)")
                }
                if t >= 30 { break }
            }
            guard playedTo >= 20 else { out("A-FAIL: playback never reached 20s (time=\(f1(playedTo)))"); return }
            out("A playing, reached media time \(f1(playedTo))s")

            // ---------- Pause: sit 15s, then resume ----------
            let pauseTime = Double(player.time.intValue) / 1000
            player.pause()
            let piecesAtPause = await s1.progress().piecesDone
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            let piecesAfterSit = await s1.progress().piecesDone
            out("PAUSE-BUFFER: position held at \(f1(pauseTime))s; pieces \(piecesAtPause) -> \(piecesAfterSit) during 15s pause")
            player.play()
            var resumeLatency: Double? = nil
            let tp = Date()
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let t = Double(player.time.intValue) / 1000
                if t > pauseTime + 0.4 { resumeLatency = Date().timeIntervalSince(tp); break }
            }
            out("PAUSE-RESUME: \(resumeLatency.map { "time advancing again after \(f1($0))s" } ?? "TIME DID NOT ADVANCE within 6s (state=\(stateName(player)))")")

            // Let it play a bit more so the saved point is unambiguous.
            for _ in 0..<6 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            let savedPos = Double(player.time.intValue) / 1000
            let dur = Double(player.media?.length.intValue ?? 0) / 1000
            out("EXIT: saved position \(f1(savedPos))s of \(f1(dur))s (fraction \(dur > 0 ? f1(savedPos / dur * 100) : "?")%)")
            player.stop()
            await s1.stop()
            partInfo("EXIT cache state")

            // ---------- Phase B: re-entry ----------
            let tB = Date()
            let s2 = try TorrentStreamer(infoHashHex: hash, fileIdx: nil)
            let url2 = try await s2.start(onProgress: { p in
                if p.stage != "Streaming" { out("B progress: \(p.stage) \(p.piecesDone)/\(p.piecesTotal) peers=\(p.peers)") }
            }, resumeFraction: dur > 0 ? savedPos / dur : nil)
            out("B-READY in \(f1(Date().timeIntervalSince(tB)))s (first entry took \(f1(Date().timeIntervalSince(tA)))s to same point incl. play)")
            let pB0 = await s2.progress()
            out("B-CACHE: pieces present at B start: \(pB0.piecesDone)/\(pB0.piecesTotal) (before-fix behavior: 0 — cache was deleted on exit)")
            if total > 0 {
                let resumeByte = Int(Double(total) * (dur > 0 ? savedPos / dur : 0))
                await probe(url2, "B resume-offset", resumeByte, 262_144)
                await probe(url2, "B byte0", 0, 262_144)
            }

            // Mirror of the build-18 resume: plain open, then the
            // confirmed-seek driver — re-apply player.position while
            // playing until the clock is in the resume zone AND advancing
            // (the start-time media option is ignored by this VLCKit).
            let player2 = VLCMediaPlayer()
            player2.media = VLCMedia(url: url2)
            player2.play()
            var seekLandedAt: Double? = nil
            let tSeek = Date()
            var prevTB = 0.0
            for i in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let t = Double(player2.time.intValue) / 1000
                if seekLandedAt == nil, player2.isPlaying {
                    let len = Double(player2.media?.length.intValue ?? 0) / 1000
                    if len > 0, abs(t - savedPos) > 2 { player2.position = min(max(savedPos / len, 0), 0.99) }
                }
                if i % 4 == 0 {
                    let p = await s2.progress()
                    out("B t+\(f1(Double(i) * 0.5))s state=\(stateName(player2)) time=\(f1(t)) pieces=\(p.piecesDone)/\(p.piecesTotal)")
                }
                if seekLandedAt == nil, abs(t - savedPos) < 8, t > prevTB + 0.05 { seekLandedAt = Date().timeIntervalSince(tSeek) }
                prevTB = t
            }
            let endTime = Double(player2.time.intValue) / 1000
            out("B-RESUME VERDICT: \(seekLandedAt.map { "playback in resume zone and advancing after \(f1($0))s" } ?? "NEVER reached resume zone; final state=\(stateName(player2)) time=\(f1(endTime)) (saved was \(f1(savedPos)))")")

            // ---------- Scrub to an unbuffered point (80%) ----------
            // Build-18 policy (faithful mirror of the VC driver): set the
            // position, re-apply it every tick while playing until the
            // clock is in-zone AND advancing; rebuild the input once if
            // unlanded after ~6s, then keep driving the new input.
            out("SCRUB: seeking to 80% (confirm + rebuild policy)")
            player2.position = 0.8
            var scrubOK: Double? = nil
            let tScr = Date()
            var prevT = Double(player2.time.intValue) / 1000
            var scrubRebuilt = false
            for _ in 0..<56 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let el = Date().timeIntervalSince(tScr)
                let t = Double(player2.time.intValue) / 1000
                if t > dur * 0.7, t < dur * 0.95, t > prevT + 0.05 { scrubOK = el; break }
                prevT = t
                if player2.isPlaying, abs(t - dur * 0.8) > 2 { player2.position = 0.8 }
                if !scrubRebuilt, el >= 6 {
                    scrubRebuilt = true
                    out("SCRUB: unlanded after \(f1(el))s — rebuilding input at \(f1(dur * 0.8))s (position pre-play)")
                    player2.media = VLCMedia(url: url2)
                    player2.position = 0.8
                    player2.play()
                }
            }
            out("B-SCRUB VERDICT: \(scrubOK.map { "playback advancing in scrub zone after \(f1($0))s (rebuilt=\(scrubRebuilt))" } ?? "DID NOT ADVANCE in scrub zone; state=\(stateName(player2)) time=\(f1(Double(player2.time.intValue) / 1000))")")

            player2.stop()
            await s2.stop()
            out("CYCLE DONE")
        } catch {
            out("CYCLE FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Seek-mechanism matrix

    /// Which seek mechanism does this VLCKit build actually honor against
    /// the torrent server? Build 18 evidence so far: the start-time media
    /// option (no colon) is IGNORED (player opened at 0), and a position
    /// set mid-playback against a cold region wedges the input. Each arm
    /// tries one mechanism against a fresh player; target = 300s.
    @MainActor
    static func runMatrix(infoHash: String) async {
        let hash = infoHash.lowercased()
        do {
            let s = try TorrentStreamer(infoHashHex: hash, fileIdx: nil)
            let url = try await s.start { _ in }
            out("MATRIX-READY url=\(url.absoluteString)")
            let target = 300.0, dur = 600.0

            func watch(_ player: VLCMediaPlayer, arm: String, seconds: Int) async {
                var prev = -1.0
                for i in 0..<seconds * 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let t = Double(player.time.intValue) / 1000
                    if i % 4 == 0 { out("MATRIX \(arm) t+\(f1(Double(i) * 0.5))s state=\(stateName(player)) time=\(f1(t))") }
                    if t >= target - 5, t > prev { out("MATRIX \(arm): LANDED at \(f1(t))s after \(f1(Double(i) * 0.5))s"); return }
                    prev = t
                }
                out("MATRIX \(arm): NOT landed; final time=\(f1(Double(player.time.intValue) / 1000)) state=\(stateName(player))")
            }

            // Arm 1: media option with leading colon.
            do {
                let player = VLCMediaPlayer()
                let media = VLCMedia(url: url)
                media?.addOption(":start-time=\(target)")
                player.media = media
                player.play()
                await watch(player, arm: "colon-start-time", seconds: 10)
                player.stop()
            }
            // Arm 2: position set BEFORE play().
            do {
                let player = VLCMediaPlayer()
                player.media = VLCMedia(url: url)
                player.position = target / dur
                player.play()
                await watch(player, arm: "position-before-play", seconds: 10)
                player.stop()
            }
            // Arm 3: position confirm loop while playing.
            do {
                let player = VLCMediaPlayer()
                player.media = VLCMedia(url: url)
                player.play()
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let t = Double(player.time.intValue) / 1000
                    if t >= target - 5 { break }
                    if player.isPlaying { player.position = target / dur }
                }
                await watch(player, arm: "position-confirm", seconds: 6)
                player.stop()
            }
            // Arm 4: VLCTime set once playing.
            do {
                let player = VLCMediaPlayer()
                player.media = VLCMedia(url: url)
                player.play()
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if player.isPlaying { player.time = VLCTime(int: Int32(target * 1000)); break }
                }
                await watch(player, arm: "time-set", seconds: 10)
                player.stop()
            }
            // Arm 5: jumpForward once playing.
            do {
                let player = VLCMediaPlayer()
                player.media = VLCMedia(url: url)
                player.play()
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if player.isPlaying { player.jumpForward(target); break }
                }
                await watch(player, arm: "jump-forward", seconds: 10)
                player.stop()
            }
            await s.stop()
            out("MATRIX DONE")
        } catch {
            out("MATRIX FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Scrub-freeze micro-repro

    /// Play from 0, then seek once to 80% and watch for 90s: does playback
    /// recover? Concurrent range probes at the scrub offset discriminate
    /// "server/engine can't serve it" from "VLC never re-asked".
    @MainActor
    static func runScrub(infoHash: String) async {
        do {
            // Control arm: STREAMIO_SCRUB_URL plays an arbitrary URL with
            // no torrent engine behind it (e.g. a plain range server).
            var streamer: TorrentStreamer? = nil
            let url: URL
            if let raw = ProcessInfo.processInfo.environment["STREAMIO_SCRUB_URL"], let u = URL(string: raw) {
                url = u
                out("SCRUB-READY (external URL) url=\(url.absoluteString)")
            } else {
                let s = try TorrentStreamer(infoHashHex: infoHash.lowercased(), fileIdx: nil)
                streamer = s
                url = try await s.start { _ in }
                out("SCRUB-READY url=\(url.absoluteString)")
                // Timing-isolation arm: wait for a COMPLETE local copy
                // before playing, so every server read is instant.
                if ProcessInfo.processInfo.environment["STREAMIO_SCRUB_PRESEED"] != nil {
                    for _ in 0..<120 {
                        let p = await s.progress()
                        if p.piecesTotal > 0, p.piecesDone >= p.piecesTotal { break }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    let p = await s.progress()
                    out("SCRUB-PRESEED: pieces \(p.piecesDone)/\(p.piecesTotal)")
                }
            }
            let total = await probe(url, "S byte0", 0, 262_144) ?? 0
            let player = VLCMediaPlayer()
            player.media = VLCMedia(url: url)
            player.play()
            var started = false
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Double(player.time.intValue) / 1000 > 6 { started = true; break }
            }
            guard started else { out("SCRUB-FAIL: initial playback never started"); return }
            out("SCRUB: playing at \(f1(Double(player.time.intValue) / 1000))s; seeking to 80%")
            player.position = 0.8
            var probed10 = false, probed40 = false
            var advancedAt: Double? = nil
            let t0 = Date()
            var prev = 480.0
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let el = Date().timeIntervalSince(t0)
                let t = Double(player.time.intValue) / 1000
                if let s = streamer {
                    let p = await s.progress()
                    out("SCRUB t+\(f1(el))s state=\(stateName(player)) time=\(f1(t)) pieces=\(p.piecesDone)/\(p.piecesTotal) peers=\(p.peers)")
                } else {
                    out("SCRUB t+\(f1(el))s state=\(stateName(player)) time=\(f1(t))")
                }
                if !probed10, el >= 10 {
                    probed10 = true
                    if total > 0 { await probe(url, "S scrub-offset@10s", Int(Double(total) * 0.8), 262_144) }
                }
                if !probed40, el >= 40 {
                    probed40 = true
                    if total > 0 { await probe(url, "S scrub-offset@40s", Int(Double(total) * 0.8), 262_144) }
                }
                if t > 470, abs(t - prev) > 0.05 { advancedAt = el; break }
                prev = t
            }
            out("SCRUB VERDICT: \(advancedAt.map { "advanced again after \(f1($0))s" } ?? "STILL FROZEN at \(f1(Double(player.time.intValue) / 1000))s after 90s; state=\(stateName(player))")")
            player.stop()
            if let s = streamer { await s.stop() }
            out("SCRUB DONE")
        } catch {
            out("SCRUB FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Build 19: re-entry x3 + full scrub matrix

    /// Drives one seek with the SAME policy VLCPlayerViewController uses
    /// (build 18 confirmed-seek driver): set position, re-apply while
    /// playing until the clock is in-zone AND advancing; rebuild the input
    /// once if unlanded after ~6s. Returns seconds until advancing at the
    /// target, or nil if it never lands within `timeoutS`.
    @MainActor
    private static func driveSeek19(_ player: VLCMediaPlayer, url: URL, target: Double, label: String,
                                    timeoutS: Double = 28) async -> Double? {
        let len = Double(player.media?.length.intValue ?? 0) / 1000
        guard len > 0 else { out("C19 \(label): no media length"); return nil }
        let frac = min(max(target / len, 0), 0.99)
        player.position = frac
        let t0 = Date()
        var prev = Double(player.time.intValue) / 1000
        var rebuilt = false
        while Date().timeIntervalSince(t0) < timeoutS {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let el = Date().timeIntervalSince(t0)
            let t = Double(player.time.intValue) / 1000
            if abs(t - target) <= 2, t > prev + 0.03 {
                out("C19 \(label): advancing at target after \(f1(el))s (rebuilt=\(rebuilt))")
                return el
            }
            // Wedge signature (mirrors the shipped driver): clock parked
            // AT the target while playing -> rebuild early (~2s), not at 6s.
            let parked = abs(t - target) <= 2 && t <= prev + 0.001
            prev = t
            if player.isPlaying, abs(t - target) > 2 { player.position = frac }
            if !rebuilt, el >= 6 || (parked && el >= 2) {
                rebuilt = true
                out("C19 \(label): unlanded after \(f1(el))s (parked=\(parked)) — rebuilding input")
                player.media = VLCMedia(url: url)
                player.position = frac
                player.play()
            }
        }
        out("C19 \(label): NOT LANDED after \(f1(timeoutS))s; state=\(stateName(player)) time=\(f1(Double(player.time.intValue) / 1000)) target=\(f1(target))")
        return nil
    }

    @MainActor
    private static func playUntil19(_ player: VLCMediaPlayer, _ seconds: Double, timeoutS: Double = 90) async -> Double {
        var t = 0.0
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeoutS {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            t = Double(player.time.intValue) / 1000
            if t >= seconds { break }
        }
        return t
    }

    /// Build-19 verification cycle: cold entry, exit, re-entry x2 more
    /// (x3 entries total) with a position check each time, then the full
    /// scrub matrix (+10s, 50%, 90% cold, rewind to 10%, rewind to ~2%)
    /// with time-to-advancing per seek, then pause-sit-resume. Prints the
    /// warm-start cache evidence (info dict + stored peers files) that
    /// builds <=18 did not have.
    @MainActor
    static func runCycles19(infoHash: String) async {
        let hash = infoHash.lowercased()
        let dir = PieceStore.cacheDir
        let partURL = dir.appendingPathComponent("streamio-\(hash).part")
        let indexURL = dir.appendingPathComponent("streamio-\(hash).json")
        let infoURL = dir.appendingPathComponent("streamio-\(hash).info")
        let peersURL = dir.appendingPathComponent("streamio-\(hash).peers.json")
        func cacheState(_ label: String) {
            let fm = FileManager.default
            var peers = -1
            if let d = try? Data(contentsOf: peersURL),
               let list = try? JSONDecoder().decode([String].self, from: d) { peers = list.count }
            out("C19 cache \(label): part=\(fm.fileExists(atPath: partURL.path)) index=\(fm.fileExists(atPath: indexURL.path)) info=\(fm.fileExists(atPath: infoURL.path)) storedPeers=\(peers)")
        }
        // True cold start: wipe every cache artifact for this hash.
        for u in [partURL, indexURL, infoURL, peersURL] { try? FileManager.default.removeItem(at: u) }
        out("C19: cache wiped — entry 1 is cold")
        do {
            // ---------- Entry 1 (cold) ----------
            let t1 = Date()
            let s1 = try TorrentStreamer(infoHashHex: hash, fileIdx: nil)
            let url1 = try await s1.start { p in
                if p.stage != "Streaming" { out("C19 e1 progress: \(p.stage) \(p.piecesDone)/\(p.piecesTotal) peers=\(p.peers)") }
            }
            out("C19 ENTRY1-READY in \(f1(Date().timeIntervalSince(t1)))s")
            _ = await probe(url1, "C19 e1 byte0", 0, 262_144)
            let player1 = VLCMediaPlayer()
            player1.media = VLCMedia(url: url1)
            player1.play()
            let played1 = await playUntil19(player1, 30)
            guard played1 >= 20 else { out("C19 ENTRY1-FAIL: never reached 20s (time=\(f1(played1)))"); return }
            let dur = Double(player1.media?.length.intValue ?? 0) / 1000
            var saved = Double(player1.time.intValue) / 1000
            out("C19 ENTRY1: played to \(f1(saved))s of \(f1(dur))s — exiting")
            player1.stop()
            await s1.stop()
            cacheState("after exit 1")

            // ---------- Entries 2 and 3 (warm re-entries) ----------
            var currentSaved = saved
            var lastPlayer: VLCMediaPlayer?
            var lastStreamer: TorrentStreamer?
            var lastURL: URL?
            for entry in 2...3 {
                let tE = Date()
                let s = try TorrentStreamer(infoHashHex: hash, fileIdx: nil)
                let url = try await s.start(onProgress: { p in
                    if p.stage != "Streaming" { out("C19 e\(entry) progress: \(p.stage) \(p.piecesDone)/\(p.piecesTotal) peers=\(p.peers)") }
                }, resumeFraction: dur > 0 ? currentSaved / dur : nil)
                let readyS = Date().timeIntervalSince(tE)
                let p0 = await s.progress()
                out("C19 ENTRY\(entry)-READY in \(f1(readyS))s; pieces restored at start: \(p0.piecesDone)/\(p0.piecesTotal)")
                let player = VLCMediaPlayer()
                player.media = VLCMedia(url: url)
                player.play()
                // Give the input a moment to open, then drive the resume seek.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let land = await driveSeek19(player, url: url, target: currentSaved, label: "ENTRY\(entry) resume->\(f1(currentSaved))s")
                out("C19 ENTRY\(entry) VERDICT: \(land.map { "resume advancing after \($0)s of seek drive" } ?? "RESUME DID NOT LAND")")
                guard land != nil else { player.stop(); await s.stop(); return }
                // Play on ~12s so the next saved point is unambiguous.
                let target = Double(player.time.intValue) / 1000 + 12
                _ = await playUntil19(player, target, timeoutS: 30)
                currentSaved = Double(player.time.intValue) / 1000
                out("C19 ENTRY\(entry): played to \(f1(currentSaved))s")
                if entry < 3 {
                    player.stop()
                    await s.stop()
                    cacheState("after exit \(entry)")
                } else {
                    lastPlayer = player; lastStreamer = s; lastURL = url
                }
            }
            saved = currentSaved
            guard let player = lastPlayer, let streamer = lastStreamer, let url = lastURL else {
                out("C19: internal — no final session"); return
            }

            // ---------- Scrub matrix ----------
            let now = Double(player.time.intValue) / 1000
            _ = await driveSeek19(player, url: url, target: now + 10, label: "SCRUB +10s")
            _ = await driveSeek19(player, url: url, target: dur * 0.5, label: "SCRUB fwd 50%")
            let pPre90 = await streamer.progress()
            out("C19 SCRUB 90%: pieces before seek \(pPre90.piecesDone)/\(pPre90.piecesTotal)")
            _ = await driveSeek19(player, url: url, target: dur * 0.9, label: "SCRUB fwd 90% (cold)")
            _ = await driveSeek19(player, url: url, target: dur * 0.10, label: "SCRUB rewind 10%")
            _ = await driveSeek19(player, url: url, target: dur * 0.02, label: "SCRUB rewind ~2%")

            // ---------- Pause-sit-resume ----------
            let pauseAt = Double(player.time.intValue) / 1000
            player.pause()
            let piecesAtPause = await streamer.progress().piecesDone
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let piecesAfterSit = await streamer.progress().piecesDone
            out("C19 PAUSE-SIT: held at \(f1(pauseAt))s; pieces \(piecesAtPause) -> \(piecesAfterSit) during 10s pause")
            player.play()
            var resumeLat: Double? = nil
            let tp = Date()
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Double(player.time.intValue) / 1000 > pauseAt + 0.4 { resumeLat = Date().timeIntervalSince(tp); break }
            }
            out("C19 PAUSE-RESUME: \(resumeLat.map { "advancing again after \(f1($0))s" } ?? "DID NOT ADVANCE within 6s")")

            player.stop()
            await streamer.stop()
            cacheState("final")
            out("CYCLES19 DONE")
        } catch {
            out("CYCLES19 FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Build 19: cold-region scrub timing

    /// Cold-start, play a few seconds, then scrub into regions that are
    /// provably NOT downloaded yet (piece counts printed before each
    /// seek), timing each landing with the shipped seek policy
    /// (parked-at-target -> rebuild at ~2s; general unlanded -> 6s).
    /// Run 4 of runCycles19 could not measure this: the fixed engine had
    /// already pulled 391/392 pieces before the matrix ran.
    @MainActor
    static func runColdScrub19(infoHash: String) async {
        let hash = infoHash.lowercased()
        let dir = PieceStore.cacheDir
        for ext in ["part", "json", "info", "peers.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("streamio-\(hash).\(ext)"))
        }
        out("C19CS: cache wiped — cold start")
        do {
            let s = try TorrentStreamer(infoHashHex: hash, fileIdx: nil)
            let url = try await s.start { _ in }
            let p0 = await s.progress()
            out("C19CS READY pieces=\(p0.piecesDone)/\(p0.piecesTotal)")
            let player = VLCMediaPlayer()
            player.media = VLCMedia(url: url)
            player.play()
            let played = await playUntil19(player, 8, timeoutS: 30)
            guard played >= 5 else { out("C19CS FAIL: playback never started (time=\(f1(played)))"); return }
            let dur = Double(player.media?.length.intValue ?? 0) / 1000
            out("C19CS playing at \(f1(played))s of \(f1(dur))s")
            var p = await s.progress()
            out("C19CS before fwd90: pieces=\(p.piecesDone)/\(p.piecesTotal)")
            _ = await driveSeek19(player, url: url, target: dur * 0.9, label: "COLDSCRUB fwd 90%")
            p = await s.progress()
            out("C19CS before rew50: pieces=\(p.piecesDone)/\(p.piecesTotal)")
            _ = await driveSeek19(player, url: url, target: dur * 0.5, label: "COLDSCRUB rewind 50%")
            _ = await driveSeek19(player, url: url, target: dur * 0.1, label: "COLDSCRUB rewind 10%")
            player.stop()
            await s.stop()
            out("COLDSCRUB19 DONE")
        } catch {
            out("COLDSCRUB19 FAILED: \(error.localizedDescription)")
        }
    }
}
#endif
