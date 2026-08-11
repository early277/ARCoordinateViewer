import Foundation
import Compression

enum ElevationGeoTIFFError: LocalizedError {
    case invalidTIFF
    case bigTIFFUnsupported
    case missingTag(String)
    case unsupported(String)
    case invalidDimensions
    case tooManyCells(Int)
    case invalidBlock
    case decompressionFailed(String)
    case missingGeoReference
    case invalidTransform
    case noValidElevation

    var errorDescription: String? {
        switch self {
        case .invalidTIFF:
            return "標高GeoTIFFの構造を解析できません。"
        case .bigTIFFUnsupported:
            return "BigTIFFには未対応です。通常のGeoTIFFとして書き出してください。"
        case .missingTag(let tag):
            return "標高GeoTIFFに必要なタグがありません：\(tag)"
        case .unsupported(let detail):
            return "未対応の標高GeoTIFF形式です：\(detail)"
        case .invalidDimensions:
            return "標高GeoTIFFの画像サイズが不正です。"
        case .tooManyCells(let count):
            return "標高GeoTIFFが大きすぎます（\(count)セル）。範囲を分けてください。"
        case .invalidBlock:
            return "標高GeoTIFFのストリップ／タイル情報が不正です。"
        case .decompressionFailed(let detail):
            return "標高GeoTIFFの展開に失敗しました：\(detail)"
        case .missingGeoReference:
            return "標高GeoTIFFに位置情報タグがありません。"
        case .invalidTransform:
            return "標高GeoTIFFの座標変換情報が不正です。"
        case .noValidElevation:
            return "標高GeoTIFF内に有効な標高値がありません。"
        }
    }
}

enum ElevationGeoTIFFParser {
    private static let maximumCells = 8_000_000

    static func parse(
        data: Data,
        fileName: String,
        coordinateMode: GeoTIFFCoordinateMode
    ) throws -> ElevationGrid {
        let reader = try ClassicElevationTIFFReader(data: data, maximumCells: maximumCells)
        return try reader.makeElevationGrid(fileName: fileName, coordinateMode: coordinateMode)
    }
}

private enum ElevationTIFFEndian {
    case little
    case big
}

private struct ElevationTIFFEntry {
    var type: UInt16
    var count: Int
    var dataOffset: Int
}

private struct ClassicElevationTIFFReader {
    private static let maximumBlockCount = 100_000
    private static let maximumDecodedBlockBytes = 64 * 1_024 * 1_024
    private let data: Data
    private let endian: ElevationTIFFEndian
    private let entries: [UInt16: ElevationTIFFEntry]
    private let maximumCells: Int

    init(data: Data, maximumCells: Int) throws {
        guard data.count >= 8 else { throw ElevationGeoTIFFError.invalidTIFF }
        let byteOrder = data.elevationReadUInt16(at: 0, endian: .little)
        let parsedEndian: ElevationTIFFEndian
        if byteOrder == 0x4949 {
            parsedEndian = .little
        } else if byteOrder == 0x4d4d {
            parsedEndian = .big
        } else {
            throw ElevationGeoTIFFError.invalidTIFF
        }

        let magic = data.elevationReadUInt16(at: 2, endian: parsedEndian)
        if magic == 43 { throw ElevationGeoTIFFError.bigTIFFUnsupported }
        guard magic == 42 else { throw ElevationGeoTIFFError.invalidTIFF }

        let ifdOffset = Int(data.elevationReadUInt32(at: 4, endian: parsedEndian))
        guard ifdOffset > 0, ifdOffset + 2 <= data.count else {
            throw ElevationGeoTIFFError.invalidTIFF
        }
        let entryCount = Int(data.elevationReadUInt16(at: ifdOffset, endian: parsedEndian))
        guard entryCount > 0, entryCount <= 4_096 else {
            throw ElevationGeoTIFFError.invalidTIFF
        }

        var parsed: [UInt16: ElevationTIFFEntry] = [:]
        let entriesStart = ifdOffset + 2
        for index in 0..<entryCount {
            let offset = entriesStart + index * 12
            guard offset + 12 <= data.count else {
                throw ElevationGeoTIFFError.invalidTIFF
            }
            let tag = data.elevationReadUInt16(at: offset, endian: parsedEndian)
            let type = data.elevationReadUInt16(at: offset + 2, endian: parsedEndian)
            let count = Int(data.elevationReadUInt32(at: offset + 4, endian: parsedEndian))
            let bytesPerValue = Self.bytesPerValue(type)
            guard count >= 0,
                  bytesPerValue > 0,
                  count <= Int.max / bytesPerValue else { continue }
            let byteCount = count * bytesPerValue
            let dataOffset: Int
            if byteCount <= 4 {
                dataOffset = offset + 8
            } else {
                dataOffset = Int(data.elevationReadUInt32(at: offset + 8, endian: parsedEndian))
            }
            guard dataOffset >= 0,
                  dataOffset <= data.count,
                  byteCount <= data.count - dataOffset else { continue }
            parsed[tag] = ElevationTIFFEntry(type: type, count: count, dataOffset: dataOffset)
        }
        self.data = data
        self.endian = parsedEndian
        self.entries = parsed
        self.maximumCells = maximumCells
    }

