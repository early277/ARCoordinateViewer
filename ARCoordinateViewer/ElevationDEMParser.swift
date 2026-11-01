import Foundation
import Compression

/// DEMを読み込む対象範囲。緯度経度の外接矩形で表す。
///
/// 既存の点・線データから作成し、ZIP内の3次メッシュXMLを
/// 完全展開する前の選別に使う。
struct DEMImportRegion: Equatable, Sendable {
    var minimumLatitude: Double
    var maximumLatitude: Double
    var minimumLongitude: Double
    var maximumLongitude: Double

    init(
        minimumLatitude: Double,
        maximumLatitude: Double,
        minimumLongitude: Double,
        maximumLongitude: Double
    ) {
        self.minimumLatitude = min(minimumLatitude, maximumLatitude)
        self.maximumLatitude = max(minimumLatitude, maximumLatitude)
        self.minimumLongitude = min(minimumLongitude, maximumLongitude)
        self.maximumLongitude = max(minimumLongitude, maximumLongitude)
    }

    func expanded(by meters: Double) -> DEMImportRegion {
        guard meters.isFinite, meters > 0 else { return self }
        let centerLatitude = (minimumLatitude + maximumLatitude) * 0.5
        let latitudeDegrees = meters / 111_320.0
        let longitudeScale = max(0.1, cos(centerLatitude * .pi / 180.0))
        let longitudeDegrees = meters / (111_320.0 * longitudeScale)
        return DEMImportRegion(
            minimumLatitude: max(minimumLatitude - latitudeDegrees, -90),
            maximumLatitude: min(maximumLatitude + latitudeDegrees, 90),
            minimumLongitude: minimumLongitude - longitudeDegrees,
            maximumLongitude: maximumLongitude + longitudeDegrees
        )
    }

    func intersects(_ other: DEMImportRegion) -> Bool {
        maximumLatitude >= other.minimumLatitude
            && other.maximumLatitude >= minimumLatitude
            && maximumLongitude >= other.minimumLongitude
            && other.maximumLongitude >= minimumLongitude
    }
}

enum ElevationDEMError: LocalizedError {
    case notGSIDEM
    case invalidXML(String)
    case unsupportedSRS(String)
    case unsupportedSequence(String)
    case invalidGridSize
    case tooManyCells(Int)
    case invalidTuple(String)
    case noValidElevation
    case invalidZIP
    case zip64Unsupported
    case tooManyArchiveEntries
    case archiveTooLarge
    case unsupportedZIPCompression(UInt16)
    case encryptedZIPUnsupported
    case zipIntegrityFailed
    case decompressionFailed
    case noDEMXML
    case noDEMXMLInTargetRegion
    case nestedZIPUnsupported

    var errorDescription: String? {
        switch self {
        case .notGSIDEM:
            return "基盤地図情報の数値標高モデルXMLではありません。"
        case .invalidXML(let detail):
            return "基盤地図情報DEMのXMLを解析できません：\(detail)"
        case .unsupportedSRS(let name):
            return "未対応の基盤地図情報DEM座標系です：\(name)"
        case .unsupportedSequence(let order):
            return "未対応のDEM走査順です：\(order)"
        case .invalidGridSize:
            return "DEMの行列サイズまたは範囲が不正です。"
        case .tooManyCells(let count):
            return "DEMのセル数が多すぎます（\(count)セル）。範囲を分けて読み込んでください。"
        case .invalidTuple(let text):
            return "DEM標高値を解析できません：\(text)"
        case .noValidElevation:
            return "DEM内に有効な標高値がありません。"
        case .invalidZIP:
            return "ZIP構造を解析できません。"
        case .zip64Unsupported:
            return "ZIP64形式には未対応です。通常のZIPとして再圧縮してください。"
        case .tooManyArchiveEntries:
            return "ZIP内のファイル数が多すぎます。"
        case .archiveTooLarge:
            return "ZIP展開後のデータ量が大きすぎます。範囲を分けてください。"
        case .unsupportedZIPCompression(let method):
            return "ZIPの圧縮方式\(method)には未対応です。"
        case .encryptedZIPUnsupported:
            return "暗号化されたZIPには対応していません。"
        case .zipIntegrityFailed:
            return "ZIP内DEMの整合性確認に失敗しました。再ダウンロードしてください。"
        case .decompressionFailed:
            return "ZIP内DEMの展開に失敗しました。"
        case .noDEMXML:
            return "ZIP内に基盤地図情報DEMのXMLが見つかりません。"
        case .noDEMXMLInTargetRegion:
            return "対象データの範囲に重なる基盤地図情報DEMがありません。"
        case .nestedZIPUnsupported:
            return "まとめてダウンロードした外側のZIPです。内側のFG-GML-DEM ZIPを選択してください。"
        }
    }
}

