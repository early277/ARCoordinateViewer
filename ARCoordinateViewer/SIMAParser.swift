import Foundation

struct SIMAParseResult {
    var features: [GeoFeature]
    var points: [GeoCoordinate]
    var parcelCount: Int
}

enum SIMAParserError: LocalizedError {
    case noCoordinates

    var errorDescription: String? {
        switch self {
        case .noCoordinates:
            return "SIMAの座標データを読み取れませんでした。"
        }
    }
}

enum SIMAParser {
    private struct SIMAPoint {
        var aliases: [String]
        var coordinate: GeoCoordinate
    }

    static func looksLikeSIMA(_ text: String) -> Bool {
        let upper = text.prefix(4096).uppercased()
        return upper.contains("A01") || upper.contains("A00") || upper.contains("D00") || upper.contains("D99")
    }

    static func parse(text: String, defaultPlaneSystem: Int) throws -> SIMAParseResult {
        let rows = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { parseLine(String($0)) }
            .filter { !$0.isEmpty }

        var points: [SIMAPoint] = []
        var aliasMap: [String: GeoCoordinate] = [:]
        var parcelFeatures: [GeoFeature] = []

        var insideParcel = false
        var currentParcelName = "画地"
        var currentParcelCoordinates: [GeoCoordinate] = []
        var parcelIndex = 1

        for row in rows {
            let code = row.first?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""

            if code == "A01", let point = try parseCoordinateRow(row, defaultPlaneSystem: defaultPlaneSystem) {
                points.append(point)
                for alias in point.aliases {
                    aliasMap[normalizeKey(alias)] = point.coordinate
                }
                continue
            }

            if code == "D00" {
                if insideParcel, currentParcelCoordinates.count >= 2 {
                    parcelFeatures.append(makeParcelFeature(name: currentParcelName, coordinates: currentParcelCoordinates))
                }
                insideParcel = true
                currentParcelCoordinates = []
                currentParcelName = firstMeaningfulText(in: Array(row.dropFirst())) ?? "画地\(parcelIndex)"
                parcelIndex += 1
                continue
            }

            if code == "D99" {
                if insideParcel, currentParcelCoordinates.count >= 2 {
                    parcelFeatures.append(makeParcelFeature(name: currentParcelName, coordinates: currentParcelCoordinates))
                }
                insideParcel = false
                currentParcelCoordinates = []
                continue
            }

            if insideParcel {
                // B01行は画地名ではなく点参照であることが多い。
                // D00,画地番号,画地名,... で取得した画地名を維持する。
                let referenced = referencedCoordinates(in: row, aliasMap: aliasMap)
                if !referenced.isEmpty {
                    currentParcelCoordinates.append(contentsOf: referenced)
                }
            }
        }

        if insideParcel, currentParcelCoordinates.count >= 2 {
            parcelFeatures.append(makeParcelFeature(name: currentParcelName, coordinates: currentParcelCoordinates))
        }

        let geoPoints = points.map { $0.coordinate }
        guard !geoPoints.isEmpty else { throw SIMAParserError.noCoordinates }

        let pointFeatures = geoPoints.map { point in
            GeoFeature(name: point.name ?? "点", kind: .point, coordinates: [point])
        }

        // 画地がある場合も、点は現在地選択用・単独点確認用として残す。
        let features = pointFeatures + parcelFeatures
        return SIMAParseResult(features: features, points: geoPoints, parcelCount: parcelFeatures.count)
    }

    private static func parseCoordinateRow(_ row: [String], defaultPlaneSystem: Int) throws -> SIMAPoint? {
        guard row.count >= 4 else { return nil }

        // 一般的なSIMA座標行：A01,点番号,点名,X,Y,Z
        // 点番号・点名が数字だけの場合でも、X/Yを誤認しないように列位置を優先する。
        if row.count >= 5,
           let x = Double(row[3].trimmingCharacters(in: .whitespacesAndNewlines)),
           let y = Double(row[4].trimmingCharacters(in: .whitespacesAndNewlines)) {
            let z = row.count >= 6 ? Double(row[5].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            let pointNumber = row.count >= 2 ? row[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let pointName = row.count >= 3 ? row[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let name = pointName.isEmpty ? (pointNumber.isEmpty ? "SIMA点" : pointNumber) : pointName

            var coord = try JapanesePlaneRectangularSystem.toGeodetic(system: defaultPlaneSystem, x: x, y: y)
            coord.name = name
            coord.altitude = z

            var aliases = [pointNumber, pointName, name]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return SIMAPoint(aliases: Array(Set(aliases)), coordinate: coord)
        }

        let tail = Array(row.dropFirst())
        let numericFlags = tail.map { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }

        // フォールバック：後方から連続する数値群を座標候補として扱う。
        var end = numericFlags.count - 1
        while end >= 0, !numericFlags[end] { end -= 1 }
        guard end >= 1 else { return nil }

        var start = end
        while start - 1 >= 0, numericFlags[start - 1] { start -= 1 }

        let numericCells = tail[start...end].compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard numericCells.count >= 2 else { return nil }

        let x: Double
        let y: Double
        let z: Double?
        if numericCells.count >= 3 {
            x = numericCells[numericCells.count - 3]
            y = numericCells[numericCells.count - 2]
            z = numericCells[numericCells.count - 1]
        } else {
            x = numericCells[numericCells.count - 2]
            y = numericCells[numericCells.count - 1]
            z = nil
        }

        let aliasCells = Array(tail.prefix(start))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let name = aliasCells.last ?? "SIMA点"
        var coord = try JapanesePlaneRectangularSystem.toGeodetic(system: defaultPlaneSystem, x: x, y: y)
        coord.name = name
        coord.altitude = z

        var aliases = aliasCells
        aliases.append(name)
        return SIMAPoint(aliases: Array(Set(aliases)), coordinate: coord)
    }

    private static func referencedCoordinates(in row: [String], aliasMap: [String: GeoCoordinate]) -> [GeoCoordinate] {
        var result: [GeoCoordinate] = []
        var seen = Set<String>()
        for cell in row.dropFirst() {
            let key = normalizeKey(cell)
            guard !key.isEmpty, !seen.contains(key), let coordinate = aliasMap[key] else { continue }
            result.append(coordinate)
            seen.insert(key)
        }
        return result
    }

    private static func makeParcelFeature(name: String, coordinates: [GeoCoordinate]) -> GeoFeature {
        let kind: GeometryKind = coordinates.count >= 3 ? .polygon : .line
        return GeoFeature(name: name, kind: kind, coordinates: coordinates, labelRole: .parcel)
    }

    private static func firstMeaningfulText(in cells: [String]) -> String? {
        for cell in cells {
            let text = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if Double(text) != nil { continue }
            return text
        }
        return cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func normalizeKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\"", with: "")
    }

    private static func parseLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "\"" {
                if inQuotes, index + 1 < chars.count, chars[index + 1] == "\"" {
                    current.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if ch == ",", !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            index += 1
        }
        result.append(current)
        return result
    }
}
