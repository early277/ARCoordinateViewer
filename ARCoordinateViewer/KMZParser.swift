import Foundation
import Compression

enum KMZParserError: LocalizedError {
    case noKMLFile
    case unsupportedCompression(method: UInt16)
    case decompressionFailed
    case invalidZip

    var errorDescription: String? {
        switch self {
        case .noKMLFile:
            return "KMZ内にKMLファイルが見つかりませんでした。"
        case .unsupportedCompression(let method):
            return "未対応のKMZ圧縮方式です：\(method)"
        case .decompressionFailed:
            return "KMZ内KMLの展開に失敗しました。"
        case .invalidZip:
            return "KMZ/ZIP構造を解析できませんでした。"
        }
    }
}

enum KMZParser {
    private struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var localHeaderOffset: UInt32
    }

    static func extractKMLData(from data: Data) throws -> Data {
        let entries = try readCentralDirectory(from: data)
        let candidates = entries
            .filter { $0.name.lowercased().hasSuffix(".kml") }
            .sorted { lhs, rhs in
                if lhs.name.lowercased() == "doc.kml" { return true }
                if rhs.name.lowercased() == "doc.kml" { return false }
                return lhs.name.count < rhs.name.count
            }

        guard let kmlEntry = candidates.first else { throw KMZParserError.noKMLFile }
        return try extract(entry: kmlEntry, from: data)
    }

    private static func readCentralDirectory(from data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw KMZParserError.invalidZip }

        let signature: UInt32 = 0x06054b50
        let maxCommentLength = min(data.count - 22, 65535)
        var eocdOffset: Int?
        var offset = data.count - 22
        let minOffset = data.count - 22 - maxCommentLength
        while offset >= minOffset {
            if readUInt32(data, offset) == signature {
                eocdOffset = offset
                break
            }
            offset -= 1
        }
        guard let eocd = eocdOffset else { throw KMZParserError.invalidZip }

        let entryCount = Int(readUInt16(data, eocd + 10))
        let centralOffset = Int(readUInt32(data, eocd + 16))
        var entries: [Entry] = []
        var p = centralOffset

        for _ in 0..<entryCount {
            guard p + 46 <= data.count, readUInt32(data, p) == 0x02014b50 else { break }
            let method = readUInt16(data, p + 10)
            let compressedSize = readUInt32(data, p + 20)
            let uncompressedSize = readUInt32(data, p + 24)
            let nameLength = Int(readUInt16(data, p + 28))
            let extraLength = Int(readUInt16(data, p + 30))
            let commentLength = Int(readUInt16(data, p + 32))
            let localHeaderOffset = readUInt32(data, p + 42)
            let nameStart = p + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count else { throw KMZParserError.invalidZip }
            let nameData = data[nameStart..<nameEnd]
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .shiftJIS)
                ?? ""
            entries.append(Entry(name: name, method: method, compressedSize: compressedSize, uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset))
            p = nameEnd + extraLength + commentLength
        }

        return entries
    }

    private static func extract(entry: Entry, from data: Data) throws -> Data {
        let local = Int(entry.localHeaderOffset)
        guard local + 30 <= data.count, readUInt32(data, local) == 0x04034b50 else { throw KMZParserError.invalidZip }
        let nameLength = Int(readUInt16(data, local + 26))
        let extraLength = Int(readUInt16(data, local + 28))
        let payloadStart = local + 30 + nameLength + extraLength
        let payloadEnd = payloadStart + Int(entry.compressedSize)
        guard payloadEnd <= data.count else { throw KMZParserError.invalidZip }
        let payload = Data(data[payloadStart..<payloadEnd])

        switch entry.method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expectedSize: Int(entry.uncompressedSize))
        default:
            throw KMZParserError.unsupportedCompression(method: entry.method)
        }
    }

    private static func inflate(_ payload: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let decoded: Int = payload.withUnsafeBytes { sourceBuffer in
            guard let sourceBase = sourceBuffer.baseAddress else { return 0 }
            return output.withUnsafeMutableBytes { destinationBuffer in
                guard let destinationBase = destinationBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase.assumingMemoryBound(to: UInt8.self),
                    expectedSize,
                    sourceBase.assumingMemoryBound(to: UInt8.self),
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded > 0 else { throw KMZParserError.decompressionFailed }
        return Data(output.prefix(decoded))
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
