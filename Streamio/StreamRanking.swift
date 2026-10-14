import Foundation

extension StremioStream {
    /// Barklee's ranking rule, stepped by resolution tier:
    /// all 4K first, then 1080p, then 720p, etc. Inside a tier, source quality
    /// ranks next (Blu-ray/REMUX > WEB-DL > WEBRip > HDTV), then seeder count.
    /// Resolution parsed from name/title (2160p/4K > 1080p > 720p > 480p);
    /// seeders from the Stremio "👤 N" convention in the title.
    var resolutionRank: Int {
        let text = ((name ?? "") + " " + (title ?? "")).lowercased()
        if text.contains("2160p") || text.contains("4k") { return 2160 }
        if text.contains("1080p") { return 1080 }
        if text.contains("720p") { return 720 }
        if text.contains("480p") { return 480 }
        return 0
    }

    /// Source quality within a resolution tier.
    var sourceQualityRank: Int {
        let text = ((name ?? "") + " " + (title ?? "")).lowercased()
        if text.contains("remux") { return 4 }
        if text.contains("bluray") || text.contains("blu-ray") || text.contains("bdrip") { return 3 }
        if text.contains("web-dl") || text.contains("webdl") { return 2 }
        if text.contains("webrip") || text.contains("web-rip") { return 1 }
        if text.contains("hdtv") { return 1 }
        return 0
    }

    var seederCount: Int {
        guard let t = title else { return 0 }
        // Stremio convention: "👤 1234" in the stream title
        guard let r = t.range(of: "👤\\s*(\\d+)", options: .regularExpression) else { return 0 }
        let digits = t[r].filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

/// Sort stepped by resolution tier (4K, 1080p, 720p, ...), then source quality
/// inside the tier (Blu-ray/REMUX > WEB-DL > WEBRip/HDTV), then seeder count.
func rankStreams(_ streams: [StremioStream]) -> [StremioStream] {
    streams.sorted {
        if $0.resolutionRank != $1.resolutionRank { return $0.resolutionRank > $1.resolutionRank }
        if $0.sourceQualityRank != $1.sourceQualityRank { return $0.sourceQualityRank > $1.sourceQualityRank }
        return $0.seederCount > $1.seederCount
    }
}
