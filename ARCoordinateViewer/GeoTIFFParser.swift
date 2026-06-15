import Foundation
import UIKit
import ImageIO
import CoreGraphics

struct GeoTIFFParser {
    static let maxTextureDimension = 2048

    static func parse(data: Data, fileName: String, coordinateMode: GeoTIFFCoordinateMode) throws -> GeoRaster {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw GeoTIFFError.notImage
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw GeoTIFFError.invalidImageSize
        }

        let metadata = TIFFMetadata(data: data)
        let corners = try makeGeoCorners(metadata: metadata, imageWidth: sourceWidth, imageHeight: sourceHeight, coordinateMode: coordinateMode)

        let maxPixel = min(maxTextureDimension, max(sourceWidth, sourceHeight))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw GeoTIFFError.imageDecodeFailed
        }

        let renderedWidth = thumbnail.width
        let renderedHeight = thumbnail.height
        let image = UIImage(cgImage: thumbnail)
        let downsampleNote: String
        if sourceWidth != renderedWidth || sourceHeight != renderedHeight {
            downsampleNote = " / 画像縮小：\(sourceWidth)x\(sourceHeight)→\(renderedWidth)x\(renderedHeight)"
        } else {
            downsampleNote = ""
        }

        return GeoRaster(
            name: fileName,
            image: image,
            corners: corners,
            sourcePixelWidth: sourceWidth,
            sourcePixelHeight: sourceHeight,
            renderedPixelWidth: renderedWidth,
            renderedPixelHeight: renderedHeight,
            notes: "不透明度35%初期値 / 画素透過処理なし\(downsampleNote)"
        )
    }

    private static func makeGeoCorners(metadata: TIFFMetadata, imageWidth: Int, imageHeight: Int, coordinateMode: GeoTIFFCoordinateMode) throws -> [GeoCoordinate] {
        let pixelCorners = [
            (x: 0.0, y: 0.0),
            (x: Double(imageWidth), y: 0.0),
            (x: Double(imageWidth), y: Double(imageHeight)),
            (x: 0.0, y: Double(imageHeight))
        ]

        let modelCorners: [(x: Double, y: Double)]
        if let transform = metadata.modelTransformation, transform.count >= 16 {
            modelCorners = pixelCorners.map { pixel in
                let x = transform[0] * pixel.x + transform[1] * pixel.y + transform[3]
                let y = transform[4] * pixel.x + transform[5] * pixel.y + transform[7]
                return (x, y)
            }
        } else if let scale = metadata.modelPixelScale, scale.count >= 2,
                  let tiepoint = metadata.modelTiepoint, tiepoint.count >= 6 {
            let tiePixelX = tiepoint[0]
            let tiePixelY = tiepoint[1]
            let tieModelX = tiepoint[3]
            let tieModelY = tiepoint[4]
            let scaleX = scale[0]
            let scaleY = scale[1]
            modelCorners = pixelCorners.map { pixel in
                let x = tieModelX + (pixel.x - tiePixelX) * scaleX
                let y = tieModelY - (pixel.y - tiePixelY) * scaleY
                return (x, y)
            }
        } else {
            throw GeoTIFFError.missingGeoReference
        }

        // GeoTIFF内のEPSG情報は使わず、ユーザーが指定した座標系で解釈する。
        // これにより、EPSG未設定・誤設定のGeoTIFFでも読み込みやすくする。
        switch coordinateMode {
        case .geographic:
            return modelCorners.map { model in
                GeoCoordinate(name: nil, latitude: model.y, longitude: model.x, altitude: nil)
            }
        case .planeRectangular(let system):
            return try modelCorners.map { model in
                // GeoTIFFのモデル座標は通常 X=東方向、Y=北方向。
                // 日本の平面直角座標系変換関数は x=北方向、y=東方向で受ける。
                try JapanesePlaneRectangularSystem.toGeodetic(system: system, x: model.y, y: model.x)
            }
        }
    }

}

enum GeoTIFFError: LocalizedError {
    case notImage
    case invalidImageSize
    case imageDecodeFailed
    case missingGeoReference
    case unsupportedCoordinateSystem(String)
    case unsupportedTIFF

    var errorDescription: String? {
        switch self {
        case .notImage:
            return "画像として読み込めません。"
        case .invalidImageSize:
            return "画像サイズを取得できません。"
        case .imageDecodeFailed:
            return "GeoTIFF画像をデコードできません。"
        case .missingGeoReference:
            return "GeoTIFF内に位置情報タグを確認できません。"
        case .unsupportedCoordinateSystem(let text):
            return "未対応の座標系です：\(text)"
        case .unsupportedTIFF:
            return "このTIFF形式には未対応です。"
        }
    }
}

private struct TIFFMetadata {
    var modelPixelScale: [Double]?
    var modelTiepoint: [Double]?
    var modelTransformation: [Double]?
    var geoKeys: [UInt16: UInt16] = [:]
    var geographicType: UInt16? { geoKeys[2048] }
    var projectedType: UInt16? { geoKeys[3072] }