    func makeElevationGrid(
        fileName: String,
        coordinateMode: GeoTIFFCoordinateMode
    ) throws -> ElevationGrid {
        guard let width = unsignedValues(tag: 256).first.map(Int.init) else {
            throw ElevationGeoTIFFError.missingTag("ImageWidth")
        }
        guard let height = unsignedValues(tag: 257).first.map(Int.init) else {
            throw ElevationGeoTIFFError.missingTag("ImageLength")
        }
        let multiplication = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !multiplication.overflow else {
            throw ElevationGeoTIFFError.invalidDimensions
        }
        let cellCount = multiplication.partialValue
        guard cellCount <= maximumCells else {
            throw ElevationGeoTIFFError.tooManyCells(cellCount)
        }

        let bitsPerSample = Int(unsignedValues(tag: 258).first ?? 0)
        guard [8, 16, 32, 64].contains(bitsPerSample) else {
            throw ElevationGeoTIFFError.unsupported("BitsPerSample=\(bitsPerSample)")
        }
        let bytesPerSample = bitsPerSample / 8
        let samplesPerPixel = Int(unsignedValues(tag: 277).first ?? 1)
        guard samplesPerPixel == 1 else {
            throw ElevationGeoTIFFError.unsupported("単一バンドのみ対応（SamplesPerPixel=\(samplesPerPixel)）")
        }
        let planarConfiguration = Int(unsignedValues(tag: 284).first ?? 1)
        guard planarConfiguration == 1 else {
            throw ElevationGeoTIFFError.unsupported("PlanarConfiguration=\(planarConfiguration)")
        }
        let orientation = Int(unsignedValues(tag: 274).first ?? 1)
        guard orientation == 1 else {
            throw ElevationGeoTIFFError.unsupported("Orientation=\(orientation)")
        }

        let sampleFormat = Int(unsignedValues(tag: 339).first ?? 1)
        guard [1, 2, 3].contains(sampleFormat) else {
            throw ElevationGeoTIFFError.unsupported("SampleFormat=\(sampleFormat)")
        }
        if sampleFormat == 3, bitsPerSample != 32, bitsPerSample != 64 {
            throw ElevationGeoTIFFError.unsupported("浮動小数点は32bitまたは64bitのみ対応")
        }

        let compression = Int(unsignedValues(tag: 259).first ?? 1)
        guard [1, 5, 8, 32_946, 32_773].contains(compression) else {
            throw ElevationGeoTIFFError.unsupported("Compression=\(compression)")
        }
        let predictor = Int(unsignedValues(tag: 317).first ?? 1)
        guard predictor == 1 || predictor == 2 else {
            throw ElevationGeoTIFFError.unsupported(
                "Predictor=\(predictor)。書出時に予測圧縮を「なし」にしてください"
            )
        }
        if predictor == 2, sampleFormat == 3 {
            throw ElevationGeoTIFFError.unsupported(
                "浮動小数点Predictor=2。書出時に予測圧縮を「なし」にしてください"
            )
        }

        let noDataValue = asciiValue(tag: 42_113)
            .flatMap { text -> Double? in
                let trimmed = text.trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
                )
                if trimmed.lowercased() == "nan" { return .nan }
                return Double(trimmed)
            }

        var values = [Float](repeating: .nan, count: cellCount)
        if entries[324] != nil || entries[325] != nil {
            try decodeTiles(
                width: width,
                height: height,
                bytesPerSample: bytesPerSample,
                bitsPerSample: bitsPerSample,
                sampleFormat: sampleFormat,
                compression: compression,
                predictor: predictor,
                noDataValue: noDataValue,
                into: &values
            )
        } else {
            try decodeStrips(
                width: width,
                height: height,
                bytesPerSample: bytesPerSample,
                bitsPerSample: bitsPerSample,
                sampleFormat: sampleFormat,
                compression: compression,
                predictor: predictor,
                noDataValue: noDataValue,
                into: &values
            )
        }
        guard values.contains(where: { $0.isFinite }) else {
            throw ElevationGeoTIFFError.noValidElevation
        }

        let rasterType = geoKeyValue(1_025) ?? 1
        let pixelIsArea = rasterType != 2
        let modelTransform = try makeSampleCenterTransform(pixelIsArea: pixelIsArea)
        let reference: ElevationCoordinateReference
        switch coordinateMode {
        case .geographic:
            reference = .geographic
        case .planeRectangular(let system):
            reference = .planeRectangular(system: system)
        }

