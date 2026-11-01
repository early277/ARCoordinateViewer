import Foundation
import simd
import UIKit

struct GeoCoordinate: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String?
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    /// Original DXF Z in metres, including an explicit/implicit zero in a 2D file.
    var dxfAltitude: Double? = nil
    var altitudeWasEstimated: Bool? = nil
    var drawingSourceAltitude: Double? { dxfAltitude ?? (altitudeWasEstimated == true ? nil : altitude) }
    var planeSystem: Int? = nil
    var planeNorth: Double? = nil
    var planeEast: Double? = nil

    init(name: String? = nil, latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

struct DXFCoordinateReference: Codable, Hashable {
    var planeSystem = 9
    var metersPerUnit = 1.0
    var xIsEasting = true
    var insertionUnits: Int? = nil
}

enum PhotoCaptureMode:String,Codable,CaseIterable { case arOverlay, cameraOnly
    var title:String { self == .arOverlay ? "AR写真" : "写真のみ" }
}
enum PhotoPositionSource:String,Codable { case ar, deviceGPS }
enum SurveyDatum:String,Codable,CaseIterable { case unknown, wgs84, jgd2011, jgd2000
    var title:String { switch self { case .unknown:return "不明・任意座標";case .wgs84:return "WGS84";case .jgd2011:return "JGD2011";case .jgd2000:return "JGD2000" } }
}
enum SurveyHeightReference:String,Codable,CaseIterable { case unknown, seaLevel, ellipsoid, local
    var title:String { switch self { case .unknown:return "不明";case .seaLevel:return "海面基準の標高（T.P.等）";case .ellipsoid:return "楕円体高";case .local:return "任意の高さ" } }
}
struct PhotoReferenceSettings:Codable,Equatable {
    var datum:SurveyDatum = .unknown
    var heightReference:SurveyHeightReference = .unknown
}

enum DrawingExportHeightMode: String, Codable { case automatic, planar, referencePoint }
struct DrawingExportProfile: Codable, Equatable {
    var planeSystem = 0
    var metresPerUnit: Double?
    var xIsEasting: Bool?
    var insertionUnits: Int?
    var heightMode = DrawingExportHeightMode.automatic
    var anchorID: UUID?
    var anchorAltitude: Double?
    var reference: DXFCoordinateReference? {
        guard (1...19).contains(planeSystem), let metresPerUnit, metresPerUnit.isFinite,
              metresPerUnit > 0, let xIsEasting else { return nil }
        return DXFCoordinateReference(planeSystem:planeSystem,metersPerUnit:metresPerUnit,xIsEasting:xIsEasting,insertionUnits:insertionUnits)
    }
    init(reference: DXFCoordinateReference? = nil) {
        if let reference {
            planeSystem=reference.planeSystem; metresPerUnit=reference.metersPerUnit
            xIsEasting=reference.xIsEasting; insertionUnits=reference.insertionUnits
        }
    }
}

/// Source file RGBA, independent of display frameworks.
struct SourceColor: Hashable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static func rgb(_ value: Int) -> SourceColor {
        SourceColor(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255)
    }
    static func kml(_ text: String) -> SourceColor? {
        guard text.count == 8, let value = UInt32(text, radix:16) else { return nil }
        return SourceColor(red: Double(value & 255)/255, green: Double((value >> 8) & 255)/255,
                           blue: Double((value >> 16) & 255)/255, alpha: Double(value >> 24)/255)
    }
    static func aci(_ index: Int) -> SourceColor? {
        guard (1...255).contains(index) else { return nil }
        let basic = [0,0xff0000,0xffff00,0x00ff00,0x00ffff,0x0000ff,0xff00ff,0xffffff,0x808080,0xc0c0c0]
        if index < 10 { return rgb(basic[index]) }
        if index >= 250 { let v = [51,80,105,130,190,255][index-250]; return rgb(v*0x010101) }
        let hue = Double((index-10)/10)/4
        let value = [255.0,165,127,76,38][((index-10)%10)/2]
        let saturation = index % 2 == 0 ? 1.0 : 0.5
        let c = value*saturation, x = c*(1-abs(hue.truncatingRemainder(dividingBy:2)-1)), m = value-c
        let components: (Double,Double,Double)
        switch Int(hue) { case 0: components=(c,x,0); case 1: components=(x,c,0); case 2: components=(0,c,x); case 3: components=(0,x,c); case 4: components=(x,0,c); default: components=(c,0,x) }
        return SourceColor(red: floor(components.0+m)/255,green: floor(components.1+m)/255,blue: floor(components.2+m)/255)
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

struct GeoFeature: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var kind: GeometryKind
    var coordinates: [GeoCoordinate]
    var labelRole: GeoFeatureLabelRole
    var sourceLayer: String? = nil
    var sourceColor: SourceColor? = nil

    init(name: String, kind: GeometryKind, coordinates: [GeoCoordinate], labelRole: GeoFeatureLabelRole? = nil, sourceColor: SourceColor? = nil) {
        self.sourceColor = sourceColor
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
    /// 地形追従のために線を細分化した場合でも、柱は元の境界点だけへ立てる。
    /// nilの場合は従来どおり全positionsを使う。
    var pillarPositions: [SIMD3<Float>]? = nil
    var sourceColor: SourceColor? = nil
    /// Original drawing heights stay separate from flattened/clipped/DEM display Y.
    var sourceAltitudes: [Double?]? = nil
    var pillarSourceAltitudes: [Double?]? = nil
}

extension SourceColor {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
}

struct GeoRaster: Identifiable {
    var id = UUID()
    var name: String
    var image: UIImage
    /// top-left, top-right, bottom-right, bottom-left の順
    var corners: [GeoCoordinate]
    var sourcePixelWidth: Int
    var sourcePixelHeight: Int
    var renderedPixelWidth: Int
    var renderedPixelHeight: Int
    var notes: String
    var tileStore: RasterTileStore? = nil
}


struct ImportedDataLayer: Identifiable {
    var dxfReference: DXFCoordinateReference? = nil
    var documentID: UUID
    var id = UUID()
    var name: String
    var features: [GeoFeature]
    var points: [GeoCoordinate]
    var rasters: [GeoRaster]
    var elevationGrids: [ElevationGrid] = []
    var isVisible: Bool = true

    var pointCount: Int {
        points.count
    }

    let lineCount: Int
    let constantDXFAltitude: Double?

    init(name: String, features: [GeoFeature], points: [GeoCoordinate], rasters: [GeoRaster], elevationGrids: [ElevationGrid] = [], isVisible: Bool = true, dxfReference: DXFCoordinateReference? = nil, documentID: UUID = UUID()) {
        self.documentID = documentID
        self.dxfReference = dxfReference
        self.name = name; self.features = features; self.points = points; self.rasters = rasters
        self.elevationGrids = elevationGrids; self.isVisible = isVisible
        var constant: Double?
        if dxfReference != nil {
            heightScan: for feature in features { for coordinate in feature.coordinates {
                let height=coordinate.drawingSourceAltitude ?? 0
                guard height.isFinite else { constant=nil; break heightScan }
                if let first=constant, first != height { constant=nil; break heightScan }
                constant=height
            } }
        }
        constantDXFAltitude=constant
        lineCount = features.reduce(0) { sum, feature in
            sum + (feature.kind == .point ? 0 : max(0, feature.coordinates.count-1) + (feature.kind == .polygon ? 1 : 0))
        }
    }

    var rasterCount: Int {
        rasters.count
    }

    var elevationGridCount: Int {
        elevationGrids.count
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
    /// LiDAR深度判定による表示倍率。通常は1.0、現実物体の奥側では設定値まで下げる。
    var opacity: Double = 1.0
    /// Tree identity and measured diameter occupy two lines; other labels stay compact.
    var maximumLines: Int = 1
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
    var displayRadiusMeters: Double = 1000
    var labelDistanceMeters: Double = 150

    /// 点・線の個別設定を保ったまま、表示サイズを一括調整する倍率。
    var masterSizeScale: Double = 1.0
    /// 表示半径と点名表示距離を一括調整する倍率。
    var masterRangeScale: Double = 1.0

    var arPointSize: Double = 0.05
    var arSelectedSphereSize: Double = 0.12
    var arLineWidth: Double = 0.01

    var planPointSize: Double = 3
    var planLineWidth: Double = 1.5

    /// 近距離を小さく、遠距離を見失いにくい大きさへ自動調整する。
    var farMinimumSizeEnabled: Bool = true
    var farPointMinSize: Double = 0.10
    var farLineMinWidth: Double = 0.01

    /// 森林・草地でARKit方位だけがずれた場合、コンパスを補助基準に緩やかに補正する。
    var headingStabilizationEnabled: Bool = false
    var headingStabilizationExplicit: Bool? = nil

    /// LiDAR深度から、現実物体より奥側にあるAR要素を半透明にする。
    var lidarFadeBehindObjectsEnabled: Bool = true
    var lidarBehindOpacity: Double = 0.50
    var drawingDistanceMode: DrawingDistanceMode = .slope

    /// 取り込んだ標高を、現在地付近の標高を基準にした高さ差としてAR表示する。
    /// 標高0や欠損高度は軽量な近傍推定で補完する。
    var useRelativeAltitude: Bool = false
    /// 相対高さの暴走防止。0以下は制限なし。
    var relativeAltitudeLimitMeters: Double = 100

    /// 表示中のDEMから境界線の標高を補間し、地形に沿って描画する。
    var boundaryTerrainFollowEnabled: Bool = true
    /// 境界線上でDEMを再サンプリングする希望間隔。大量データ時は自動的に広げる。
    var demSampleSpacingMeters: Double = 5

    /// GeoTIFF全体の不透明度。1.0=不透明、0.0=透明。
    var rasterOpacity: Double = 0.35

    static let defaults = DisplaySettings()

    init() { }

    private enum CodingKeys: String, CodingKey {
        case showPoints
        case showLines
        case showLabels
        case maxDisplayPoints
        case maxDisplayLines
        case maxLabelCount
        case displayRadiusMeters
        case labelDistanceMeters
        case masterSizeScale
        case masterRangeScale
        case arPointSize
        case arSelectedSphereSize
        case arLineWidth
        case planPointSize
        case planLineWidth
        case farMinimumSizeEnabled
        case farPointMinSize
        case farLineMinWidth
        case headingStabilizationEnabled
        case headingStabilizationExplicit
        case lidarFadeBehindObjectsEnabled
        case lidarBehindOpacity
        case drawingDistanceMode
        case useRelativeAltitude
        case relativeAltitudeLimitMeters
        case boundaryTerrainFollowEnabled
        case demSampleSpacingMeters
        case rasterOpacity
    }

    /// 以前の版で保存した設定には新しいキーがないため、存在する値だけを復元する。
    /// 新設項目は上記の初期値を使い、アップデート時に設定全体が消えるのを防ぐ。
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showPoints = try container.decodeIfPresent(Bool.self, forKey: .showPoints) ?? showPoints
        showLines = try container.decodeIfPresent(Bool.self, forKey: .showLines) ?? showLines
        showLabels = try container.decodeIfPresent(Bool.self, forKey: .showLabels) ?? showLabels
        maxDisplayPoints = try container.decodeIfPresent(Int.self, forKey: .maxDisplayPoints) ?? maxDisplayPoints
        maxDisplayLines = try container.decodeIfPresent(Int.self, forKey: .maxDisplayLines) ?? maxDisplayLines
        maxLabelCount = try container.decodeIfPresent(Int.self, forKey: .maxLabelCount) ?? maxLabelCount
        displayRadiusMeters = try container.decodeIfPresent(Double.self, forKey: .displayRadiusMeters) ?? displayRadiusMeters
        labelDistanceMeters = try container.decodeIfPresent(Double.self, forKey: .labelDistanceMeters) ?? labelDistanceMeters
        masterSizeScale = try container.decodeIfPresent(Double.self, forKey: .masterSizeScale) ?? masterSizeScale
        masterRangeScale = try container.decodeIfPresent(Double.self, forKey: .masterRangeScale) ?? masterRangeScale
        arPointSize = try container.decodeIfPresent(Double.self, forKey: .arPointSize) ?? arPointSize
        arSelectedSphereSize = try container.decodeIfPresent(Double.self, forKey: .arSelectedSphereSize) ?? arSelectedSphereSize
        arLineWidth = try container.decodeIfPresent(Double.self, forKey: .arLineWidth) ?? arLineWidth
        planPointSize = try container.decodeIfPresent(Double.self, forKey: .planPointSize) ?? planPointSize
        planLineWidth = try container.decodeIfPresent(Double.self, forKey: .planLineWidth) ?? planLineWidth
        farMinimumSizeEnabled = try container.decodeIfPresent(Bool.self, forKey: .farMinimumSizeEnabled) ?? farMinimumSizeEnabled
        farPointMinSize = try container.decodeIfPresent(Double.self, forKey: .farPointMinSize) ?? farPointMinSize
        farLineMinWidth = try container.decodeIfPresent(Double.self, forKey: .farLineMinWidth) ?? farLineMinWidth
        headingStabilizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .headingStabilizationEnabled) ?? headingStabilizationEnabled
        headingStabilizationExplicit = try container.decodeIfPresent(Bool.self, forKey: .headingStabilizationExplicit)
        lidarFadeBehindObjectsEnabled = try container.decodeIfPresent(Bool.self, forKey: .lidarFadeBehindObjectsEnabled) ?? lidarFadeBehindObjectsEnabled
        lidarBehindOpacity = try container.decodeIfPresent(Double.self, forKey: .lidarBehindOpacity) ?? lidarBehindOpacity
        drawingDistanceMode = (try container.decodeIfPresent(String.self, forKey: .drawingDistanceMode))
            .flatMap(DrawingDistanceMode.init(rawValue:)) ?? .slope
        useRelativeAltitude = try container.decodeIfPresent(Bool.self, forKey: .useRelativeAltitude) ?? useRelativeAltitude
        relativeAltitudeLimitMeters = try container.decodeIfPresent(Double.self, forKey: .relativeAltitudeLimitMeters) ?? relativeAltitudeLimitMeters
        boundaryTerrainFollowEnabled = try container.decodeIfPresent(Bool.self, forKey: .boundaryTerrainFollowEnabled) ?? boundaryTerrainFollowEnabled
        demSampleSpacingMeters = try container.decodeIfPresent(Double.self, forKey: .demSampleSpacingMeters) ?? demSampleSpacingMeters
        rasterOpacity = try container.decodeIfPresent(Double.self, forKey: .rasterOpacity) ?? rasterOpacity
    }

    mutating func clamp() {
        maxDisplayPoints = Swift.max(0, Swift.min(maxDisplayPoints, 10000))
        maxDisplayLines = Swift.max(0, Swift.min(maxDisplayLines, 5000))
        maxLabelCount = Swift.max(0, Swift.min(maxLabelCount, 500))
        displayRadiusMeters = Swift.max(0, Swift.min(displayRadiusMeters, 10000))
        labelDistanceMeters = Swift.max(0, Swift.min(labelDistanceMeters, 10000))
        masterSizeScale = Swift.max(0.5, Swift.min(masterSizeScale, 3.0))
        masterRangeScale = Swift.max(0.5, Swift.min(masterRangeScale, 3.0))
        arPointSize = Swift.max(0.005, Swift.min(arPointSize, 2.0))
        arSelectedSphereSize = Swift.max(0.01, Swift.min(arSelectedSphereSize, 3.0))
        arLineWidth = Swift.max(0.001, Swift.min(arLineWidth, 1.0))
        planPointSize = Swift.max(2, Swift.min(planPointSize, 40))
        planLineWidth = Swift.max(0.5, Swift.min(planLineWidth, 12))
        farPointMinSize = Swift.max(0.005, Swift.min(farPointMinSize, 2.0))
        farLineMinWidth = Swift.max(0.001, Swift.min(farLineMinWidth, 1.0))
        relativeAltitudeLimitMeters = Swift.max(0, Swift.min(relativeAltitudeLimitMeters, 1000))
        demSampleSpacingMeters = Swift.max(1, Swift.min(demSampleSpacingMeters, 50))
        rasterOpacity = Swift.max(0.0, Swift.min(rasterOpacity, 1.0))
        lidarBehindOpacity = Swift.max(0.05, Swift.min(lidarBehindOpacity, 0.85))
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

    func effectivePointRadius(distance: Float, baseRadius: Float? = nil) -> Float {
        let base = baseRadius ?? pointRadius
        guard farMinimumSizeEnabled else { return base }

        let d = max(0, distance)
        if d < 5 {
            // 手元では固定サイズの45〜80%へ縮小し、点が視界を覆いすぎないようにする。
            return base * (0.45 + 0.35 * d / 5)
        }
        if d < 30 {
            // 中距離では元サイズへ滑らかに戻す。
            return base * (0.80 + 0.40 * (d - 5) / 25)
        }

        // 遠距離は距離に比例した最小値を設け、投影後に消えにくくする。
        let farScale = min(max(d / 30, 1), 4)
        return max(base * 1.20, farPointMinRadius * farScale)
    }

    func effectiveLineRadius(distance: Float) -> Float {
        guard farMinimumSizeEnabled else { return lineRadius }

        let d = max(0, distance)
        if d < 5 {
            return lineRadius * (0.50 + 0.30 * d / 5)
        }
        if d < 30 {
            return lineRadius * (0.80 + 0.35 * (d - 5) / 25)
        }

        let farScale = min(max(d / 30, 1), 3.5)
        return max(lineRadius * 1.15, farLineMinRadius * farScale)
    }
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