enum GSIElevationDEMParser {
    private static let maximumCellsPerGrid = 2_000_000
    // 1m DEMの配布ZIPは、複数の3次メッシュXMLをまとめて含むことがある。
    // 1枚あたりは1125×750セル（843,750セル）なので、従来の12Mセル上限では
    // 1mデータだけがZIP全体の途中で止まりやすかった。Float配列で保持する上限は
    // 48Mセル（約192MB）に留め、端末上での過大な展開を避ける。
    private static let maximumCellsPerImport = 48_000_000

    static func parseXML(data: Data, fileName: String) throws -> ElevationGrid {
        let delegate = GSIDEMXMLDelegate(fileName: fileName, maximumCells: maximumCellsPerGrid)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let detail = delegate.failureMessage
                ?? parser.parserError?.localizedDescription
                ?? "XML形式エラー"
            throw ElevationDEMError.invalidXML(detail)
        }
        if let failureMessage = delegate.failureMessage {
            throw ElevationDEMError.invalidXML(failureMessage)
        }
        return try delegate.makeGrid()
    }

    static func parseZIP(
        data: Data,
        fileName: String,
        targetRegion: DEMImportRegion? = nil,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> [ElevationGrid] {
        progress?(0, "ZIPの構造を確認中…")
        let archive = try DEMZIPArchive(data: data)
        let allXMLEntries = archive.entries
            .filter { $0.name.lowercased().hasSuffix(".xml") }
            .sorted { lhs, rhs in
                demPriority(for: lhs.name) < demPriority(for: rhs.name)
            }
        guard !allXMLEntries.isEmpty else {
            if archive.entries.contains(where: { $0.name.lowercased().hasSuffix(".zip") }) {
                throw ElevationDEMError.nestedZIPUnsupported
            }
            throw ElevationDEMError.noDEMXML
        }

        let xmlEntries: [DEMZIPEntry]
        if let targetRegion {
            let selected = allXMLEntries.filter { entry in
                guard let tileRegion = tileRegion(for: entry.name) else {
                    // 現行の基盤地図情報DEMの標準ファイル名は3次メッシュ番号を
                    // 含む。判定できないXMLは欠落を避けるため保守的に残す。
                    return true
                }
                return tileRegion.intersects(targetRegion)
            }
            guard !selected.isEmpty else {
                throw ElevationDEMError.noDEMXMLInTargetRegion
            }
            xmlEntries = selected
            progress?(
                0.01,
                "対象範囲のDEM XMLを選別しました（"
                    + String(selected.count)
                    + "/"
                    + String(allXMLEntries.count)
                    + "枚）"
            )
        } else {
            xmlEntries = allXMLEntries
        }

        // 対象範囲がある場合は、選別されたXMLだけを展開量の上限に含める。
        // ZIP全体のメタデータには対象外タイルのサイズも含まれるため、ここで
        // archive.entries 全体を検査すると、必要な範囲だけ読み込む前に失敗する。
        try archive.validateExpandedSize(of: targetRegion == nil ? archive.entries : xmlEntries)

        var grids: [ElevationGrid] = []
        var totalCells = 0

        for (index, entry) in xmlEntries.enumerated() {
            let entryProgress = Double(index) / Double(max(xmlEntries.count, 1))
            progress?(
                entryProgress,
                "DEM XMLを解析中… " + String(index + 1) + "/" + String(xmlEntries.count)
            )
            do {
                let xml = try archive.extract(entry)
                let grid = try parseXML(data: xml, fileName: entry.name)
                let nextCellCount = totalCells + grid.width * grid.height
                guard nextCellCount <= maximumCellsPerImport else {
                    throw ElevationDEMError.tooManyCells(nextCellCount)
                }
                totalCells = nextCellCount
                grids.append(grid)
                progress?(
                    Double(index + 1) / Double(max(xmlEntries.count, 1)),
                    "DEM XMLを解析中… "
                        + String(index + 1)
                        + "/"
                        + String(xmlEntries.count)
                        + "（"
                        + totalCells.formatted()
                        + "セル）"
                )
            } catch ElevationDEMError.notGSIDEM {
                continue
            } catch {
                // 一部タイルだけを黙って省略すると、境界に気付けない標高穴が生じる。
                // DEM以外の正常なXMLだけをnotGSIDEMで読み飛ばし、その他は読込全体を失敗させる。
                throw error
            }
        }

        guard !grids.isEmpty else {
            throw ElevationDEMError.noDEMXML
        }
        return grids.sorted {
            if $0.estimatedCellSizeMeters != $1.estimatedCellSizeMeters {
                return $0.estimatedCellSizeMeters < $1.estimatedCellSizeMeters
            }
            return demPriority(for: $0.name) < demPriority(for: $1.name)
        }
    }

    private static func demPriority(for name: String) -> Int {
        let upper = name.uppercased()
        if upper.contains("DEM1A") { return 0 }
        if upper.contains("DEM5A") { return 1 }
        if upper.contains("DEM5B") { return 2 }
        if upper.contains("DEM5C") { return 3 }
        if upper.contains("DEM10A") { return 4 }
        if upper.contains("DEM10B") { return 5 }
        return 6
    }

    /// 基盤地図情報DEMの標準XMLファイル名から3次メッシュの範囲を求める。
    ///
    /// 例：FG-GML-5538-16-01-DEM1A-20251208.xml
    /// 1次メッシュ緯度2桁・経度2桁、2次メッシュ緯度経度各1桁、
    /// 3次メッシュ緯度経度各1桁という標準地域メッシュの定義を使う。
    private static func tileRegion(for fileName: String) -> DEMImportRegion? {
        let baseName = URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
        let parts = baseName.split(separator: "-").map(String.init)
        guard let demIndex = parts.firstIndex(where: { $0.uppercased().hasPrefix("DEM") }) else {
            return nil
        }

        let preceding = parts[..<demIndex].filter { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                CharacterSet.decimalDigits.contains($0)
            }
        }
        let code: String
        if let combined = preceding.last, combined.count == 8 {
            code = combined
        } else if preceding.count >= 3,
                  preceding[preceding.count - 3].count == 4,
                  preceding[preceding.count - 2].count == 2,
                  preceding[preceding.count - 1].count == 2 {
            code = preceding[(preceding.count - 3)...].joined()
        } else {
            return nil
        }

        let digits = Array(code)
        guard digits.count == 8,
              let firstLatitude = Int(String(digits[0...1])),
              let firstLongitude = Int(String(digits[2...3])),
              let secondLatitude = Int(String(digits[4])),
              let secondLongitude = Int(String(digits[5])),
              let thirdLatitude = Int(String(digits[6])),
              let thirdLongitude = Int(String(digits[7])),
              secondLatitude <= 7,
              secondLongitude <= 7,
              thirdLatitude <= 9,
              thirdLongitude <= 9 else {
            return nil
        }

        let minimumLatitude = Double(firstLatitude) / 1.5
            + Double(secondLatitude) / 12.0
            + Double(thirdLatitude) / 120.0
        let minimumLongitude = 100.0 + Double(firstLongitude)
            + Double(secondLongitude) / 8.0
            + Double(thirdLongitude) / 80.0
        return DEMImportRegion(
            minimumLatitude: minimumLatitude,
            maximumLatitude: minimumLatitude + 1.0 / 120.0,
            minimumLongitude: minimumLongitude,
            maximumLongitude: minimumLongitude + 1.0 / 80.0
        )
    }
}