        let outerGridCorners: [(column: Double, row: Double)] = [
            (-0.5, -0.5),
            (Double(width) - 0.5, -0.5),
            (Double(width) - 0.5, Double(height) - 0.5),
            (-0.5, Double(height) - 0.5)
        ]
        let geographicCorners = try outerGridCorners.map { grid -> GeoCoordinate in
            let model = modelTransform.modelCoordinate(column: grid.column, row: grid.row)
            return try geographicCoordinate(
                modelX: model.x,
                modelY: model.y,
                coordinateMode: coordinateMode
            )
        }
        guard geographicCorners.allSatisfy({
            $0.latitude.isFinite
                && $0.longitude.isFinite
                && (-90.0...90.0).contains($0.latitude)
                && (-180.0...180.0).contains($0.longitude)
        }) else {
            throw ElevationGeoTIFFError.invalidTransform
        }

        // 平面直角座標の広いラスターでは投影上の辺が緯度経度で曲がるため、
        // 四隅だけでなく外周も標本化して包含範囲を求める。
        var geographicFootprint = geographicCorners
        for index in 0...16 {
            let fraction = Double(index) / 16.0
            let column = -0.5 + Double(width) * fraction
            let row = -0.5 + Double(height) * fraction
            let edgeSamples: [(column: Double, row: Double)] = [
                (column, -0.5),
                (column, Double(height) - 0.5),
                (-0.5, row),
                (Double(width) - 0.5, row)
            ]
            for sample in edgeSamples {
                let model = modelTransform.modelCoordinate(
                    column: sample.column,
                    row: sample.row
                )
                let geographic = try geographicCoordinate(
                    modelX: model.x,
                    modelY: model.y,
                    coordinateMode: coordinateMode
                )
                guard geographic.latitude.isFinite,
                      geographic.longitude.isFinite,
                      (-90.0...90.0).contains(geographic.latitude),
                      (-180.0...180.0).contains(geographic.longitude) else {
                    throw ElevationGeoTIFFError.invalidTransform
                }
                geographicFootprint.append(geographic)
            }
        }

        let centerColumn = max(0, min(width - 1, width / 2))
        let centerRow = max(0, min(height - 1, height / 2))
        let centerModel = modelTransform.modelCoordinate(
            column: Double(centerColumn),
            row: Double(centerRow)
        )
        let columnNeighborModel = modelTransform.modelCoordinate(
            column: Double(min(width - 1, centerColumn + 1)),
            row: Double(centerRow)
        )
        let rowNeighborModel = modelTransform.modelCoordinate(
            column: Double(centerColumn),
            row: Double(min(height - 1, centerRow + 1))
        )
        let centerGeo = try geographicCoordinate(
            modelX: centerModel.x,
            modelY: centerModel.y,
            coordinateMode: coordinateMode
        )
        let columnNeighborGeo = try geographicCoordinate(
            modelX: columnNeighborModel.x,
            modelY: columnNeighborModel.y,
            coordinateMode: coordinateMode
        )
        let rowNeighborGeo = try geographicCoordinate(
            modelX: rowNeighborModel.x,
            modelY: rowNeighborModel.y,
            coordinateMode: coordinateMode
        )
        let columnMeters = CoordinateConverter.enuMeters(from: columnNeighborGeo, origin: centerGeo)
        let rowMeters = CoordinateConverter.enuMeters(from: rowNeighborGeo, origin: centerGeo)
        let candidateCellSizes = [
            hypot(columnMeters.east, columnMeters.north),
            hypot(rowMeters.east, rowMeters.north)
        ].filter { $0.isFinite && $0 > 0.001 }
        let estimatedCellSize = candidateCellSizes.min() ?? 1

        let minimumLatitude = geographicFootprint.map(\.latitude).min()!
        let maximumLatitude = geographicFootprint.map(\.latitude).max()!
        let minimumLongitude = geographicFootprint.map(\.longitude).min()!
        let maximumLongitude = geographicFootprint.map(\.longitude).max()!
        let rangeText: String
        var minimumElevation = Float.greatestFiniteMagnitude
        var maximumElevation = -Float.greatestFiniteMagnitude
        for value in values where value.isFinite {
            minimumElevation = min(minimumElevation, value)
            maximumElevation = max(maximumElevation, value)
        }
        if minimumElevation.isFinite, maximumElevation.isFinite {
            rangeText = String(
                format: " / 標高%.2f〜%.2fm",
                Double(minimumElevation),
                Double(maximumElevation)
            )
        } else {
            rangeText = ""
        }

