import Foundation

/// Playback language preferences (Settings → Playback).
/// The VLC player auto-selects audio/subtitle tracks matching these on start.
enum PlaybackPrefs {
    private static let audioKey = "streamio.playback.audioLang"
    private static let subKey = "streamio.playback.subLang"

    static let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
    ]

    /// ISO 639-1 code, default English.
    static var audioLanguage: String {
        get { UserDefaults.standard.string(forKey: audioKey) ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: audioKey) }
    }

    /// ISO 639-1 code or "off", default English.
    static var subtitleLanguage: String {
        get { UserDefaults.standard.string(forKey: subKey) ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: subKey) }
    }

    static func languageName(for code: String) -> String {
        if code == "off" { return "Off" }
        return languages.first { $0.code == code }?.name ?? code
    }

    /// True when a VLC track name looks like the given language.
    /// Matches full names ("English"), ISO codes ("eng", "en"), etc.
    static func trackMatches(_ trackName: String, language code: String) -> Bool {
        let lower = trackName.lowercased()
        let tokens: [String: [String]] = [
            "en": ["english", "[eng]", "(eng)", " eng ", ".eng.", "_eng_", "-eng-", "eng_"],
            "es": ["spanish", "español", "[spa]", "(spa)", " spa "],
            "fr": ["french", "français", "[fra]", "[fre]", "(fra)"],
            "de": ["german", "deutsch", "[deu]", "[ger]", "(deu)"],
            "it": ["italian", "[ita]", "(ita)"],
            "pt": ["portuguese", "[por]", "(por)"],
            "ja": ["japanese", "[jpn]", "(jpn)"],
            "ko": ["korean", "[kor]", "(kor)"],
            "zh": ["chinese", "mandarin", "[chi]", "[zho]", "(chi)"],
        ]
        guard let toks = tokens[code] else { return lower.contains(code) }
        // Also match a bare "en"/"eng" token at word boundaries.
        if lower == code { return true }
        return toks.contains { lower.contains($0) }
    }
}
