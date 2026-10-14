import SwiftUI

struct AddonStreams: Identifiable {
    let addon: AddonDescriptor
    var streams: [StremioStream]
    var failed: Bool
    var id: String { addon.id }
}

struct TitleDetailView: View {
    @Environment(Session.self) private var session
    @Environment(WatchStore.self) private var watchStore
    let meta: StremioMeta

    @State private var full: StremioMeta?
    @State private var selectedSeason: Int = 1
    @State private var selectedVideo: MetaVideo?
    @State private var groups: [AddonStreams] = []
    @State private var loading = false
    @State private var playURL: URL?
    @State private var playResumeFrom: Double?
    @State private var playResumeFraction: Double?
    @State private var unsupported = false
    @State private var torrent: TorrentSession?
    @State private var activeTorrent: TorrentSession?
    @State private var torrentError: String?
    @State private var vlcError: String?
    @State private var errorRefreshUsed = false
    /// File name of the file behind `playURL` when the URL itself carries no
    /// extension (TorBox download links) — routes VLC vs AVPlayer correctly.
    @State private var playFileNameHint: String?
    /// The last successful TorBox mint, kept so a playback failure can be
    /// healed by re-minting a fresh link once instead of dead-ending.
    @State private var lastTorBoxMint: (hash: String, fileIdx: Int?)?
    @State private var torBoxRemintUsed = false
    @State private var autoResumeFired = false
    @Environment(\.openURL) private var openURL

