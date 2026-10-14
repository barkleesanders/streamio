import Foundation
import CryptoKit

enum TorrentError: LocalizedError {
    case invalidInfoHash
    case trackerUnreachable
    case noPeers
    case metadataFailed(String)
    case malformed(String)
    case timeout(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidInfoHash: return "Invalid torrent hash."
        case .trackerUnreachable: return "Tracker unreachable."
        case .noPeers: return "No peers found."
        case .metadataFailed(let m): return "Couldn't fetch torrent metadata (\(m))."
        case .malformed(let m): return "Malformed torrent data (\(m))."
        case .timeout(let m): return "Timed out: \(m)."
        case .cancelled: return "Cancelled."
        }
    }
}

struct TorrentFile: Sendable {
    let path: String
    let length: Int
    /// Byte offset of this file inside the concatenated torrent content.
    let offset: Int
}

struct TorrentMetadata: Sendable {
    let name: String
    let pieceLength: Int
    let pieceHashes: [Data]   // 20 bytes each
    let files: [TorrentFile]
    let totalLength: Int

    /// Parses the bencoded `info` dictionary.
    init(infoDict: Bencode) throws {
        guard let name = infoDict["name"]?.string ?? infoDict["name.utf-8"]?.string,
              let pl = infoDict["piece length"]?.intValue, pl > 0, pl <= 64 << 20,
              let pieces = infoDict["pieces"]?.data, pieces.count % 20 == 0, !pieces.isEmpty
        else { throw TorrentError.malformed("info dict") }
        self.name = name
        self.pieceLength = pl
        let bytes = [UInt8](pieces)
        self.pieceHashes = stride(from: 0, to: bytes.count, by: 20).map { Data(bytes[$0..<($0 + 20)]) }

        var files: [TorrentFile] = []
        var offset = 0
        if let list = infoDict["files"]?.list {
            for f in list {
                guard let len = f["length"]?.intValue, len >= 0,
                      let comps = f["path"]?.list ?? f["path.utf-8"]?.list else { throw TorrentError.malformed("file entry") }
                let path = comps.compactMap(\.string).joined(separator: "/")
                files.append(TorrentFile(path: path, length: len, offset: offset))
                offset += len
            }
        } else if let len = infoDict["length"]?.intValue, len >= 0 {
            files = [TorrentFile(path: name, length: len, offset: 0)]
            offset = len
        } else {
            throw TorrentError.malformed("no files")
        }
        guard !files.isEmpty else { throw TorrentError.malformed("empty file list") }
        // piece count must cover the content exactly
        guard (offset + pl - 1) / pl == pieceHashes.count else { throw TorrentError.malformed("piece count mismatch") }
        self.files = files
        self.totalLength = offset
    }

    /// `fileIdx` if valid, else the largest file.
    func selectFile(_ idx: Int?) -> TorrentFile {
        if let i = idx, files.indices.contains(i) { return files[i] }
        return files.max { $0.length < $1.length }!
    }

    func pieceLength(at index: Int) -> Int {
        index == pieceHashes.count - 1 ? totalLength - index * pieceLength : pieceLength
    }

    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
}

enum Hex {
    static func decode(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(); var idx = s.startIndex
        while idx < s.endIndex {
            let n = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<n], radix: 16) else { return nil }
            out.append(b); idx = n
        }
        return out
    }
}
