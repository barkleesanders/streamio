import Foundation

/// Local watched-state tracker, Stremio-style. Keys are "type:metaId:videoId"
/// (movies use videoId == metaId). Persisted in UserDefaults; no account needed.
@MainActor
@Observable
final class WatchStore {
    private static let watchedKey = "streamio.watchedKeys.v1"
    private static let recordsKey = "streamio.watchRecords.v1"

    struct WatchRecord: Codable {
        let name: String
        let poster: String?
        let type: String
        let date: Date
    }

    private(set) var watched: Set<String> = []
    private var records: [String: WatchRecord] = [:]

    /// Transient (never persisted): set by a Continue Watching tap so the
    /// detail view it opens goes straight to playing at the saved position
    /// — one tap from Home to playback, the way Plex's Continue Watching
    /// behaves. Consumed (and cleared) by TitleDetailView when it matches.
    var pendingResume: (metaId: String, videoId: String)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.watchedKey),
           let keys = try? JSONDecoder().decode(Set<String>.self, from: data) {
            watched = keys
        }
        if let data = UserDefaults.standard.data(forKey: Self.recordsKey),
           let recs = try? JSONDecoder().decode([String: WatchRecord].self, from: data) {
            records = recs
        }
        loadProgress()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(watched) {
            UserDefaults.standard.set(data, forKey: Self.watchedKey)
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.recordsKey)
        }
    }

    static func key(type: String, metaId: String, videoId: String) -> String {
        "\(type):\(metaId):\(videoId)"
    }

    func isWatched(type: String, metaId: String, videoId: String) -> Bool {
        watched.contains(Self.key(type: type, metaId: metaId, videoId: videoId))
    }

    func setWatched(_ flag: Bool, type: String, metaId: String, videoId: String, name: String, poster: String?) {
        let k = Self.key(type: type, metaId: metaId, videoId: videoId)
        if flag {
            watched.insert(k)
            records[k] = WatchRecord(name: name, poster: poster, type: type, date: Date())
        } else {
            watched.remove(k)
            records.removeValue(forKey: k)
        }
        save()
    }

    func toggle(type: String, metaId: String, videoId: String, name: String, poster: String?) {
        setWatched(!isWatched(type: type, metaId: metaId, videoId: videoId),
                   type: type, metaId: metaId, videoId: videoId, name: name, poster: poster)
    }

    /// Most recently watched first.
    var recent: [(key: String, record: WatchRecord)] {
        records.sorted { $0.value.date > $1.value.date }.map { (key: $0.key, record: $0.value) }
    }

    // MARK: - Continue Watching (playback position)

    struct ProgressRecord: Codable {
        let metaId: String
        let type: String
        let videoId: String
        let name: String
        let poster: String?
        let position: Double  // seconds
        let duration: Double  // seconds
        let date: Date

        var fraction: Double { duration > 0 ? position / duration : 0 }
        var remaining: Double { max(0, duration - position) }
    }

    private static let progressKey = "streamio.progress.v1"
    private var progress: [String: ProgressRecord] = [:]

    private func loadProgress() {
        if let data = UserDefaults.standard.data(forKey: Self.progressKey),
           let p = try? JSONDecoder().decode([String: ProgressRecord].self, from: data) {
            progress = p
        }
    }

    private func saveProgressStore() {
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: Self.progressKey)
        }
    }

    /// Saves playback position. Ignores trivial positions (< 15s) and clears
    /// the entry when essentially finished (>= 92%), so finished items don't
    /// linger in Continue Watching.
    func saveProgress(type: String, metaId: String, videoId: String,
                      name: String, poster: String?, position: Double, duration: Double) {
        let k = Self.key(type: type, metaId: metaId, videoId: videoId)
        guard duration > 0 else { return }
        if position < 15 || position >= duration * 0.92 {
            if progress.removeValue(forKey: k) != nil { saveProgressStore() }
            return
        }
        progress[k] = ProgressRecord(metaId: metaId, type: type, videoId: videoId,
                                     name: name, poster: poster,
                                     position: position, duration: duration, date: Date())
        saveProgressStore()
    }

    func progress(type: String, metaId: String, videoId: String) -> ProgressRecord? {
        progress[Self.key(type: type, metaId: metaId, videoId: videoId)]
    }

    func clearProgress(type: String, metaId: String, videoId: String) {
        if progress.removeValue(forKey: Self.key(type: type, metaId: metaId, videoId: videoId)) != nil {
            saveProgressStore()
        }
    }

    /// In-progress items, most recently touched first.
    var continueWatching: [ProgressRecord] {
        progress.values.sorted { $0.date > $1.date }
    }
}

/// Lenient air-date formatting for Cinemeta `released` values
/// ("2026-10-12", "2026-10-12T00:00:00.000Z", ...).
enum AirDate {
    private static let inFormats: [String] = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"]
    private static let out: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func display(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in inFormats {
            f.dateFormat = fmt
            if let d = f.date(from: raw) { return out.string(from: d) }
        }
        return nil
    }
}
