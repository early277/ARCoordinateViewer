import Foundation
import simd
import UIKit

struct GeoCoordinate: Identifiable, Hashable {
    let id = UUID()
    var name: String?
    var latitude: Double
    var longitude: Double
    var altitude: Double?

    init(name: String? = nil, latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

enum GeometryKind: String, Codable {
    case point
    case line
    case polygon
}

enum GeoFeatureLabelRole: String, Codable, Hashable {
    case none
    case point
    case parcel
}

struct GeoFeature: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var kind: GeometryKind
    var coordinates: [GeoCoordinate]
    var labelRole: GeoFeatureLabelRole

    init(name: String, kind: GeometryKind, coordinates: [GeoCoordinate], labelRole: GeoFeatureLabelRole? = nil) {
        self.name = name
        self.kind = kind
        self.coordinates = coordinates
        self.labelRole = labelRole ?? (kind == .point ? .point : .none)
    }
}

struct RenderFeature: Identifiable, Hashable {
    let id: UUID
    var name: String
    var kind: GeometryKind
    var positions: [SIMD3<Float>]
    var labelRole: GeoFeatureLabelRole = .none
}

struct GeoRaster: Identifiable {
    let id = UUID()
    var name: String
    var image: UIImage
    /// top-left, top-right, bottom-right, bottom-left の順
    var corners: [GeoCoordinate]
    var sourcePixelWidth: Int
    var sourcePixelHeight: Int
    var renderedPixelWidth: Int
    var renderedPixelHeight: Int
    var notes: String
}


struct ImportedDataLayer: Identifiable {
    let id = UUID()
    var name: String
    var features: [GeoFeature]
    var points: [GeoCoordinate]
    var rasters: [GeoRaster]
    var isVisible: Bool = true

    var pointCount: Int {
        points.count
    }

    var lineCount: Int {
        features.reduce(0) { total, feature in
            switch feature.kind {
            case .point:
                return total
            case .line:
                return total + max(0, feature.coordinates.count - 1)
            case .polygon:
                return total + max(0, feature.coordinates.count)
            }
        }
    }

    var rasterCount: Int {
        rasters.count
    }
}

struct RenderRaster: Identifiable {
    let id: UUID
    var name: String
    var image: UIImage
    /// top-left, top-right, bottom-right, bottom-left の順。Yは0固定。
    var positions: [SIMD3<Float>]
    var notes: String
}

enum GeoTIFFCoordinateMode: Hashable {
    case geographic
    case planeRectangular(system: Int)

    var description: String {
        switch self {
        case .geographic:
            return "緯度経度"
        case .planeRectangular(let system):
            return "平面直角\(system)系"
        }
    }
}



enum CSVCoordinateKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case planeXY
    case latLon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .planeXY:
            return "平面直角座標 X/Y"
        case .latLon:
            return "緯度経度"
        }
    }
}

struct CSVColumnMapping: Hashable {
    var hasHeader: Bool
    var coordinateKind: CSVCoordinateKind
    var planeSystemNumber: Int
    var nameColumn: Int?
    var firstCoordinateColumn: Int
    var secondCoordinateColumn: Int
    var altitudeColumn: Int?
}

struct CSVPreviewData: Hashable {
    var rows: [[String]]
    var hasHeader: Bool
    var headers: [String]
    var columnCount: Int
}

struct ScreenLabel: Identifiable, Hashable {
    let id: UUID
    var text: String
    var x: CGFloat
    var y: CGFloat
    var distance: Float
    var labelRole: GeoFeatureLabelRole = .point
    var isSelected: Bool = false
    /// 2D画面上でラベルを上へずらす量。点名は球体と重ならないよう上にずらし、
    /// 画地名は高さ方向の見え方が逆に見えないよう、原則として投影位置そのままにする。
    var screenYOffset: CGFloat = 20
}