private final class GSIDEMXMLDelegate: NSObject, XMLParserDelegate {
    private let fileName: String
    private let maximumCells: Int

    private var foundDEMElement = false
    private var tupleListCount = 0
    private var lowerCorner: [Double]?
    private var upperCorner: [Double]?
    private var low: [Int]?
    private var high: [Int]?
    private var startPoint: [Int]?
    private var sequenceOrder = "+x-y"
    private var srsName = ""
    private var demType = ""
    private var meshCode = ""
    private var captureElement: String?
    private var captureText = ""
    private var insideTupleList = false
    private var tupleRemainder = ""
    private var tupleValues: [Float] = []

    fileprivate var failureMessage: String?

    init(fileName: String, maximumCells: Int) {
        self.fileName = fileName
        self.maximumCells = maximumCells
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.localName(elementName)
        if name == "DEM" {
            if foundDEMElement {
                failureMessage = "1つのXMLに複数のDEM要素がある形式には未対応です"
                return
            }
            foundDEMElement = true
        }
        if name == "Envelope", let value = attributeDict["srsName"] {
            srsName = value
        }
        if name == "sequenceRule", let value = attributeDict["order"] {
            sequenceOrder = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name == "tupleList" {
            tupleListCount += 1
            if tupleListCount > 1 {
                failureMessage = "1つのXMLに複数のcoverageがある形式には未対応です"
                return
            }
            insideTupleList = true
            tupleRemainder = ""
            return
        }

        let capturedNames: Set<String> = [
            "lowerCorner", "upperCorner", "low", "high", "startPoint", "type", "mesh"
        ]
        if capturedNames.contains(name) {
            captureElement = name
            captureText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failureMessage == nil else { return }
        if insideTupleList {
            consumeTupleCharacters(string)
        } else if captureElement != nil {
            captureText.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.localName(elementName)
        if name == "tupleList" {
            insideTupleList = false
            consumeTupleCharacters(" ")
            tupleRemainder = ""
            return
        }

        guard captureElement == name else { return }
        let text = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "lowerCorner":
            guard let values = Self.parseDoubles(text) else {
                failureMessage = "lowerCornerは2つの数値で指定してください"
                break
            }
            lowerCorner = values
        case "upperCorner":
            guard let values = Self.parseDoubles(text) else {
                failureMessage = "upperCornerは2つの数値で指定してください"
                break
            }
            upperCorner = values
        case "low":
            guard let values = Self.parseIntegers(text) else {
                failureMessage = "lowは2つの整数で指定してください"
                break
            }
            low = values
        case "high":
            guard let values = Self.parseIntegers(text) else {
                failureMessage = "highは2つの整数で指定してください"
                break
            }
            high = values
        case "startPoint":
            guard let values = Self.parseIntegers(text) else {
                failureMessage = "startPointは2つの整数で指定してください"
                break
            }
            startPoint = values
        case "type":
            if demType.isEmpty { demType = text }
        case "mesh":
            if meshCode.isEmpty { meshCode = text }
        default:
            break
        }
        captureElement = nil
        captureText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failureMessage == nil {
            failureMessage = parseError.localizedDescription
        }
    }

    fileprivate func makeGrid() throws -> ElevationGrid {
        guard foundDEMElement else { throw ElevationDEMError.notGSIDEM }
        let lowerSRS = srsName.lowercased()
        guard lowerSRS.contains("jgd2024.bl")
                || lowerSRS.contains("jgd2011.bl") else {
            throw ElevationDEMError.unsupportedSRS(
                srsName.isEmpty ? "記載なし" : srsName
            )
        }
        let normalizedSequenceOrder = Self.normalizedSequenceOrder(sequenceOrder)
        guard sequenceOrder.isEmpty || normalizedSequenceOrder == "+x-y" else {
            throw ElevationDEMError.unsupportedSequence(sequenceOrder)
        }
        guard let lowerCorner,
              lowerCorner.count >= 2,
              let upperCorner,
              upperCorner.count >= 2,
              let low,
              low.count >= 2,
              let high,
              high.count >= 2 else {
            throw ElevationDEMError.invalidGridSize
        }

        let widthDifference = high[0].subtractingReportingOverflow(low[0])
        let heightDifference = high[1].subtractingReportingOverflow(low[1])
        guard !widthDifference.overflow, !heightDifference.overflow else {
            throw ElevationDEMError.invalidGridSize
        }
        let widthResult = widthDifference.partialValue.addingReportingOverflow(1)
        let heightResult = heightDifference.partialValue.addingReportingOverflow(1)
        guard !widthResult.overflow, !heightResult.overflow else {
            throw ElevationDEMError.invalidGridSize
        }
        let width = widthResult.partialValue
        let height = heightResult.partialValue
        let multiplication = width.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              !multiplication.overflow,
              multiplication.partialValue <= maximumCells else {
            if !multiplication.overflow, multiplication.partialValue > maximumCells {
                throw ElevationDEMError.tooManyCells(multiplication.partialValue)
            }
            throw ElevationDEMError.invalidGridSize
        }
        let cellCount = multiplication.partialValue

        let start = startPoint ?? low
        guard start.count >= 2,
              start[0] >= low[0],
              start[0] <= high[0],
              start[1] >= low[1],
              start[1] <= high[1] else {
            throw ElevationDEMError.invalidGridSize
        }
        let startIndex = (start[1] - low[1]) * width + (start[0] - low[0])
        guard tupleValues.count <= cellCount - startIndex else {
            throw ElevationDEMError.invalidTuple("標高値数がグリッド範囲を超えています")
        }

        var elevations = [Float](repeating: .nan, count: cellCount)
        if !tupleValues.isEmpty {
            elevations.replaceSubrange(
                startIndex..<(startIndex + tupleValues.count),
                with: tupleValues
            )
        }
        guard elevations.contains(where: \.isFinite) else {
            throw ElevationDEMError.noValidElevation
        }

        // 基盤地図情報DEMの座標順はB,L（緯度、経度）。
        let south = lowerCorner[0]
        let west = lowerCorner[1]
        let north = upperCorner[0]
        let east = upperCorner[1]
        guard south.isFinite,
              west.isFinite,
              north.isFinite,
              east.isFinite,
              north > south,
              east > west else {
            throw ElevationDEMError.invalidGridSize
        }

        let longitudeStep = (east - west) / Double(width)
        let latitudeStep = (north - south) / Double(height)
        let transform = ElevationGridTransform(
            originX: west + longitudeStep * 0.5,
            originY: north - latitudeStep * 0.5,
            columnX: longitudeStep,
            columnY: 0,
            rowX: 0,
            rowY: -latitudeStep
        )
        let center = GeoCoordinate(
            latitude: (south + north) * 0.5,
            longitude: (west + east) * 0.5
        )
        let eastNeighbor = GeoCoordinate(
            latitude: center.latitude,
            longitude: center.longitude + longitudeStep
        )
        let northNeighbor = GeoCoordinate(
            latitude: center.latitude + latitudeStep,
            longitude: center.longitude
        )
        let eastMeters = CoordinateConverter.enuMeters(from: eastNeighbor, origin: center)
        let northMeters = CoordinateConverter.enuMeters(from: northNeighbor, origin: center)
        let estimatedCellSize = max(
            0.01,
            min(
                hypot(eastMeters.east, eastMeters.north),
                hypot(northMeters.east, northMeters.north)
            )
        )

        let datum: String
        if lowerSRS.contains("jgd2024") {
            datum = "JGD2024"
        } else if lowerSRS.contains("jgd2011") {
            datum = "JGD2011"
        } else {
            datum = srsName.isEmpty ? "測地系記載なし" : srsName
        }
        let typeText = demType.isEmpty ? "数値標高モデル" : demType
        let meshText = meshCode.isEmpty ? "" : " / メッシュ\(meshCode)"

        return ElevationGrid(
            name: fileName,
            width: width,
            height: height,
            elevations: elevations,
            transform: transform,
            coordinateReference: .geographic,
            minimumLatitude: south,
            maximumLatitude: north,
            minimumLongitude: west,
            maximumLongitude: east,
            estimatedCellSizeMeters: estimatedCellSize,
            sourceDescription: "基盤地図情報 \(typeText) / \(datum)\(meshText)"
        )
    }

    private func consumeTupleCharacters(_ string: String) {
        guard failureMessage == nil else { return }
        tupleRemainder.append(string)
        let endsWithWhitespace = tupleRemainder.unicodeScalars.last.map {
            CharacterSet.whitespacesAndNewlines.contains($0)
        } ?? true
        var components = tupleRemainder.components(separatedBy: .whitespacesAndNewlines)
        if endsWithWhitespace {
            tupleRemainder = ""
        } else {
            tupleRemainder = components.popLast() ?? ""
        }

        for token in components where !token.isEmpty {
            guard tupleValues.count < maximumCells else {
                failureMessage = "標高値数が上限\(maximumCells)セルを超えています"
                return
            }
            guard let comma = token.firstIndex(of: ",") else {
                failureMessage = "tupleListの区切りが不正です"
                return
            }
            let type = String(token[..<comma])
            let valueText = String(token[token.index(after: comma)...])
            guard let value = Double(valueText), value.isFinite else {
                failureMessage = "標高値「\(valueText)」が数値ではありません"
                return
            }
            if type.contains("データなし") || abs(value + 9999.0) < 0.001 {
                tupleValues.append(.nan)
            } else {
                guard value >= -12_000, value <= 20_000 else {
                    failureMessage = "標高値が範囲外です：\(value)"
                    return
                }
                tupleValues.append(Float(value))
            }
        }
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func parseDoubles(_ text: String) -> [Double]? {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count == 2 else { return nil }
        let values = tokens.compactMap { Double($0) }
        return values.count == 2 ? values : nil
    }

    private static func parseIntegers(_ text: String) -> [Int]? {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count == 2 else { return nil }
        let values = tokens.compactMap { Int($0) }
        return values.count == 2 ? values : nil
    }

    private static func normalizedSequenceOrder(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .filter { !$0.isWhitespace }
    }
}

struct DEMZIPEntry {
    var name: String
    var generalPurposeFlag: UInt16
    var compressionMethod: UInt16
    var crc32: UInt32
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int
}

struct DEMZIPArchive {
    private static let maximumEntries = 512
    // 現行の1m DEM ZIPは複数XMLを含み、圧縮後のファイルサイズより展開後が
    // 大きくなる。1mの通常配布データを扱えるようにしつつ、異常な圧縮爆弾は
    // 512MBで止める。
    private static let maximumExpandedBytes = 512 * 1024 * 1024
    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) != 0
                ? 0xedb8_8320 ^ (crc >> 1)
                : crc >> 1
        }
        return crc
    }