    init(data: Data) {
        guard data.count >= 8 else { return }
        let byteOrder = data.readUInt16(at: 0, endian: .little)
        let endian: TIFFEndian
        if byteOrder == 0x4949 {
            endian = .little
        } else if byteOrder == 0x4D4D {
            endian = .big
        } else {
            return
        }

        let magic = data.readUInt16(at: 2, endian: endian)
        guard magic == 42 else { return }
        let ifdOffset = Int(data.readUInt32(at: 4, endian: endian))
        guard ifdOffset > 0, ifdOffset + 2 <= data.count else { return }

        let entryCount = Int(data.readUInt16(at: ifdOffset, endian: endian))
        let entriesStart = ifdOffset + 2
        for index in 0..<entryCount {
            let offset = entriesStart + index * 12
            guard offset + 12 <= data.count else { continue }
            let tag = data.readUInt16(at: offset, endian: endian)
            let type = data.readUInt16(at: offset + 2, endian: endian)
            let count = Int(data.readUInt32(at: offset + 4, endian: endian))
            let valueOffset = data.readUInt32(at: offset + 8, endian: endian)
            guard let tagDataOffset = tagDataOffset(type: type, count: count, valueOffset: valueOffset, entryValueOffset: offset + 8) else { continue }

            switch tag {
            case 33550:
                modelPixelScale = data.readDoubleArray(type: type, count: count, at: tagDataOffset, endian: endian)
            case 33922:
                modelTiepoint = data.readDoubleArray(type: type, count: count, at: tagDataOffset, endian: endian)
            case 34264:
                modelTransformation = data.readDoubleArray(type: type, count: count, at: tagDataOffset, endian: endian)
            case 34735:
                parseGeoKeyDirectory(data.readUInt16Array(type: type, count: count, at: tagDataOffset, endian: endian))
            default:
                continue
            }
        }
    }

    var isGeographicCoordinateSystem: Bool {
        if let geographicType {
            return geographicType == 4326 || geographicType == 4612 || geographicType == 6668 || geographicType == 6697
        }
        return false
    }

    var japanesePlaneRectangularSystemNumber: Int? {
        guard let epsg = projectedType else { return nil }

        // JGD2011 / Japan Plane Rectangular CS I〜XIX: EPSG 6669〜6687
        if epsg >= 6669 && epsg <= 6687 { return Int(epsg - 6668) }

        // JGD2000 / Japan Plane Rectangular CS I〜XIX: EPSG 2443〜2461
        if epsg >= 2443 && epsg <= 2461 { return Int(epsg - 2442) }

        return nil
    }

    var coordinateSystemDescription: String {
        if let projectedType { return "Projected EPSG:\(projectedType)" }
        if let geographicType { return "Geographic EPSG:\(geographicType)" }
        return "EPSG不明"
    }

    private func tagDataOffset(type: UInt16, count: Int, valueOffset: UInt32, entryValueOffset: Int) -> Int? {
        let totalBytes = count * bytesPerValue(type)
        if totalBytes <= 4 {
            return entryValueOffset
        }
        let offset = Int(valueOffset)
        return offset >= 0 ? offset : nil
    }

    private func bytesPerValue(_ type: UInt16) -> Int {
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
            return 1
        }
    }

    private mutating func parseGeoKeyDirectory(_ values: [UInt16]) {
        guard values.count >= 4 else { return }
        let keyCount = Int(values[3])
        for i in 0..<keyCount {
            let base = 4 + i * 4
            guard base + 3 < values.count else { continue }
            let keyID = values[base]
            let tagLocation = values[base + 1]
            let count = values[base + 2]
            let valueOffset = values[base + 3]
            if tagLocation == 0, count == 1 {
                geoKeys[keyID] = valueOffset
            }
        }
    }
}

private enum TIFFEndian {
    case little
    case big
}

private extension Data {
    func readUInt16(at offset: Int, endian: TIFFEndian) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let value = self[offset..<offset + 2].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        switch endian {
        case .big:
            return value
        case .little:
            return value.byteSwapped
        }
    }

    func readUInt32(at offset: Int, endian: TIFFEndian) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let value = self[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        switch endian {
        case .big:
            return value
        case .little:
            return value.byteSwapped
        }
    }

    func readFloat64(at offset: Int, endian: TIFFEndian) -> Double {
        guard offset + 8 <= count else { return 0 }
        let bits = readUInt64(at: offset, endian: endian)
        return Double(bitPattern: bits)
    }

    func readFloat32(at offset: Int, endian: TIFFEndian) -> Float {
        guard offset + 4 <= count else { return 0 }
        let bits = readUInt32(at: offset, endian: endian)
        return Float(bitPattern: bits)
    }

    func readUInt64(at offset: Int, endian: TIFFEndian) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let value = self[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        switch endian {
        case .big:
            return value
        case .little:
            return value.byteSwapped
        }
    }

    func readDoubleArray(type: UInt16, count: Int, at offset: Int, endian: TIFFEndian) -> [Double] {
        guard count > 0 else { return [] }
        var result: [Double] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            switch type {
            case 12:
                let byteOffset = offset + i * 8
                guard byteOffset + 8 <= self.count else { return result }
                result.append(readFloat64(at: byteOffset, endian: endian))
            case 11:
                let byteOffset = offset + i * 4
                guard byteOffset + 4 <= self.count else { return result }
                result.append(Double(readFloat32(at: byteOffset, endian: endian)))
            default:
                return result
            }
        }
        return result
    }

    func readUInt16Array(type: UInt16, count: Int, at offset: Int, endian: TIFFEndian) -> [UInt16] {
        guard type == 3, count > 0 else { return [] }
        var result: [UInt16] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let byteOffset = offset + i * 2
            guard byteOffset + 2 <= self.count else { return result }
            result.append(readUInt16(at: byteOffset, endian: endian))
        }
        return result
    }
}