    private var current: StremioMeta { full ?? meta }
    private var isSeries: Bool { current.type == "series" }
    private var seasons: [Int] {
        Array(Set((current.videos ?? []).compactMap(\.season).filter { $0 > 0 })).sorted()
    }
    private var episodes: [MetaVideo] {
        (current.videos ?? []).filter { $0.season == selectedSeason }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    /// Containers iOS AVPlayer cannot play. These route to the bundled VLC
    /// player (VLCKit ships every codec — nothing needs "installing").
    /// Torrents always use VLC via the local 127.0.0.1 server.
    static func shouldUseVLC(url: URL, fileNameHint: String? = nil) -> Bool {
        if url.host == "127.0.0.1" { return true }
        let vlcOnly: Set<String> = ["mkv", "avi", "ts", "m2ts", "mts", "wmv", "flv", "webm", "vob", "ogv", "rmvb"]
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty, let hint = fileNameHint, !hint.isEmpty {
            // TorBox download links have no extension — judge by the real
            // file name TorBox reported for the stream.
            ext = (hint as NSString).pathExtension.lowercased()
        }
        return vlcOnly.contains(ext)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: current.backgroundURL ?? current.posterURL) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                    .frame(height: 220).clipped()
                VStack(alignment: .leading, spacing: 12) {
                    Text(current.name).font(.title.bold())
                    if let d = current.description { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                    watchToggle
                    if isSeries { episodePicker }
                    streamList
                }.padding(.horizontal)
            }
        }
        .inlineNavTitle()
        .task { await loadMeta(); await autoResumeIfPending() }
        .fullScreenCover(item: $playURL, onDismiss: stopTorrent) { url in
            Group {
                if Self.shouldUseVLC(url: url, fileNameHint: playFileNameHint) {
                    VLCPlayerView(url: url, errorMessage: $vlcError,
                                  resumeFrom: playResumeFrom,
                                  onProgress: { pos, dur in savePlaybackProgress(position: pos, duration: dur) },
                                  subtitleVideo: subtitleLookup,
                                  onDone: { playURL = nil })
                        .ignoresSafeArea()
                } else {
                    PlayerView(url: url, resumeFrom: playResumeFrom,
                               onProgress: { pos, dur in savePlaybackProgress(position: pos, duration: dur) },
                               onError: { msg in vlcError = msg; refreshStreamsAfterError() })
                        .ignoresSafeArea()
                }
            }
        }
        .overlay { if let t = torrent { TorrentBufferingOverlay(session: t, cancel: stopTorrent) } }
        .alert("Can't play this stream", isPresented: $unsupported) {
            Button("OK", role: .cancel) {}
        } message: { Text("This stream type isn't supported.") }
        .alert("Torrent error", isPresented: Binding(get: { torrentError != nil }, set: { if !$0 { torrentError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(torrentError ?? "") }
        .alert("Playback error", isPresented: Binding(get: { vlcError != nil }, set: { if !$0 { vlcError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(vlcError ?? "") }
        .onDisappear { if playURL == nil { stopTorrent() } }
        .onChange(of: vlcError) { _, newValue in
            guard newValue != nil else { return }
            // A TorBox link that fails mid-play is usually just a dead
            // session link: re-mint a fresh one ONCE and resume in place
            // instead of leaving a dead player on screen.
            if let mint = lastTorBoxMint, !torBoxRemintUsed {
                torBoxRemintUsed = true
                vlcError = nil
                Task { await remintTorBox(hash: mint.hash, fileIdx: mint.fileIdx) }
            } else {
                refreshStreamsAfterError()
            }
        }
    }

    /// A failed direct/debrid link is usually just an EXPIRED link:
    /// refetch the stream list once so the next tap gets a freshly minted
    /// URL. Torrent streams play from 127.0.0.1 — a local failure can't be
    /// fixed by a refetch. (TorBox in-app streams are already re-minted on
    /// every TorBoxStreamer.streamURL call.)
    private func refreshStreamsAfterError() {
        guard !errorRefreshUsed, let u = playURL, u.host != "127.0.0.1" else { return }
        errorRefreshUsed = true
        guard let vid = isSeries ? selectedVideo?.id : current.id else { return }
        Task { await loadStreams(videoId: vid) }
    }

    /// One automatic recovery for a dead TorBox stream: mint a FRESH TorBox
    /// link for the same torrent/file and re-present the player at the
    /// latest saved position. A second failure falls through to the normal
    /// error alert.
    private func remintTorBox(hash: String, fileIdx: Int?) async {
        let vid = isSeries ? selectedVideo?.id : current.id
        if let vid, let p = watchStore.progress(type: current.type, metaId: current.id, videoId: vid) {
            playResumeFrom = p.position
            playResumeFraction = p.fraction
        }
        playURL = nil
        do {
            let minted = try await TorBoxStreamer.streamURL(infoHashHex: hash, fileIdx: fileIdx) { _ in }
            playFileNameHint = minted.fileName
            playURL = minted.url
        } catch {
            vlcError = "TorBox couldn't refresh this stream: \(error.localizedDescription)"
        }
    }

    @ViewBuilder private var watchToggle: some View {
        let w = watchStore.isWatched(type: current.type, metaId: current.id, videoId: current.id)
        Button {
            watchStore.toggle(type: current.type, metaId: current.id, videoId: current.id,
                              name: current.name, poster: current.poster)
        } label: {
            Label(w ? "Watched" : "Mark watched", systemImage: w ? "checkmark.circle.fill" : "circle")
                .font(.subheadline).foregroundStyle(.purple)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var episodePicker: some View {
        if !seasons.isEmpty {
            Picker("Season", selection: $selectedSeason) {
                ForEach(seasons, id: \.self) { Text("Season \($0)").tag($0) }
            }.pickerStyle(.menu)
            ForEach(episodes) { ep in
                HStack(spacing: 10) {
                    Button {
                        selectedVideo = ep
                        Task { await loadStreams(videoId: ep.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(ep.episode ?? 0). \(ep.displayTitle)").lineLimit(1)
                                if let air = AirDate.display(ep.released) {
                                    Text(air).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedVideo?.id == ep.id { Image(systemName: "checkmark").foregroundStyle(.purple) }
                        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    Button {
                        watchStore.toggle(type: current.type, metaId: current.id, videoId: ep.id,
                                          name: "\(current.name) S\(ep.season ?? 0) E\(ep.episode ?? 0)",
                                          poster: current.poster)
                    } label: {
                        Image(systemName: watchStore.isWatched(type: current.type, metaId: current.id, videoId: ep.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.purple).font(.title3)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var streamList: some View {
        if isSeries && selectedVideo == nil {
            Text("Pick an episode to load streams.").font(.footnote).foregroundStyle(.secondary)
        } else if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text(g.addon.manifest.name).font(.headline)
                    if g.failed {
                        Text("Couldn't reach this addon.").font(.footnote).foregroundStyle(.secondary)
                    } else if g.streams.isEmpty {
                        Text("No streams.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(g.streams) { s in
                        Button {
                            tap(s)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if let n = s.name { Text(n).font(.caption).foregroundStyle(.purple) }
                                Text(s.displayTitle).font(.subheadline).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func tap(_ s: StremioStream) {
        errorRefreshUsed = false
        torBoxRemintUsed = false
        markPlayedWatched()
        // Continue Watching: resume from saved position if meaningful.
        let vid = isSeries ? selectedVideo?.id : current.id
        if let vid, let p = watchStore.progress(type: current.type, metaId: current.id, videoId: vid) {
            playResumeFrom = p.position
            playResumeFraction = p.fraction
        } else {
            playResumeFrom = nil
            playResumeFraction = nil
        }
        if let u = s.playableURL { lastTorBoxMint = nil; playFileNameHint = nil; playURL = u }
        else if s.isTorrent, let hash = s.infoHash { startTorrent(hash: hash, fileIdx: s.fileIdx, trackers: s.magnetTrackers) }
        else if let app = s.youTubeAppURL, let web = s.youTubeWebURL {
            openURL(app) { accepted in if !accepted { openURL(web) } }
        } else { unsupported = true }
    }

    /// Continue Watching one-tap resume (build 19): Home's CW card sets
    /// `watchStore.pendingResume`; when this detail view matches it, pick
    /// the saved episode, load its streams, and start the top-ranked one —
    /// the same stream order the user sees in the list — so the tap goes
    /// straight to playing at the saved position instead of landing on a
    /// page that still needs two more picks. If anything is missing
    /// (streams failed to load, nothing playable), the user simply stays
    /// on the detail page, no worse off than before.
    private func autoResumeIfPending() async {
        guard !autoResumeFired, let pending = watchStore.pendingResume,
              pending.metaId == meta.id else { return }
        autoResumeFired = true
        watchStore.pendingResume = nil
        if isSeries {
            guard let ep = (current.videos ?? []).first(where: { $0.id == pending.videoId }) else { return }
            selectedSeason = ep.season ?? selectedSeason
            selectedVideo = ep
            await loadStreams(videoId: ep.id)
        }
        // Movies already loaded their streams in loadMeta.
        for g in groups where !g.failed {
            if let s = g.streams.first(where: { $0.playableURL != nil || $0.isTorrent }) {
                tap(s)
                return
            }
        }
    }

    /// (type, videoId) for the OpenSubtitles lookup, e.g. ("series", "tt26545992:1:8").
    private var subtitleLookup: (type: String, videoId: String)? {
        let vid = isSeries ? selectedVideo?.id : current.id
        guard let vid else { return nil }
        return (type: current.type, videoId: vid)
    }

    /// Persists playback position for Continue Watching.
    private func savePlaybackProgress(position: Double, duration: Double) {
        let vid = isSeries ? selectedVideo?.id : current.id
        guard let vid else { return }
        let label: String
        if isSeries, let ep = selectedVideo {
            label = "\(current.name) S\(ep.season ?? 0) E\(ep.episode ?? 0)"
        } else {
            label = current.name
        }
        watchStore.saveProgress(type: current.type, metaId: current.id, videoId: vid,
                                name: label, poster: current.poster,
                                position: position, duration: duration)
    }

    /// Tracker behavior: playing something marks it watched (toggle to undo).
    private func markPlayedWatched() {
        if isSeries, let ep = selectedVideo {
            watchStore.setWatched(true, type: current.type, metaId: current.id, videoId: ep.id,
                                  name: "\(current.name) S\(ep.season ?? 0) E\(ep.episode ?? 0)",
                                  poster: current.poster)
        } else if !isSeries {
            watchStore.setWatched(true, type: current.type, metaId: current.id, videoId: current.id,
                                  name: current.name, poster: current.poster)
        }
    }

    private func startTorrent(hash: String, fileIdx: Int?, trackers: [String] = []) {
        stopTorrent()
        let t = TorrentSession()
        torrent = t
        let fraction = playResumeFraction
        // TorBox first (fast server-side download, no P2P flakiness), P2P fallback.
        var torBoxFailure: String?
        let useTorBox = DebridConfig.provider == .torbox && DebridConfig.apiKey != nil
        Task {
            do {
                if useTorBox {
                    do {
                        let minted = try await TorBoxStreamer.streamURL(infoHashHex: hash, fileIdx: fileIdx) { stage in
                            Task { @MainActor in t.progress = TorrentProgress(stage: stage) }
                        }
                        // TorBox serves a direct link — no local P2P session to track.
                        guard torrent === t else { return }
                        torrent = nil
                        lastTorBoxMint = (hash: hash, fileIdx: fileIdx)
                        playFileNameHint = minted.fileName
                        playURL = minted.url
                        return
                    } catch {
                        // Fall through to P2P — but remember the TorBox
                        // failure so it is not swallowed silently if the
                        // fallback fails too.
                        torBoxFailure = error.localizedDescription
                    }
                }
                let url = try await t.start(infoHash: hash, fileIdx: fileIdx, trackers: trackers, resumeFraction: fraction)
                guard torrent === t else { t.stop(); return }
                lastTorBoxMint = nil
                playFileNameHint = nil
                playURL = url
                torrent = nil
                activeTorrent = t
            } catch {
                if torrent === t {
                    torrent = nil
                    torrentError = torBoxFailure != nil
                        ? "TorBox failed: \(torBoxFailure!). Torrent fallback also failed: \(error.localizedDescription)"
                        : error.localizedDescription
                }
                t.stop()
            }
        }
    }

    private func stopTorrent() {
        torrent?.stop(); torrent = nil
        activeTorrent?.stop(); activeTorrent = nil
    }

    private func loadMeta() async {
        if let m = try? await Cinemeta.getMeta(type: meta.type, id: meta.id) {
            full = m
            if let first = (m.videos ?? []).compactMap(\.season).filter({ $0 > 0 }).min() { selectedSeason = first }
        }
        if !isSeries { await loadStreams(videoId: meta.id) }
    }

    private func loadStreams(videoId: String) async {
        loading = true
        let addons = await RealAddons.streamAddons(from: session.effectiveAddons)
        let type = meta.type
        let results = await withTaskGroup(of: AddonStreams.self) { group in
            for a in addons {
                group.addTask {
                    do { return AddonStreams(addon: a, streams: try await AddonClient(addon: a).getStreams(type: type, id: videoId), failed: false) }
                    catch { return AddonStreams(addon: a, streams: [], failed: true) }
                }
            }
            var out: [AddonStreams] = []
            for await r in group { out.append(r) }
            return out
        }
        groups = addons.compactMap { a in
            guard var g = results.first(where: { $0.addon.id == a.id }) else { return nil }
            g.streams = rankStreams(g.streams)
            return g
        }
        loading = false
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }


struct TorrentBufferingOverlay: View {
    let session: TorrentSession
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if session.progress.piecesTotal > 0 {
                ProgressView(value: Double(session.progress.piecesDone), total: Double(max(session.progress.piecesTotal, 1)))
                    .tint(.purple).frame(width: 220)
            } else {
                ProgressView()
            }
            Text(session.progress.stage).font(.headline)
            if session.progress.piecesTotal > 0 {
                Text("\(session.progress.piecesDone) / \(session.progress.piecesTotal) pieces · \(session.progress.peers) peers")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