struct RenderLabel: Identifiable, Hashable {
    let id: UUID
    var text: String
    var position: SIMD3<Float>
    var distance: Float
    var labelRole: GeoFeatureLabelRole = .point
    var isSelected: Bool = false
    /// 2D画面上でラベルを上へずらす量。
    var screenYOffset: CGFloat = 20
}

struct ManualOriginInput {
    var latitudeText: String = ""
    var longitudeText: String = ""
}

struct PlaneCoordinateInput {
    var systemNumber: Int = 9
    var xText: String = ""
    var yText: String = ""
}

struct DisplaySettings: Codable, Equatable {
    var showPoints: Bool = true
    var showLines: Bool = true
    var showLabels: Bool = true

    var maxDisplayPoints: Int = 500
    var maxDisplayLines: Int = 300
    var maxLabelCount: Int = 30

    /// 0以下は距離制限なし
    var displayRadiusMeters: Double = 0
    var labelDistanceMeters: Double = 150

    var arPointSize: Double = 0.036
    var arSelectedSphereSize: Double = 0.068
    var arLineWidth: Double = 0.01

    var planPointSize: Double = 7
    var planLineWidth: Double = 2

    var farMinimumSizeEnabled: Bool = true
    var farPointMinSize: Double = 0.096
    var farLineMinWidth: Double = 0.008

    /// 取り込んだ標高を、現在地付近の標高を基準にした高さ差としてAR表示する。
    /// 標高0や欠損高度は軽量な近傍推定で補完する。
    var useRelativeAltitude: Bool = false
    /// 相対高さの暴走防止。0以下は制限なし。
    var relativeAltitudeLimitMeters: Double = 100

    /// GeoTIFF全体の不透明度。1.0=不透明、0.0=透明。
    var rasterOpacity: Double = 0.35

    static let defaults = DisplaySettings()

    mutating func clamp() {
        maxDisplayPoints = Swift.max(0, Swift.min(maxDisplayPoints, 10000))
        maxDisplayLines = Swift.max(0, Swift.min(maxDisplayLines, 5000))
        maxLabelCount = Swift.max(0, Swift.min(maxLabelCount, 500))
        displayRadiusMeters = Swift.max(0, Swift.min(displayRadiusMeters, 10000))
        labelDistanceMeters = Swift.max(0, Swift.min(labelDistanceMeters, 10000))
        arPointSize = Swift.max(0.03, Swift.min(arPointSize, 2.0))
        arSelectedSphereSize = Swift.max(0.05, Swift.min(arSelectedSphereSize, 3.0))
        arLineWidth = Swift.max(0.005, Swift.min(arLineWidth, 1.0))
        planPointSize = Swift.max(2, Swift.min(planPointSize, 40))
        planLineWidth = Swift.max(0.5, Swift.min(planLineWidth, 12))
        farPointMinSize = Swift.max(0.02, Swift.min(farPointMinSize, 2.0))
        farLineMinWidth = Swift.max(0.005, Swift.min(farLineMinWidth, 1.0))
        relativeAltitudeLimitMeters = Swift.max(0, Swift.min(relativeAltitudeLimitMeters, 1000))
        rasterOpacity = Swift.max(0.0, Swift.min(rasterOpacity, 1.0))
    }
}

struct RenderStyle: Hashable {
    var pointRadius: Float
    var selectedPointRadius: Float
    var lineRadius: Float
    var farMinimumSizeEnabled: Bool
    var farPointMinRadius: Float
    var farLineMinRadius: Float
    var rasterOpacity: Float
}

struct PlanDrawableFeature: Identifiable, Hashable {
    let id: UUID
    var name: String
    var kind: GeometryKind
    var coordinates: [GeoCoordinate]
}

struct DisplayLimitResult {
    var features: [GeoFeature]
    /// 画地名ラベル用の代表点。線分表示用に分割したFeatureではなく、元の面要素から作る。
    var parcelLabelFeatures: [GeoFeature]
    var message: String
    var pointCount: Int
    var lineCount: Int
    var totalPointCount: Int
    var totalLineCount: Int
}
