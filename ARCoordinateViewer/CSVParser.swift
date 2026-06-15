import Foundation

struct CSVParseResult {
    var features: [GeoFeature]
    var points: [GeoCoordinate]
}

enum CSVParser {
    static func preview(text: String) -> CSVPreviewData {
        let rows = parsedRows(from: text)
        let first = rows.first ?? []
        let hasHeader = first.contains { cell in
            let s = normalize(cell)
            return ["name", "point", "pointname", "lat", "latitude", "lon", "lng", "longitude", "x", "y", "z", "alt", "altitude", "height", "system", "zone", "点名", "名称", "緯度", "経度", "標高", "高さ", "系", "系番号"].contains(s)
        }
        let columnCount = rows.map { $0.count }.max() ?? 0
        let headers: [String]
        if hasHeader {
            headers = (0..<columnCount).map { index in
                index < first.count && !first[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? first[index].trimmingCharacters(in: .whitespacesAndNewlines) : "列\(index + 1)"
            }
        } else {
            headers = (0..<columnCount).map { "列\($0 + 1)" }
        }
        return CSVPreviewData(rows: rows, hasHeader: hasHeader, headers: headers, columnCount: columnCount)
    }

    static func parse(text: String, mapping: CSVColumnMapping) throws -> CSVParseResult {
        let rows = parsedRows(from: text)
        let dataRows = mapping.hasHeader ? Array(rows.dropFirst()) : rows
        var points: [GeoCoordinate] = []

        for (rowIndex, row) in dataRows.enumerated() {
            func cell(_ index: Int?) -> String? {
                guard let index, index >= 0, index < row.count else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            guard let firstText = cell(mapping.firstCoordinateColumn),
                  let secondText = cell(mapping.secondCoordinateColumn),
                  let firstValue = Double(firstText),
                  let secondValue = Double(secondText) else {
                continue
            }

            let nameText = cell(mapping.nameColumn)
            let name = nameText?.isEmpty == false ? nameText : "P\(rowIndex + 1)"
            let altitude = cell(mapping.altitudeColumn).flatMap(Double.init)

            switch mapping.coordinateKind {
            case .latLon:
                points.append(GeoCoordinate(name: name, latitude: firstValue, longitude: secondValue, altitude: altitude))
            case .planeXY:
                var coord = try JapanesePlaneRectangularSystem.toGeodetic(
                    system: mapping.planeSystemNumber,
                    x: firstValue,
                    y: secondValue
                )
                coord.name = name
                coord.altitude = altitude
                points.append(coord)
            }
        }

        let features = points.map { point in
            GeoFeature(name: point.name ?? "点", kind: .point, coordinates: [point])
        }
        return CSVParseResult(features: features, points: points)
    }

    static func parse(text: String, defaultPlaneSystem: Int) throws -> CSVParseResult {
        let rows = parsedRows(from: text)

        guard let first = rows.first else {
            return CSVParseResult(features: [], points: [])
        }

        let hasHeader = first.contains { cell in
            let s = normalize(cell)
            return ["name", "point", "lat", "latitude", "lon", "lng", "longitude", "x", "y", "z", "system", "系"].contains(s)
        }

        let header: [String]
        let dataRows: [[String]]
        if hasHeader {
            header = first.map { normalize($0) }
            dataRows = Array(rows.dropFirst())
        } else {
            header = []
            dataRows = rows
        }

        var points: [GeoCoordinate] = []

        for (rowIndex, row) in dataRows.enumerated() {
            if hasHeader {
                if let point = try parseHeaderRow(row, header: header, defaultPlaneSystem: defaultPlaneSystem) {
                    points.append(point)
                }
            } else {
                if let point = try parseNoHeaderRow(row, rowIndex: rowIndex, defaultPlaneSystem: defaultPlaneSystem) {
                    points.append(point)
                }
            }
        }

        let features = points.map { point in
            GeoFeature(name: point.name ?? "点", kind: .point, coordinates: [point])
        }
        return CSVParseResult(features: features, points: points)
    }

    private static func parseHeaderRow(_ row: [String], header: [String], defaultPlaneSystem: Int) throws -> GeoCoordinate? {
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let index = header.firstIndex(of: key), index < row.count {
                    let v = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !v.isEmpty { return v }
                }
            }
            return nil
        }

        let name = value(["name", "point", "pointname", "点名", "名称"])
        let altitude = value(["alt", "altitude", "z", "height", "標高", "高さ"]).flatMap(Double.init)

        if let latText = value(["lat", "latitude", "緯度"]),
           let lonText = value(["lon", "lng", "longitude", "経度"]),
           let lat = Double(latText),
           let lon = Double(lonText) {
            return GeoCoordinate(name: name, latitude: lat, longitude: lon, altitude: altitude)
        }

        if let xText = value(["x", "x座標", "north", "北"]),
           let yText = value(["y", "y座標", "east", "東"]),
           let x = Double(xText),
           let y = Double(yText) {
            let system = value(["system", "系", "系番号", "zone"]).flatMap(Int.init) ?? defaultPlaneSystem
            var coord = try JapanesePlaneRectangularSystem.toGeodetic(system: system, x: x, y: y)
            coord.name = name
            coord.altitude = altitude
            return coord
        }

        return nil
    }

    private static func parseNoHeaderRow(_ row: [String], rowIndex: Int, defaultPlaneSystem: Int) throws -> GeoCoordinate? {
        guard row.count >= 3 else { return nil }
        let name = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let v1 = Double(row[1].trimmingCharacters(in: .whitespacesAndNewlines))
        let v2 = Double(row[2].trimmingCharacters(in: .whitespacesAndNewlines))
        let altitude = row.count >= 4 ? Double(row[3].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        guard let a = v1, let b = v2 else { return nil }

        // ヘッダーなしの場合：緯度経度らしい範囲なら lat/lon、それ以外は平面直角座標 X/Y とみなす。
        if abs(a) <= 90, abs(b) <= 180 {
            return GeoCoordinate(name: name.isEmpty ? "P\(rowIndex + 1)" : name, latitude: a, longitude: b, altitude: altitude)
        } else {
            var coord = try JapanesePlaneRectangularSystem.toGeodetic(system: defaultPlaneSystem, x: a, y: b)
            coord.name = name.isEmpty ? "P\(rowIndex + 1)" : name
            coord.altitude = altitude
            return coord
        }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private static func parsedRows(from text: String) -> [[String]] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { parseLine(String($0)) }
            .filter { !$0.isEmpty }
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