        return ElevationGrid(
            name: fileName,
            width: width,
            height: height,
            elevations: values,
            transform: modelTransform,
            coordinateReference: reference,
            minimumLatitude: minimumLatitude,
            maximumLatitude: maximumLatitude,
            minimumLongitude: minimumLongitude,
            maximumLongitude: maximumLongitude,
            estimatedCellSizeMeters: estimatedCellSize,
            sourceDescription: "標高GeoTIFF / \(coordinateMode.description) / \(width)x\(height)\(rangeText)"
        )
    }

    private func decodeStrips(
        width: Int,
        height: Int,
        bytesPerSample: Int,
        bitsPerSample: Int,
        sampleFormat: Int,
        compression: Int,
        predictor: Int,
        noDataValue: Double?,
        into values: inout [Float]
    ) throws {
        guard let offsetEntry = entries[273],
              let byteCountEntry = entries[279],
              offsetEntry.count > 0,
              offsetEntry.count <= Self.maximumBlockCount,
              byteCountEntry.count == offsetEntry.count else {
            throw ElevationGeoTIFFError.invalidBlock
        }
        let offsets = unsignedValues(tag: 273).map(Int.init)
        let byteCounts = unsignedValues(tag: 279).map(Int.init)
        guard !offsets.isEmpty, offsets.count == byteCounts.count else {
            throw ElevationGeoTIFFError.missingTag("StripOffsets / StripByteCounts")
        }
        let rowsPerStrip = Int(unsignedValues(tag: 278).first ?? UInt64(height))
        guard rowsPerStrip > 0 else { throw ElevationGeoTIFFError.invalidBlock }
        let expectedStripCount = (height + rowsPerStrip - 1) / rowsPerStrip
        guard expectedStripCount <= Self.maximumBlockCount,
              offsets.count >= expectedStripCount else {
            throw ElevationGeoTIFFError.invalidBlock
        }

        for stripIndex in 0..<expectedStripCount {
            let firstRow = stripIndex * rowsPerStrip
            let rowCount = min(rowsPerStrip, height - firstRow)
            let expectedBytes = try checkedByteCount(
                width: width,
                height: rowCount,
                bytesPerSample: bytesPerSample
            )
            var block = try decodeBlock(
                offset: offsets[stripIndex],
                byteCount: byteCounts[stripIndex],
                expectedBytes: expectedBytes,
                compression: compression
            )
            try undoHorizontalPredictor(
                &block,
                width: width,
                rowCount: rowCount,
                bitsPerSample: bitsPerSample,
                predictor: predictor
            )
            writeSamples(
                block,
                blockWidth: width,
                validWidth: width,
                validHeight: rowCount,
                destinationColumn: 0,
                destinationRow: firstRow,
                destinationWidth: width,
                bitsPerSample: bitsPerSample,
                sampleFormat: sampleFormat,
                noDataValue: noDataValue,
                into: &values
            )
        }
    }

    private func decodeTiles(
        width: Int,
        height: Int,
        bytesPerSample: Int,
        bitsPerSample: Int,
        sampleFormat: Int,
        compression: Int,
        predictor: Int,
        noDataValue: Double?,
        into values: inout [Float]
    ) throws {
        guard let tileWidth = unsignedValues(tag: 322).first.map(Int.init),
              let tileHeight = unsignedValues(tag: 323).first.map(Int.init),
              tileWidth > 0,
              tileHeight > 0 else {
            throw ElevationGeoTIFFError.missingTag("TileWidth / TileLength")
        }
        let tilesAcross = (width + tileWidth - 1) / tileWidth
        let tilesDown = (height + tileHeight - 1) / tileHeight
        let tileCount = tilesAcross * tilesDown
        guard tileCount <= Self.maximumBlockCount,
              let offsetEntry = entries[324],
              let byteCountEntry = entries[325],
              offsetEntry.count >= tileCount,
              offsetEntry.count <= Self.maximumBlockCount,
              byteCountEntry.count == offsetEntry.count else {
            throw ElevationGeoTIFFError.invalidBlock
        }
        let offsets = unsignedValues(tag: 324).map(Int.init)
        let byteCounts = unsignedValues(tag: 325).map(Int.init)
        guard offsets.count >= tileCount,
              byteCounts.count >= tileCount else {
            throw ElevationGeoTIFFError.invalidBlock
        }
        let expectedBytes = try checkedByteCount(
            width: tileWidth,
            height: tileHeight,
            bytesPerSample: bytesPerSample
        )

        for tileIndex in 0..<tileCount {
            let tileX = tileIndex % tilesAcross
            let tileY = tileIndex / tilesAcross
            var block = try decodeBlock(
                offset: offsets[tileIndex],
                byteCount: byteCounts[tileIndex],
                expectedBytes: expectedBytes,
                compression: compression
            )
            try undoHorizontalPredictor(
                &block,
                width: tileWidth,
                rowCount: tileHeight,
                bitsPerSample: bitsPerSample,
                predictor: predictor
            )
            let destinationColumn = tileX * tileWidth
            let destinationRow = tileY * tileHeight
            let validWidth = min(tileWidth, width - destinationColumn)
            let validHeight = min(tileHeight, height - destinationRow)
            writeSamples(
                block,
                blockWidth: tileWidth,
                validWidth: validWidth,
                validHeight: validHeight,
                destinationColumn: destinationColumn,
                destinationRow: destinationRow,
                destinationWidth: width,
                bitsPerSample: bitsPerSample,
                sampleFormat: sampleFormat,
                noDataValue: noDataValue,
                into: &values
            )
        }
    }

    private func checkedByteCount(width: Int, height: Int, bytesPerSample: Int) throws -> Int {
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow,
              pixels.partialValue <= maximumCells else {
            throw ElevationGeoTIFFError.invalidBlock
        }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: bytesPerSample)
        guard !bytes.overflow,
              bytes.partialValue >= 0,
              bytes.partialValue <= Self.maximumDecodedBlockBytes else {
            throw ElevationGeoTIFFError.invalidBlock
        }
        return bytes.partialValue
    }

    private func decodeBlock(
        offset: Int,
        byteCount: Int,
        expectedBytes: Int,
        compression: Int
    ) throws -> [UInt8] {
        guard offset >= 0,
              byteCount >= 0,
              offset <= data.count,
              byteCount <= data.count - offset else {
            throw ElevationGeoTIFFError.invalidBlock
        }
        let payload = Data(data[offset..<(offset + byteCount)])
        let decoded: [UInt8]
        switch compression {
        case 1:
            decoded = Array(payload)
        case 5:
            decoded = try decodeLZW(payload, expectedBytes: expectedBytes)
        case 8:
            decoded = try decodeDeflate(payload, expectedBytes: expectedBytes)
        case 32_946:
            decoded = try decodeDeflate(payload, expectedBytes: expectedBytes)
        case 32_773:
            decoded = try decodePackBits(payload, expectedBytes: expectedBytes)
        default:
            throw ElevationGeoTIFFError.unsupported("Compression=\(compression)")
        }
        guard decoded.count == expectedBytes else {
            throw ElevationGeoTIFFError.decompressionFailed(
                "展開サイズ\(decoded.count)、必要サイズ\(expectedBytes)"
            )
        }
        return decoded
    }

    private func decodeDeflate(
        _ payload: Data,
        expectedBytes: Int
    ) throws -> [UInt8] {
        var candidates: [(data: Data, expectedAdler32: UInt32?)] = []
        let hasZlibHeader = payload.count > 6
            && payload[0] & 0x0f == 8
            && payload[0] >> 4 <= 7
            && (Int(payload[0]) * 256 + Int(payload[1])) % 31 == 0
        if hasZlibHeader, payload[1] & 0x20 == 0 {
            let start = 2
            let end = payload.count - 4
            if start < end {
                let expectedAdler32 = (UInt32(payload[end]) << 24)
                    | (UInt32(payload[end + 1]) << 16)
                    | (UInt32(payload[end + 2]) << 8)
                    | (UInt32(payload[end + 3]))
                candidates.append(
                    (Data(payload[start..<end]), expectedAdler32)
                )
            }
        }
        // 古いDeflateタグや非標準書出しではraw DEFLATEの場合がある。
        candidates.append((payload, nil))

        for candidate in candidates {
            guard expectedBytes < Int.max else {
                throw ElevationGeoTIFFError.decompressionFailed("Deflate展開サイズ")
            }
            // 1byte余分な出力領域を設け、宣言サイズを超えるストリームを拒否する。
            var output = [UInt8](repeating: 0, count: expectedBytes + 1)
            let decodedCount: Int = candidate.data.withUnsafeBytes { sourceBuffer in
                guard let sourceBase = sourceBuffer.baseAddress else { return 0 }
                return output.withUnsafeMutableBytes { destinationBuffer in
                    guard let destinationBase = destinationBuffer.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        destinationBase.assumingMemoryBound(to: UInt8.self),
                        expectedBytes + 1,
                        sourceBase.assumingMemoryBound(to: UInt8.self),
                        candidate.data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decodedCount == expectedBytes else { continue }
            output.removeLast()
            if let expectedAdler32 = candidate.expectedAdler32,
               expectedAdler32 != adler32(output) {
                continue
            }
            return output
        }
        throw ElevationGeoTIFFError.decompressionFailed("Deflate")
    }

    private func adler32(_ bytes: [UInt8]) -> UInt32 {
        let modulus: UInt32 = 65_521
        var first: UInt32 = 1
        var second: UInt32 = 0
        var offset = 0
        // zlibと同じNMAXで区切り、剰余演算を毎byte行わない。
        while offset < bytes.count {
            let end = min(bytes.count, offset + 5_552)
            for index in offset..<end {
                first += UInt32(bytes[index])
                second += first
            }
            first %= modulus
            second %= modulus
            offset = end
        }
        return (second << 16) | first
    }

    private func decodePackBits(_ payload: Data, expectedBytes: Int) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(expectedBytes)
        var cursor = 0
        while cursor < payload.count, output.count < expectedBytes {
            let header = Int(Int8(bitPattern: payload[cursor]))
            cursor += 1
            if header >= 0 {
                let count = header + 1
                guard cursor + count <= payload.count else {
                    throw ElevationGeoTIFFError.decompressionFailed("PackBits")
                }
                output.append(contentsOf: payload[cursor..<(cursor + count)])
                cursor += count
            } else if header >= -127 {
                let count = 1 - header
                guard cursor < payload.count else {
                    throw ElevationGeoTIFFError.decompressionFailed("PackBits")
                }
                output.append(contentsOf: repeatElement(payload[cursor], count: count))
                cursor += 1
            }
        }
        guard output.count == expectedBytes else {
            throw ElevationGeoTIFFError.decompressionFailed("PackBits")
        }
        return output
    }

    private func decodeLZW(_ payload: Data, expectedBytes: Int) throws -> [UInt8] {
        struct BitReader {
            let bytes: [UInt8]
            var bitOffset = 0

            mutating func read(_ bitCount: Int) -> Int? {
                guard bitCount > 0, bitOffset + bitCount <= bytes.count * 8 else { return nil }
                var value = 0
                for _ in 0..<bitCount {
                    let byteIndex = bitOffset / 8
                    let bitIndex = 7 - bitOffset % 8
                    value = (value << 1) | Int((bytes[byteIndex] >> bitIndex) & 1)
                    bitOffset += 1
                }
                return value
            }
        }

        let clearCode = 256
        let endCode = 257
        var reader = BitReader(bytes: Array(payload))
        var dictionary = [[UInt8]?](repeating: nil, count: 4_096)
        func resetDictionary(_ dictionary: inout [[UInt8]?]) {
            for index in 0..<256 { dictionary[index] = [UInt8(index)] }
            for index in 256..<dictionary.count { dictionary[index] = nil }
        }
        resetDictionary(&dictionary)

        var codeWidth = 9
        var nextCode = 258
        var previous: [UInt8]?
        var output: [UInt8] = []
        output.reserveCapacity(expectedBytes)

        while let code = reader.read(codeWidth) {
            if code == clearCode {
                resetDictionary(&dictionary)
                codeWidth = 9
                nextCode = 258
                previous = nil
                continue
            }
            if code == endCode { break }

            let entry: [UInt8]
            if code < nextCode, let value = dictionary[code] {
                entry = value
            } else if code == nextCode, let previous, let first = previous.first {
                entry = previous + [first]
            } else {
                throw ElevationGeoTIFFError.decompressionFailed("LZWコード")
            }
            output.append(contentsOf: entry)
            if output.count > expectedBytes {
                throw ElevationGeoTIFFError.decompressionFailed("LZW展開量")
            }

            if let previous, let first = entry.first, nextCode < 4_096 {
                dictionary[nextCode] = previous + [first]
                nextCode += 1
                // TIFF LZWはEarlyChange=1。
                if nextCode == (1 << codeWidth) - 1, codeWidth < 12 {
                    codeWidth += 1
                }
            }
            previous = entry
        }
        guard output.count == expectedBytes else {
            throw ElevationGeoTIFFError.decompressionFailed("LZW")
        }
        return output
    }

    private func undoHorizontalPredictor(
        _ bytes: inout [UInt8],
        width: Int,
        rowCount: Int,
        bitsPerSample: Int,
        predictor: Int
    ) throws {
        guard predictor == 2 else { return }
        let bytesPerSample = bitsPerSample / 8
        let rowByteCount = width * bytesPerSample
        guard rowByteCount > 0, bytes.count >= rowByteCount * rowCount else {
            throw ElevationGeoTIFFError.invalidBlock
        }
        let mask: UInt64 = bitsPerSample == 64
            ? UInt64.max
            : (UInt64(1) << UInt64(bitsPerSample)) - 1

        for row in 0..<rowCount {
            let rowStart = row * rowByteCount
            for column in 1..<width {
                let offset = rowStart + column * bytesPerSample
                let previousOffset = offset - bytesPerSample
                let current = readUnsignedSample(bytes, offset: offset, bits: bitsPerSample)
                let previous = readUnsignedSample(bytes, offset: previousOffset, bits: bitsPerSample)
                writeUnsignedSample(
                    (current &+ previous) & mask,
                    into: &bytes,
                    offset: offset,
                    bits: bitsPerSample
                )
            }
        }
    }

    private func writeSamples(
        _ bytes: [UInt8],
        blockWidth: Int,
        validWidth: Int,
        validHeight: Int,
        destinationColumn: Int,
        destinationRow: Int,
        destinationWidth: Int,
        bitsPerSample: Int,
        sampleFormat: Int,
        noDataValue: Double?,
        into values: inout [Float]
    ) {
        let bytesPerSample = bitsPerSample / 8
        for row in 0..<validHeight {
            for column in 0..<validWidth {
                let sourceOffset = (row * blockWidth + column) * bytesPerSample
                let rawValue = numericSample(
                    bytes,
                    offset: sourceOffset,
                    bits: bitsPerSample,
                    sampleFormat: sampleFormat
                )
                let destinationIndex = (destinationRow + row) * destinationWidth
                    + destinationColumn + column
                guard rawValue.isFinite,
                      rawValue >= -12_000,
                      rawValue <= 20_000,
                      !matchesNoData(rawValue, noDataValue: noDataValue) else {
                    values[destinationIndex] = .nan
                    continue
                }
                values[destinationIndex] = Float(rawValue)
            }
        }
    }

    private func matchesNoData(_ value: Double, noDataValue: Double?) -> Bool {
        guard let noDataValue else { return false }
        if noDataValue.isNaN { return value.isNaN }
        let tolerance = max(1.0e-9, abs(noDataValue) * 1.0e-7)
        return abs(value - noDataValue) <= tolerance
    }

    private func numericSample(
        _ bytes: [UInt8],
        offset: Int,
        bits: Int,
        sampleFormat: Int
    ) -> Double {
        let unsigned = readUnsignedSample(bytes, offset: offset, bits: bits)
        switch sampleFormat {
        case 1:
            return Double(unsigned)
        case 2:
            switch bits {
            case 8:
                return Double(Int8(bitPattern: UInt8(unsigned)))
            case 16:
                return Double(Int16(bitPattern: UInt16(unsigned)))
            case 32:
                return Double(Int32(bitPattern: UInt32(unsigned)))
            case 64:
                return Double(Int64(bitPattern: unsigned))
            default:
                return .nan
            }
        case 3:
            if bits == 32 {
                return Double(Float(bitPattern: UInt32(unsigned)))
            }
            if bits == 64 {
                return Double(bitPattern: unsigned)
            }
            return .nan
        default:
            return .nan
        }
    }

    private func readUnsignedSample(_ bytes: [UInt8], offset: Int, bits: Int) -> UInt64 {
        let byteCount = bits / 8
        guard offset >= 0, offset + byteCount <= bytes.count else { return 0 }
        var value: UInt64 = 0
        switch endian {
        case .little:
            for index in 0..<byteCount {
                value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
            }
        case .big:
            for index in 0..<byteCount {
                value = (value << 8) | UInt64(bytes[offset + index])
            }
        }
        return value
    }

    private func writeUnsignedSample(
        _ value: UInt64,
        into bytes: inout [UInt8],
        offset: Int,
        bits: Int
    ) {
        let byteCount = bits / 8
        guard offset >= 0, offset + byteCount <= bytes.count else { return }
        switch endian {
        case .little:
            for index in 0..<byteCount {
                bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
            }
        case .big:
            for index in 0..<byteCount {
                let shift = UInt64((byteCount - index - 1) * 8)
                bytes[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
            }
        }
    }

    private func makeSampleCenterTransform(pixelIsArea: Bool) throws -> ElevationGridTransform {
        let centerOffset = pixelIsArea ? 0.5 : 0.0
        if let matrix = doubleValues(tag: 34_264), matrix.count >= 16 {
            let columnX = matrix[0]
            let rowX = matrix[1]
            let columnY = matrix[4]
            let rowY = matrix[5]
            let originX = matrix[3] + (columnX + rowX) * centerOffset
            let originY = matrix[7] + (columnY + rowY) * centerOffset
            let transform = ElevationGridTransform(
                originX: originX,
                originY: originY,
                columnX: columnX,
                columnY: columnY,
                rowX: rowX,
                rowY: rowY
            )
            guard transform.gridCoordinate(modelX: originX, modelY: originY) != nil else {
                throw ElevationGeoTIFFError.invalidTransform
            }
            return transform
        }

        guard let scale = doubleValues(tag: 33_550), scale.count >= 2,
              let tiepoint = doubleValues(tag: 33_922), tiepoint.count >= 6 else {
            throw ElevationGeoTIFFError.missingGeoReference
        }
        let columnX = scale[0]
        let rowY = -scale[1]
        guard columnX.isFinite,
              rowY.isFinite,
              abs(columnX) > 0,
              abs(rowY) > 0 else {
            throw ElevationGeoTIFFError.invalidTransform
        }
        let cornerOriginX = tiepoint[3] - tiepoint[0] * columnX
        let cornerOriginY = tiepoint[4] - tiepoint[1] * rowY
        return ElevationGridTransform(
            originX: cornerOriginX + columnX * centerOffset,
            originY: cornerOriginY + rowY * centerOffset,
            columnX: columnX,
            columnY: 0,
            rowX: 0,
            rowY: rowY
        )
    }

    private func geographicCoordinate(
        modelX: Double,
        modelY: Double,
        coordinateMode: GeoTIFFCoordinateMode
    ) throws -> GeoCoordinate {
        switch coordinateMode {
        case .geographic:
            return GeoCoordinate(latitude: modelY, longitude: modelX)
        case .planeRectangular(let system):
            // GeoTIFFモデル座標X=東、Y=北。平面直角はX=北、Y=東。
            return try JapanesePlaneRectangularSystem.toGeodetic(
                system: system,
                x: modelY,
                y: modelX
            )
        }
    }

    private func geoKeyValue(_ keyID: UInt16) -> UInt16? {
        guard entries[34_735]?.type == 3 else { return nil }
        let rawValues = unsignedValues(tag: 34_735)
        let values = rawValues.compactMap { UInt16(exactly: $0) }
        guard values.count == rawValues.count else { return nil }
        guard values.count >= 4 else { return nil }
        let keyCount = Int(values[3])
        for index in 0..<keyCount {
            let base = 4 + index * 4
            guard base + 3 < values.count else { break }
            if values[base] == keyID,
               values[base + 1] == 0,
               values[base + 2] == 1 {
                return values[base + 3]
            }
        }
        return nil
    }

    private func unsignedValues(tag: UInt16) -> [UInt64] {
        guard let entry = entries[tag],
              entry.count > 0,
              entry.count <= Self.maximumBlockCount else { return [] }
        var output: [UInt64] = []
        output.reserveCapacity(entry.count)
        for index in 0..<entry.count {
            let offset: Int
            switch entry.type {
            case 1, 2, 6, 7:
                offset = entry.dataOffset + index
                guard offset < data.count else { break }
                output.append(UInt64(data[offset]))
            case 3:
                offset = entry.dataOffset + index * 2
                guard offset + 2 <= data.count else { break }
                output.append(UInt64(data.elevationReadUInt16(at: offset, endian: endian)))
            case 4:
                offset = entry.dataOffset + index * 4
                guard offset + 4 <= data.count else { break }
                output.append(UInt64(data.elevationReadUInt32(at: offset, endian: endian)))
            default:
                return []
            }
        }
        return output
    }

    private func doubleValues(tag: UInt16) -> [Double]? {
        guard let entry = entries[tag],
              entry.count > 0,
              entry.count <= 64 else { return nil }
        var output: [Double] = []
        output.reserveCapacity(entry.count)
        for index in 0..<entry.count {
            switch entry.type {
            case 11:
                let offset = entry.dataOffset + index * 4
                guard offset + 4 <= data.count else { return nil }
                output.append(
                    Double(Float(bitPattern: data.elevationReadUInt32(at: offset, endian: endian)))
                )
            case 12:
                let offset = entry.dataOffset + index * 8
                guard offset + 8 <= data.count else { return nil }
                output.append(
                    Double(bitPattern: data.elevationReadUInt64(at: offset, endian: endian))
                )
            default:
                return nil
            }
        }
        return output
    }

    private func asciiValue(tag: UInt16) -> String? {
        guard let entry = entries[tag],
              entry.type == 2,
              entry.count > 0,
              entry.count <= 1_024 else { return nil }
        let end = min(data.count, entry.dataOffset + entry.count)
        guard entry.dataOffset < end else { return nil }
        return String(data: data[entry.dataOffset..<end], encoding: .ascii)
    }

    private static func bytesPerValue(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7:
            return 1
        case 3, 8:
            return 2
        case 4, 9, 11:
            return 4
        case 5, 10, 12:
            return 8
        default:
            return 0
        }
    }
}

private extension Data {
    func elevationReadUInt16(at offset: Int, endian: ElevationTIFFEndian) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        switch endian {
        case .little:
            return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
        case .big:
            return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
        }
    }

    func elevationReadUInt32(at offset: Int, endian: ElevationTIFFEndian) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        switch endian {
        case .little:
            return UInt32(self[offset])
                | (UInt32(self[offset + 1]) << 8)
                | (UInt32(self[offset + 2]) << 16)
                | (UInt32(self[offset + 3]) << 24)
        case .big:
            return (UInt32(self[offset]) << 24)
                | (UInt32(self[offset + 1]) << 16)
                | (UInt32(self[offset + 2]) << 8)
                | (UInt32(self[offset + 3]))
        }
    }

    func elevationReadUInt64(at offset: Int, endian: ElevationTIFFEndian) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        switch endian {
        case .little:
            for index in 0..<8 {
                value |= UInt64(self[offset + index]) << UInt64(index * 8)
            }
        case .big:
            for index in 0..<8 {
                value = (value << 8) | UInt64(self[offset + index])
            }
        }
        return value
    }
}