    let data: Data
    let entries: [DEMZIPEntry]

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    /// 実際に展開するエントリの合計サイズを検証する。
    ///
    /// 中央ディレクトリの読み取り時点では対象範囲をまだ判定していないため、
    /// ZIP全体の合計サイズはここでは検査しない。各エントリの展開時にも
    /// `inflate` で個別の上限を検証する。
    func validateExpandedSize(of entries: [DEMZIPEntry]) throws {
        var totalExpandedBytes = 0
        for entry in entries {
            guard entry.uncompressedSize >= 0,
                  entry.uncompressedSize <= Self.maximumExpandedBytes else {
                throw ElevationDEMError.archiveTooLarge
            }
            let (nextTotal, overflow) = totalExpandedBytes.addingReportingOverflow(
                entry.uncompressedSize
            )
            guard !overflow, nextTotal <= Self.maximumExpandedBytes else {
                throw ElevationDEMError.archiveTooLarge
            }
            totalExpandedBytes = nextTotal
        }
    }

    func extract(_ entry: DEMZIPEntry) throws -> Data {
        let local = entry.localHeaderOffset
        guard local >= 0,
              local + 30 <= data.count,
              Self.readUInt32(data, local) == 0x04034b50 else {
            throw ElevationDEMError.invalidZIP
        }
        let localFlag = Self.readUInt16(data, local + 6)
        let localMethod = Self.readUInt16(data, local + 8)
        guard localMethod == entry.compressionMethod,
              localFlag & 0x0001 == 0,
              entry.generalPurposeFlag & 0x0001 == 0 else {
            if localFlag & 0x0001 != 0 || entry.generalPurposeFlag & 0x0001 != 0 {
                throw ElevationDEMError.encryptedZIPUnsupported
            }
            throw ElevationDEMError.invalidZIP
        }
        let nameLength = Int(Self.readUInt16(data, local + 26))
        let extraLength = Int(Self.readUInt16(data, local + 28))
        let payloadStart = local + 30 + nameLength + extraLength
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadStart >= 0,
              payloadEnd >= payloadStart,
              payloadEnd <= data.count else {
            throw ElevationDEMError.invalidZIP
        }
        let payload = Data(data[payloadStart..<payloadEnd])

        let output: Data
        switch entry.compressionMethod {
        case 0:
            guard payload.count == entry.uncompressedSize else {
                throw ElevationDEMError.decompressionFailed
            }
            output = payload
        case 8:
            output = try Self.inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ElevationDEMError.unsupportedZIPCompression(entry.compressionMethod)
        }
        guard Self.crc32(output) == entry.crc32 else {
            throw ElevationDEMError.zipIntegrityFailed
        }
        return output
    }

