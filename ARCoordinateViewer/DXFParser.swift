import Foundation

typealias DXFImportOptions = DXFCoordinateReference

/// ASCII DXFを64KiBずつ読み、1要素単位で解釈する。全文・全行配列を作らない。
struct DXFParser {
    static let drawingReferencePrefix="ARCoordinateViewer.Reference/1 "
    /// Only our explicit export metadata supplies the plane system and axis order.
    /// $INSUNITS alone cannot disambiguate Japanese north/east coordinates.
    static func drawingReference(url:URL) -> DXFCoordinateReference? {
        let access=url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let reader=try? Reader(url) else { return nil }
        do {
            var inHeader=false
            var legacyReference:DXFCoordinateReference?
            for _ in 0..<2048 {
                guard reader.readBytes<=262144,let raw=try reader.line(),let code=Int(raw),let value=try reader.line() else { return nil }
                if code==2,value=="HEADER" { inHeader=true }
                if code==0,value=="ENDSEC",inHeader { return legacyReference }
                if code==2,value=="ENTITIES" { return nil }
                guard inHeader,code==999 else { continue }
                var reference:DXFCoordinateReference?
                if value.hasPrefix(drawingReferencePrefix) {
                    reference=try? JSONDecoder().decode(DXFCoordinateReference.self,from:Data(value.dropFirst(drawingReferencePrefix.count).utf8))
                } else {
                    // Compatibility with the already installed build29 exporter.
                    let parts=value.components(separatedBy:"; ")
                    if parts.count==3,parts[0].hasPrefix("Japanese plane system "),parts[1].hasPrefix("metres/unit "),
                       let system=Int(parts[0].dropFirst("Japanese plane system ".count)),
                       let unit=Double(parts[1].dropFirst("metres/unit ".count)),["CAD X east","CAD X north"].contains(parts[2]) {
                        reference=DXFCoordinateReference(planeSystem:system,metersPerUnit:unit,xIsEasting:parts[2]=="CAD X east")
                    }
                }
                if let reference,(1...19).contains(reference.planeSystem),[1.0,0.001,0.01].contains(reference.metersPerUnit),
                   reference.insertionUnits.map({ (0...24).contains($0) }) ?? true {
                    if value.hasPrefix(drawingReferencePrefix) { return reference }
                    legacyReference=reference
                }
            }
        } catch { return nil }
        return nil
    }
    struct Result {
        var features: [GeoFeature]
        var skipped: [String: Int]
        var insertionUnits: Int? = nil
        var summary: String {
            let warnings = skipped.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
            return "\(features.count)要素" + (warnings.isEmpty ? "" : " / 未対応・除外 \(warnings)")
        }
    }
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    private struct Record {
        var type: String
        var groups: [(Int, String)] = []
        func text(_ code: Int, _ fallback: String = "") -> String { groups.first { $0.0 == code }?.1 ?? fallback }
        func value(_ code: Int, _ fallback: Double = 0) -> Double { Double(text(code)) ?? fallback }
    }
    private final class Reader {
        let file: FileHandle
        var buffer = Data()
        var cursor = 0
        var ended = false
        var readBytes = 0
        init(_ url: URL) throws { file = try FileHandle(forReadingFrom: url) }
        deinit { try? file.close() }
        func line() throws -> String? {
            while true {
                if let end = buffer[cursor...].firstIndex(of: 10) {
                    let bytes = buffer[cursor..<end]
                    cursor = end + 1
                    return (String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .shiftJIS) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if ended {
                    guard cursor < buffer.count else { return nil }
                    let bytes = buffer[cursor...]; cursor = buffer.count
                    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                buffer = Data(buffer[cursor...]); cursor = 0
                let chunk = try file.read(upToCount: 65536) ?? Data()
                readBytes += chunk.count
                if chunk.isEmpty { ended = true } else { buffer.append(chunk) }
                guard buffer.count < 4_194_304 else { throw Failure(message: "DXFの行が長すぎます。ASCII DXFで保存してください。") }
            }
        }
    }
    static func parse(url: URL, options: DXFImportOptions, progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> Result {
        let reader = try Reader(url)
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1
        var records: [String: [Record]] = [:]
        var blockBases: [String: SIMD3<Double>] = [:]
        var layerColors: [String: SourceColor] = [:]
        var blockName = ""
        var section = ""
        var current: Record?
        var polyline: Record?
        var vertices: [Record] = []
        var result = Result(features: [], skipped: [:])
        var lastProgress = -1
        func coordinate(_ x: Double, _ y: Double, _ z: Double, name: String? = nil) throws -> GeoCoordinate {
            guard x.isFinite, y.isFinite, z.isFinite, options.metersPerUnit > 0 else { throw Failure(message: "DXFに不正な座標があります。") }
            let north = (options.xIsEasting ? y : x) * options.metersPerUnit
            let east = (options.xIsEasting ? x : y) * options.metersPerUnit
            var c = try JapanesePlaneRectangularSystem.toGeodetic(system: options.planeSystem, x: north, y: east)
            c.planeSystem = options.planeSystem; c.planeNorth = north; c.planeEast = east
            c.altitude = z == 0 ? nil : z * options.metersPerUnit
            c.dxfAltitude = z * options.metersPerUnit
            c.name = name
            return c
        }
        // ブロックも含めてCAD座標内で変換し、最後に測地座標へ変換する。
        func emit(_ r: Record, transform: (SIMD3<Double>) -> SIMD3<Double> = { $0 }, depth: Int = 0, inheritedLayer: String? = nil, inheritedColor: SourceColor? = nil) throws {
            if cancelled() { throw CancellationError() }
            guard depth < 16 else { throw Failure(message: "DXFのブロック参照が深すぎるか循環しています。") }
            if r.value(67) == 1 { return } // model space only
            if r.value(210) != 0 || r.value(220) != 0 || r.value(230, 1) != 1 {
                result.skipped["傾斜OCS", default: 0] += 1; return
            }
            for (code, text) in r.groups where (10...59).contains(code) || (70...79).contains(code) || (90...99).contains(code) {
                guard let value = Double(text), value.isFinite, abs(value) < 1e12 else { throw Failure(message: "DXFの数値が不正です：\(r.type) / コード\(code)") }
            }
            let required: [Int] = r.type == "LINE" ? [10,20,11,21] : (["POINT","TEXT","MTEXT","ARC","CIRCLE","INSERT"].contains(r.type) ? [10,20] : [])
            guard required.allSatisfy({ !r.text($0).isEmpty }) else { throw Failure(message: "DXFの水平座標が不足しています：\(r.type)") }
            let rawLayer = r.text(8, "0")
            let layer = rawLayer == "0" ? (inheritedLayer ?? rawLayer) : rawLayer
            let index = Int(r.text(62)) ?? 256
            let sourceColor: SourceColor?
            if let rgb = Int(r.text(420)), (0...0xffffff).contains(rgb) { sourceColor = SourceColor.rgb(rgb) }
            else if index == 0 { sourceColor = inheritedColor ?? layerColors[layer] }
            else if index == 256 { sourceColor = layerColors[layer] }
            else { sourceColor = SourceColor.aci(abs(index)) }
            var points: [SIMD3<Double>] = []
            var kind: GeometryKind = .line
            var name = layer
            func vertex(_ base: Int) -> SIMD3<Double> { SIMD3(r.value(base), r.value(base + 10), r.value(base + 20)) }
            switch r.type {
            case "LINE": points = [vertex(10), vertex(11)]
            case "POINT", "TEXT", "MTEXT":
                points = [vertex(10)]; kind = .point
                name = r.type == "POINT" ? r.text(5, layer) : r.text(1, layer)
            case "LWPOLYLINE":
                var raw: [(SIMD3<Double>, Double)] = []
                for (code, text) in r.groups {
                    guard let n = Double(text), n.isFinite else { continue }
                    if code == 10 { raw.append((SIMD3(n, 0, r.value(38)), 0)) }
                    else if !raw.isEmpty {
                        if code == 20 { raw[raw.count - 1].0.y = n }
                        if code == 42 { raw[raw.count - 1].1 = n }
                    }
                }
                guard r.groups.filter({ $0.0 == 10 }).count == r.groups.filter({ $0.0 == 20 }).count else { throw Failure(message: "DXFポリラインのXY数が一致しません。") }
                let closed = Int(r.value(70)) & 1 != 0
                for i in raw.indices {
                    points.append(raw[i].0)
                    let j = (i + 1) % max(1, raw.count)
                    if i + 1 < raw.count || closed {
                        let a = raw[i].0, b = raw[j].0, bulge = raw[i].1
                        if abs(bulge) > 1e-12 {
                            let dx = b.x - a.x, dy = b.y - a.y, chord = hypot(dx, dy)
                            guard chord > 0 else { continue }
                            let sweep = 4 * atan(bulge)
                            let h = chord * (1 - bulge * bulge) / (4 * bulge)
                            let cx = (a.x + b.x) / 2 - dy / chord * h
                            let cy = (a.y + b.y) / 2 + dx / chord * h
                            let radius = hypot(a.x - cx, a.y - cy)
                            let count = arcCount(radius: radius * options.metersPerUnit, sweep: sweep)
                            let start = atan2(a.y - cy, a.x - cx)
                            for k in 1..<count {
                                let t = Double(k) / Double(count), angle = start + sweep * t
                                points.append(SIMD3(cx + radius * cos(angle), cy + radius * sin(angle), a.z + (b.z - a.z) * t))
                            }
                        }
                    }
                }
                kind = closed ? .polygon : .line
            case "ARC", "CIRCLE":
                let center = vertex(10), radius = r.value(40)
                guard radius > 0, radius.isFinite else { throw Failure(message: "DXFの円弧半径が不正です。") }
                let start = r.type == "CIRCLE" ? 0 : r.value(50) * .pi / 180
                var sweep = r.type == "CIRCLE" ? 2 * Double.pi : (r.value(51) - r.value(50)) * .pi / 180
                if sweep <= 0 { sweep += 2 * .pi }
                let count = arcCount(radius: radius * options.metersPerUnit, sweep: sweep)
                for i in 0...count {
                    let a = start + sweep * Double(i) / Double(count)
                    points.append(SIMD3(center.x + radius * cos(a), center.y + radius * sin(a), center.z))
                }
            case "INSERT":
                let key = r.text(2)
                guard let content = records[key] else { result.skipped["未解決BLOCK:\(key)", default: 0] += 1; return }
                let base = blockBases[key] ?? .zero, offset = vertex(10)
                let sx = r.value(41, 1), sy = r.value(42, 1), sz = r.value(43, 1), angle = r.value(50) * .pi / 180
                let columns = max(1, min(10000, Int(r.value(70, 1)))), rows = max(1, min(10000, Int(r.value(71, 1))))
                guard columns * rows <= 100000 else { throw Failure(message: "ブロック配列が大きすぎます。") }
                for row in 0..<rows { for column in 0..<columns { for child in content {
                    try emit(child, transform: { p in
                        let q = p - base
                        let x = q.x * sx + Double(column) * r.value(44)
                        let y = q.y * sy + Double(row) * r.value(45)
                        return transform(offset + SIMD3(x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle), q.z * sz))
                    }, depth: depth + 1, inheritedLayer: layer, inheritedColor: sourceColor)
                } } }
                return
            case "SEQEND", "ATTRIB": return
            default: result.skipped[r.type, default: 0] += 1; return
            }
            guard !points.isEmpty else { return }
            let coords = try points.map { p -> GeoCoordinate in
                let q = transform(p); return try coordinate(q.x, q.y, q.z, name: kind == .point ? name : nil)
            }
            var feature = GeoFeature(name: name, kind: kind, coordinates: coords)
            feature.sourceLayer = layer
            feature.sourceColor = sourceColor
            result.features.append(feature)
        }
        func consume(_ r: Record) throws {
            switch r.type {
            case "LAYER" where section == "TABLES":
                if let rgb = Int(r.text(420)), (0...0xffffff).contains(rgb) { layerColors[r.text(2)] = SourceColor.rgb(rgb) }
                else { layerColors[r.text(2)] = SourceColor.aci(abs(Int(r.text(62)) ?? 7)) }
                return
            case "SECTION":
                section = r.text(2)
                if section == "HEADER" {
                    var variable=""
                    for (code,value) in r.groups {
                        if code == 9 { variable=value }
                        if variable == "$INSUNITS", code == 70, let units=Int(value), (0...24).contains(units) { result.insertionUnits=units }
                    }
                }
                return
            case "ENDSEC": section = ""; return
            case "BLOCK": blockName = r.text(2); blockBases[blockName] = SIMD3(r.value(10), r.value(20), r.value(30)); records[blockName] = []; return
            case "ENDBLK": blockName = ""; return
            default: break
            }
            guard section == "ENTITIES" || section == "BLOCKS" else { return }
            if r.type == "POLYLINE" { polyline = r; vertices = []; return }
            if r.type == "VERTEX", polyline != nil { vertices.append(r); return }
            var output = r
            if r.type == "SEQEND", let header = polyline {
                defer { polyline = nil; vertices = [] }
                if Int(header.value(70)) & (16 | 64) != 0 { result.skipped["POLYMESH", default: 0] += 1; return }
                // 3D polyline: retain each vertex Z using LINE records, including closure.
                let count = vertices.count
                guard count >= 2 else { return }
                let closed = Int(header.value(70)) & 1 != 0
                for i in 0..<(closed ? count : count - 1) {
                    let a = vertices[i], b = vertices[(i + 1) % count]
                    if a.value(42) != 0 { result.skipped["旧POLYLINE円弧", default: 0] += 1; continue }
                    output = Record(type: "LINE", groups: [(8, header.text(8)), (10, a.text(10)), (20, a.text(20)), (30, a.text(30, header.text(30, "0"))), (11, b.text(10)), (21, b.text(20)), (31, b.text(30, header.text(30, "0")))])
                    output.groups += header.groups.filter { [62,420].contains($0.0) }
                    if section == "BLOCKS" { records[blockName, default: []].append(output) } else { try emit(output) }
                }
                return
            }
            if section == "BLOCKS", !blockName.isEmpty { records[blockName, default: []].append(output) }
            else if section == "ENTITIES" { try emit(output) }
        }
        var sawEOF = false
        while let codeLine = try reader.line() {
            if cancelled() { throw CancellationError() }
            guard let code = Int(codeLine), let value = try reader.line() else { throw Failure(message: "ASCII DXFのグループコードを読み取れません。バイナリDXFは未対応です。") }
            if code == 0 {
                if let r = current { try consume(r) }
                current = Record(type: value)
                if value == "EOF" { sawEOF = true; break }
            } else { current?.groups.append((code, value)) }
            let percent = Int(Double(reader.readBytes) / Double(max(1, size)) * 100)
            if percent != lastProgress { progress(min(0.99, Double(percent) / 100)); lastProgress = percent }
        }
        guard sawEOF else { throw Failure(message: "DXFが途中で終了しています（EOFがありません）。") }
        guard !result.features.isEmpty else { throw Failure(message: "対応する図形がありません。\(result.summary)") }
        progress(1)
        return result
    }
    private static func arcCount(radius: Double, sweep: Double) -> Int {
        let step = 2 * acos(max(-1, min(1, 1 - 0.02 / max(radius, 0.02))))
        return max(2, min(65536, Int(ceil(abs(sweep) / max(step, 0.0001)))))
    }
}