    private static func readCentralDirectory(_ data: Data) throws -> [DEMZIPEntry] {
        guard data.count >= 22 else { throw ElevationDEMError.invalidZIP }
        let maximumCommentLength = min(data.count - 22, 65_535)
        let minimumOffset = data.count - 22 - maximumCommentLength
        var endOffset: Int?
        var cursor = data.count - 22
        while cursor >= minimumOffset {
            if readUInt32(data, cursor) == 0x06054b50 {
                endOffset = cursor
                break
            }
            cursor -= 1
        }
        guard let endOffset else { throw ElevationDEMError.invalidZIP }

        let diskNumber = readUInt16(data, endOffset + 4)
        let centralDirectoryDisk = readUInt16(data, endOffset + 6)
        let entriesOnDisk = readUInt16(data, endOffset + 8)
        let entryCount = Int(readUInt16(data, endOffset + 10))
        let centralSizeValue = readUInt32(data, endOffset + 12)
        let centralOffsetValue = readUInt32(data, endOffset + 16)
        let commentLength = Int(readUInt16(data, endOffset + 20))
        guard diskNumber == 0,
              centralDirectoryDisk == 0,
              Int(entriesOnDisk) == entryCount,
              endOffset + 22 + commentLength == data.count else {
            throw ElevationDEMError.invalidZIP
        }
        if entryCount == 0xffff
            || centralSizeValue == UInt32.max
            || centralOffsetValue == UInt32.max {
            throw ElevationDEMError.zip64Unsupported
        }
        guard entryCount <= maximumEntries else {
            throw ElevationDEMError.tooManyArchiveEntries
        }

        var entries: [DEMZIPEntry] = []
        entries.reserveCapacity(entryCount)
        var pointer = Int(centralOffsetValue)
        let centralEnd = pointer + Int(centralSizeValue)
        guard pointer >= 0,
              centralEnd >= pointer,
              centralEnd <= endOffset else {
            throw ElevationDEMError.invalidZIP
        }

        for _ in 0..<entryCount {
            guard pointer >= 0,
                  pointer + 46 <= data.count,
                  pointer + 46 <= centralEnd,
                  readUInt32(data, pointer) == 0x02014b50 else {
                throw ElevationDEMError.invalidZIP
            }
            let flag = readUInt16(data, pointer + 8)
            let method = readUInt16(data, pointer + 10)
            let crc32 = readUInt32(data, pointer + 16)
            let compressedSizeValue = readUInt32(data, pointer + 20)
            let uncompressedSizeValue = readUInt32(data, pointer + 24)
            let localOffsetValue = readUInt32(data, pointer + 42)
            if compressedSizeValue == UInt32.max
                || uncompressedSizeValue == UInt32.max
                || localOffsetValue == UInt32.max {
                throw ElevationDEMError.zip64Unsupported
            }

            let nameLength = Int(readUInt16(data, pointer + 28))
            let extraLength = Int(readUInt16(data, pointer + 30))
            let commentLength = Int(readUInt16(data, pointer + 32))
            let nameStart = pointer + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count,
                  nameEnd <= centralEnd else {
                throw ElevationDEMError.invalidZIP
            }
            let nameData = Data(data[nameStart..<nameEnd])
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .shiftJIS)
                ?? ""
            let uncompressedSize = Int(uncompressedSizeValue)
            entries.append(
                DEMZIPEntry(
                    name: name,
                    generalPurposeFlag: flag,
                    compressionMethod: method,
                    crc32: crc32,
                    compressedSize: Int(compressedSizeValue),
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: Int(localOffsetValue)
                )
            )
            pointer = nameEnd + extraLength + commentLength
            guard pointer <= centralEnd else {
                throw ElevationDEMError.invalidZIP
            }
        }
        return entries
    }

    private static func inflate(_ payload: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0, expectedSize <= maximumExpandedBytes else {
            throw ElevationDEMError.archiveTooLarge
        }
        if expectedSize == 0 { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let decodedCount: Int = payload.withUnsafeBytes { sourceBuffer in
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
        guard decodedCount == expectedSize else {
            throw ElevationDEMError.decompressionFailed
        }
        return Data(output)
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = crc32Table[index] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
