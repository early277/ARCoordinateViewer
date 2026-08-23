import Foundation
import CoreLocation
import simd

/// AR写真の撮影処理をUIへ伝える状態。
/// 要求IDは `photoCaptureRequestID` で別に管理し、古い非同期コールバックが
/// 新しい撮影要求の状態を上書きしないようにする。
enum PhotoCaptureState: Equatable {
    case idle
    case capturing
    case saving
    case success
    case failure(String)

    var isBusy: Bool {
        switch self {
        case .capturing, .saving:
            return true
        case .idle, .success, .failure:
            return false
        }
    }
}

/// 画面上の右方向・正面方向を、ARワールドの東西・南北へ変換する水平基底。
/// ドラッグ開始時にスナップショットを取り、操作中に端末が少し動いても軸を固定する。
struct HorizontalScreenBasis: Equatable, Sendable {
    var rightEast: Double
    var rightNorth: Double
    var forwardEast: Double
    var forwardNorth: Double
}

@MainActor
final class AppModel: ObservableObject {
    static let defaultDisplayPlaneOffsetMeters = -1.0

    @Published var layers: [ImportedDataLayer] = []
    @Published var features: [GeoFeature] = []
    @Published var importedPointList: [GeoCoordinate] = []
    @Published var origin: GeoCoordinate?
    @Published var selectedPoint: GeoCoordinate?
    @Published var headingOffsetDegrees: Double = 0
    /// 最後に中心を確定してからの一時的な高さ調整値。
    /// 実際の描画高さは `effectiveDisplayPlaneOffsetMeters` を使用する。
    @Published var displayPlaneOffsetMeters: Double = AppModel.defaultDisplayPlaneOffsetMeters
    @Published var planePanEastMeters: Double = 0
    @Published var planePanNorthMeters: Double = 0
    @Published var pillarsEnabled: Bool = false
    @Published var rastersEnabled: Bool = true
    @Published var distancesEnabled: Bool = false
    @Published var lidarEnabled: Bool = false
    @Published var lidarSupported: Bool = false
    @Published var arCameraActive: Bool = true
    @Published var screenLabels: [ScreenLabel] = []
    @Published private(set) var automaticHeadingCorrectionDegrees: Double = 0
    @Published var photoCaptureRequestID: Int = 0
    @Published private(set) var photoCaptureState: PhotoCaptureState = .idle
    @Published private(set) var photoCaptureMessage: String?
    @Published var rasters: [GeoRaster] = []
    @Published var elevationGrids: [ElevationGrid] = []
    @Published var statusMessage: String = "KML / KMZ / CSV / SIMA / GeoTIFF / DEMを読み込んでください。"
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress: Double?
    @Published private(set) var importProgressMessage = ""
    @Published private(set) var importNotice: String?
    @Published var arStatusMessage: String = "AR準備中"
    @Published var planeSystemNumber: Int = 9
    @Published var settings: DisplaySettings = DisplaySettings.defaults {
        didSet {
            var clamped = settings
            clamped.clamp()
            if clamped != settings {
                settings = clamped
                return
            }
            saveSettings()
        }
    }

    /// 初期状態では高さを使わない。設定で標高差表示に切り替える。
    let ignoreAltitudeInAR = false

    var displayHeadingOffsetDegrees: Double {
        Self.normalizedDegrees(headingOffsetDegrees)
    }

    static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360.0)
        if value > 180.0 { value -= 360.0 }
        if value <= -180.0 { value += 360.0 }
        return value
    }
    private let maxRasterCount = 1
    private let settingsKey = "ARCoordinateViewer.DisplaySettings.v37"
    private struct ParsedImportResult {
        var name: String
        var features: [GeoFeature]
        var points: [GeoCoordinate]
        var rasters: [GeoRaster]
        var elevationGrids: [ElevationGrid]
        var statusMessage: String
        var planeSystemNumber: Int?
        var enableRasters: Bool
    }
    private var displayLimitCacheSignature: String = ""
    private var displayLimitCache: DisplayLimitResult?
    private var renderCacheSignature: String = ""
    private var renderFeaturesCache: [RenderFeature] = []
    private var renderLabelsCache: [RenderLabel] = []
    private var selectedRenderPositionCache: SIMD3<Float>?
    private var altitudeCacheSignature: String = ""
    private struct AltitudeReference {
        var coord: GeoCoordinate
        var altitude: Double
        var east: Double
        var north: Double
    }

    private struct AltitudeGridKey: Hashable {
        var x: Int
        var y: Int
    }

    private struct RenderedTransformSnapshot {
        var panEastMeters: Double
        var panNorthMeters: Double
        var rootHeightMeters: Double
        var totalHeadingDegrees: Double
    }

    private let altitudeGridCellSizeMeters: Double = 25
    private let altitudeNearestSearchMaxRings: Int = 8
    private let altitudeExactSearchLimit: Int = 2000
    private var altitudeReferenceCache: [AltitudeReference] = []
    private var altitudeGridOrigin: GeoCoordinate?
    private var altitudeGrid: [AltitudeGridKey: [Int]] = [:]
    private var altitudeBaselineCache: Double?
    private var importOperationID = 0
    private var activePhotoCaptureRequestID: Int?
    private var hasPendingPhotoCaptureRequest = false
    private var photoCaptureTimeoutTask: Task<Void, Never>?
    private var photoCaptureFeedbackTask: Task<Void, Never>?
    private var horizontalScreenBasis: HorizontalScreenBasis?
    private var renderedTransformSnapshot: RenderedTransformSnapshot?
    /// 中心更新で確定済みの垂直表示オフセット。
    /// 地理座標のoriginは高度を持たないため、既存のDEM／相対標高とは分離して管理する。
    private var committedVerticalDisplayOffsetMeters: Double = 0
    
    init() {
        settings = Self.loadSettings(key: settingsKey)
    }

    @discardableResult
    private func beginImportProgress(_ message: String) -> Int {
        importOperationID &+= 1
        isImporting = true
        importProgress = nil
        importProgressMessage = message
        importNotice = nil
        statusMessage = message
        return importOperationID
    }

    func dismissImportNotice() {
        importNotice = nil
    }

    private func showImportNotice(_ message: String) {
        importNotice = message
    }

    private func updateImportProgress(
        _ progress: Double?,
        message: String,
        operationID: Int
    ) {
        guard operationID == importOperationID else { return }
        if let progress, progress.isFinite {
            importProgress = max(0, min(1, progress))
        } else {
            importProgress = nil
        }
        importProgressMessage = message
    }

    private func finishImportProgress(operationID: Int) {
        guard operationID == importOperationID else { return }
        isImporting = false
        importProgress = nil
        importProgressMessage = ""
    }

    func importFile(url: URL) {
        importFileAsync(url: url)
    }

    func importFileAsync(url: URL) {
        let fileName = url.lastPathComponent
        let planeSystem = planeSystemNumber
        let ext = url.pathExtension.lowercased()
        let targetRegion: DEMImportRegion?
        if ext == "xml" || ext == "zip" {
            guard let region = currentDEMImportRegion() else {
                let message = "DEMを読み込む前に、先に点・線などの対象データを読み込んでください。\n対象データの範囲に絞ってDEMを読み込みます。"
                statusMessage = message
                showImportNotice(message)
                return
            }
            targetRegion = region
        } else {
            targetRegion = nil
        }
        let operationID = beginImportProgress("読込中：\(fileName)")

        DispatchQueue.global(qos: .userInitiated).async {
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                let result: ParsedImportResult

                Task { @MainActor [weak self] in
                    self?.updateImportProgress(
                        nil,
                        message: "\(fileName)を解析中…",
                        operationID: operationID
                    )
                }

                if ext == "xml" {
                    let grid = try GSIElevationDEMParser.parseXML(data: data, fileName: fileName)
                    result = ParsedImportResult(
                        name: fileName,
                        features: [],
                        points: [],
                        rasters: [],
                        elevationGrids: [grid],
                        statusMessage: Self.elevationImportStatus(
                            fileName: fileName,
                            grids: [grid]
                        ),
                        planeSystemNumber: nil,
                        enableRasters: false
                    )
                } else if ext == "zip" {
                    let grids = try GSIElevationDEMParser.parseZIP(
                        data: data,
                        fileName: fileName,
                        targetRegion: targetRegion,
                        progress: { [weak self] progress, message in
                            Task { @MainActor [weak self] in
                                self?.updateImportProgress(
                                    progress,
                                    message: message,
                                    operationID: operationID
                                )
                            }
                        }
                    )
                    result = ParsedImportResult(
                        name: fileName,
                        features: [],
                        points: [],
                        rasters: [],
                        elevationGrids: grids,
                        statusMessage: Self.elevationImportStatus(
                            fileName: fileName,
                            grids: grids
                        ),
                        planeSystemNumber: nil,
                        enableRasters: false
                    )
                } else if ext == "kml" {
                    let parsed = try KMLParser.parse(data: data)
                    result = ParsedImportResult(
                        name: fileName,
                        features: parsed,
                        points: Self.pointsForVectorFeaturesStatic(parsed),
                        rasters: [],
                        elevationGrids: [],
                        statusMessage: "KML読込：\(fileName) / \(parsed.count)件",
                        planeSystemNumber: nil,
                        enableRasters: false
                    )
                } else if ext == "kmz" {
                    let kmlData = try KMZParser.extractKMLData(from: data)
                    let parsed = try KMLParser.parse(data: kmlData)
                    result = ParsedImportResult(
                        name: fileName,
                        features: parsed,
                        points: Self.pointsForVectorFeaturesStatic(parsed),
                        rasters: [],
                        elevationGrids: [],
                        statusMessage: "KMZ読込：\(fileName) / \(parsed.count)件",
                        planeSystemNumber: nil,
                        enableRasters: false
                    )
                } else if ext == "tif" || ext == "tiff" {
                    let raster = try GeoTIFFParser.parse(data: data, fileName: fileName, coordinateMode: .planeRectangular(system: planeSystem))
                    result = ParsedImportResult(
                        name: fileName,
                        features: [],
                        points: [],
                        rasters: [raster],
                        elevationGrids: [],
                        statusMessage: "GeoTIFF読込：\(raster.renderedPixelWidth)x\(raster.renderedPixelHeight) / \(raster.notes)",
                        planeSystemNumber: nil,
                        enableRasters: true
                    )
                } else {
                    let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .shiftJIS)
                        ?? ""
                    if ext == "sim" || ext == "sima" || SIMAParser.looksLikeSIMA(text) {
                        let parseResult = try SIMAParser.parse(text: text, defaultPlaneSystem: planeSystem)
                        result = ParsedImportResult(
                            name: fileName,
                            features: parseResult.features,
                            points: parseResult.points,
                            rasters: [],
                            elevationGrids: [],
                            statusMessage: "SIMA読込：\(fileName) / 座標\(parseResult.points.count)点 / 画地\(parseResult.parcelCount)件",
                            planeSystemNumber: nil,
                            enableRasters: false
                        )
                    } else {
                        let parseResult = try CSVParser.parse(text: text, defaultPlaneSystem: planeSystem)
                        result = ParsedImportResult(
                            name: fileName,
                            features: parseResult.features,
                            points: parseResult.points,
                            rasters: [],
                            elevationGrids: [],
                            statusMessage: "CSV読込：\(fileName) / \(parseResult.points.count)点",
                            planeSystemNumber: nil,
                            enableRasters: false
                        )
                    }
                }

                Task { @MainActor in
                    self.applyParsedImport(result)
                    self.finishImportProgress(operationID: operationID)
                }
            } catch {
                Task { @MainActor in
                    let message = "読込エラー：\(error.localizedDescription)"
                    self.statusMessage = message
                    self.showImportNotice(message)
                    self.finishImportProgress(operationID: operationID)
                }
            }
        }
    }

    private func applyParsedImport(_ result: ParsedImportResult) {
        if let system = result.planeSystemNumber {
            planeSystemNumber = system
        }
        if result.enableRasters {
            rastersEnabled = true
        }
        if !result.elevationGrids.isEmpty {
            settings.useRelativeAltitude = true
            settings.boundaryTerrainFollowEnabled = true
        }
        addLayer(
            name: result.name,
            features: result.features,
            points: result.points,
            rasters: result.rasters,
            elevationGrids: result.elevationGrids
        )
        statusMessage = result.statusMessage
    }

    private func pointsForVectorFeatures(_ parsed: [GeoFeature]) -> [GeoCoordinate] {
        Self.pointsForVectorFeaturesStatic(parsed)
    }

    nonisolated private static func pointsForVectorFeaturesStatic(_ parsed: [GeoFeature]) -> [GeoCoordinate] {
        parsed.flatMap { feature in
            feature.coordinates.enumerated().map { index, coord in
                GeoCoordinate(
                    name: coord.name ?? (feature.coordinates.count == 1 ? feature.name : "\(feature.name)_\(index + 1)"),
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    altitude: coord.altitude
                )
            }
        }
    }

    private func addLayer(
        name: String,
        features: [GeoFeature],
        points: [GeoCoordinate],
        rasters: [GeoRaster],
        elevationGrids: [ElevationGrid] = []
    ) {
        let normalized = normalizeAltitudesAtImport(features: features, points: points)
        layers.append(
            ImportedDataLayer(
                name: name,
                features: normalized.features,
                points: normalized.points,
                rasters: rasters,
                elevationGrids: elevationGrids,
                isVisible: true
            )
        )
        selectedPoint = nil
        rebuildVisibleData()
    }

    /// 表示中の点・線・画地を含むDEM読込対象範囲を作る。
    /// 1m DEMタイルの端部にあるデータと、線の地形追従用サンプルを取りこぼさないよう、
    /// 外周へ100mの余裕を加える。
    private func currentDEMImportRegion() -> DEMImportRegion? {
        let coordinates = features.flatMap { $0.coordinates } + importedPointList
        let validCoordinates = coordinates.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
        }
        guard let first = validCoordinates.first else { return nil }

        var minimumLatitude = first.latitude
        var maximumLatitude = first.latitude
        var minimumLongitude = first.longitude
        var maximumLongitude = first.longitude
        for coordinate in validCoordinates.dropFirst() {
            minimumLatitude = min(minimumLatitude, coordinate.latitude)
            maximumLatitude = max(maximumLatitude, coordinate.latitude)
            minimumLongitude = min(minimumLongitude, coordinate.longitude)
            maximumLongitude = max(maximumLongitude, coordinate.longitude)
        }
        return DEMImportRegion(
            minimumLatitude: minimumLatitude,
            maximumLatitude: maximumLatitude,
            minimumLongitude: minimumLongitude,
            maximumLongitude: maximumLongitude
        ).expanded(by: 100)
    }

    /// 高さ補完はAR表示中に行わず、読み込み時に一度だけ行う。
    /// 標高0または標高なしの座標には、同一ファイル内で近い有効標高を概略補完する。
    /// 補完後の高さは1m単位に丸める。
    private func normalizeAltitudesAtImport(features: [GeoFeature], points: [GeoCoordinate]) -> (features: [GeoFeature], points: [GeoCoordinate]) {
        let allCoordinates = features.flatMap { $0.coordinates } + points
        let validPairs: [(coord: GeoCoordinate, altitude: Double)] = allCoordinates.compactMap { coord in
            guard let altitude = validAltitudeValue(coord.altitude) else { return nil }
            return (coord: coord, altitude: altitude.rounded())
        }

        guard let gridOrigin = validPairs.first?.coord else {
            return (features, points)
        }

        let references: [AltitudeReference] = validPairs.map { pair in
            let meters = CoordinateConverter.enuMeters(from: pair.coord, origin: gridOrigin)
            return AltitudeReference(coord: pair.coord, altitude: pair.altitude, east: meters.east, north: meters.north)
        }

        var grid: [AltitudeGridKey: [Int]] = [:]
        for (index, reference) in references.enumerated() {
            let key = altitudeGridKey(east: reference.east, north: reference.north)
            grid[key, default: []].append(index)
        }

        func nearestAltitude(to coord: GeoCoordinate) -> Double {
            if let altitude = validAltitudeValue(coord.altitude) {
                return altitude.rounded()
            }

            let target = CoordinateConverter.enuMeters(from: coord, origin: gridOrigin)
            let centerKey = altitudeGridKey(east: target.east, north: target.north)
            var bestAltitude: Double?
            var bestDistance = Double.greatestFiniteMagnitude

            for ring in 0...altitudeNearestSearchMaxRings {
                var foundInRing = false
                for x in (centerKey.x - ring)...(centerKey.x + ring) {
                    for y in (centerKey.y - ring)...(centerKey.y + ring) {
                        if ring > 0 && x > centerKey.x - ring && x < centerKey.x + ring && y > centerKey.y - ring && y < centerKey.y + ring {
                            continue
                        }
                        guard let indices = grid[AltitudeGridKey(x: x, y: y)] else { continue }
                        foundInRing = true
                        for index in indices {
                            let reference = references[index]
                            let distance = hypot(reference.east - target.east, reference.north - target.north)
                            if distance < bestDistance {
                                bestDistance = distance
                                bestAltitude = reference.altitude
                            }
                        }
                    }
                }
                if foundInRing, bestAltitude != nil { break }
            }

            // 近傍に有効標高がない場合もAR表示中の再探索は行わない。
            // 概略表示なので、同一ファイル内の最初の有効標高をフォールバックにする。
            return (bestAltitude ?? references.first?.altitude ?? 0).rounded()
        }

        func normalizedCoordinate(_ coord: GeoCoordinate) -> GeoCoordinate {
            var output = coord
            output.altitude = nearestAltitude(to: coord)
            return output
        }

        let normalizedFeatures = features.map { feature in
            GeoFeature(
                name: feature.name,
                kind: feature.kind,
                coordinates: feature.coordinates.map(normalizedCoordinate),
                labelRole: feature.labelRole
            )
        }
        let normalizedPoints = points.map(normalizedCoordinate)
        return (normalizedFeatures, normalizedPoints)
    }

    func setLayerVisible(_ layerID: UUID, isVisible: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        layers[index].isVisible = isVisible
        rebuildVisibleData()
        statusMessage = isVisible ? "レイヤー表示：\(layers[index].name)" : "レイヤー非表示：\(layers[index].name)"
    }

    func deleteLayer(_ layerID: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        let name = layers[index].name
        layers.remove(at: index)
        selectedPoint = nil
        rebuildVisibleData()
        statusMessage = "レイヤー削除：\(name)"
    }

    func showAllLayers() {
        for index in layers.indices { layers[index].isVisible = true }
        rebuildVisibleData()
        statusMessage = "全レイヤー表示"
    }

    func hideAllLayers() {
        for index in layers.indices { layers[index].isVisible = false }
        selectedPoint = nil
        rebuildVisibleData()
        statusMessage = "全レイヤー非表示"
    }

    private func rebuildVisibleData() {
        let visible = layers.filter { $0.isVisible }
        features = visible.flatMap { $0.features }
        importedPointList = visible.flatMap { $0.points }
        rasters = visible.flatMap { $0.rasters }
        let visibleElevationGrids = visible
            .reversed()
            .flatMap { $0.elevationGrids }
        elevationGrids = visibleElevationGrids
            .enumerated()
            .sorted {
                if $0.element.estimatedCellSizeMeters != $1.element.estimatedCellSizeMeters {
                    return $0.element.estimatedCellSizeMeters < $1.element.estimatedCellSizeMeters
                }
                return $0.offset < $1.offset
            }
            .map { $0.element }
        invalidateDisplayCaches()
    }

    private func invalidateDisplayCaches() {
        displayLimitCacheSignature = ""
        displayLimitCache = nil
        renderCacheSignature = ""
        renderFeaturesCache = []
        renderLabelsCache = []
        selectedRenderPositionCache = nil
        altitudeCacheSignature = ""
        altitudeReferenceCache = []
        altitudeGridOrigin = nil
        altitudeGrid = [:]
        altitudeBaselineCache = nil
    }

    func setOriginFromLocation(_ location: CLLocation) {
        setOriginAndResetPlanePan(
            GeoCoordinate(
                name: "iOS現在地",
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: nil
            )
        )
        statusMessage = "現在地を更新：\(location.coordinate.latitude.formatted(.number.precision(.fractionLength(7)))), \(location.coordinate.longitude.formatted(.number.precision(.fractionLength(7))))"
    }

    /// 現在位置をユーザー操作・GPSで明示的に更新した場合、
    /// 旧原点に対する位置合わせを新原点へ持ち越さない。
    private func setOriginAndResetPlanePan(_ nextOrigin: GeoCoordinate) {
        origin = nextOrigin
        resetPlanePan()
        resetDisplayHeight()
    }

    func resetPlanePan() {
        planePanEastMeters = 0
        planePanNorthMeters = 0
        renderedTransformSnapshot = nil
    }

    /// RealityKitのrootへ渡す、確定済み基準を含む実効表示高さ。
    var effectiveDisplayPlaneOffsetMeters: Double {
        committedVerticalDisplayOffsetMeters + displayPlaneOffsetMeters
    }

    func setEffectiveDisplayPlaneOffsetMeters(_ meters: Double) {
        guard meters.isFinite else { return }
        let clamped = min(100.0, max(-100.0, meters))
        displayPlaneOffsetMeters = clamped - committedVerticalDisplayOffsetMeters
    }

    func resetDisplayHeight() {
        committedVerticalDisplayOffsetMeters = 0
        displayPlaneOffsetMeters = Self.defaultDisplayPlaneOffsetMeters
        renderedTransformSnapshot = nil
    }

    func setOrigin(latitude: Double, longitude: Double) {
        setOriginAndResetPlanePan(GeoCoordinate(name: "手入力", latitude: latitude, longitude: longitude, altitude: nil))
        statusMessage = "現在地を手入力で設定"
    }

    func setOriginFromPlane(system: Int, x: Double, y: Double) {
        do {
            let geo = try JapanesePlaneRectangularSystem.toGeodetic(system: system, x: x, y: y)
            setOriginAndResetPlanePan(GeoCoordinate(name: "平面直角\(system)系", latitude: geo.latitude, longitude: geo.longitude, altitude: nil))
            planeSystemNumber = system
            statusMessage = "現在地を平面直角座標で設定：\(system)系"
        } catch {
            statusMessage = "平面直角座標変換エラー：\(error.localizedDescription)"
        }
    }

    func setOriginFromPoint(_ point: GeoCoordinate) {
        setOriginAndResetPlanePan(GeoCoordinate(name: point.name ?? "CSV選択点", latitude: point.latitude, longitude: point.longitude, altitude: nil))
        statusMessage = "現在地を選択点に設定：\(point.name ?? "名称なし")"
    }

    func updateHorizontalScreenBasis(_ basis: HorizontalScreenBasis) {
        let values = [basis.rightEast, basis.rightNorth, basis.forwardEast, basis.forwardNorth]
        guard values.allSatisfy(\.isFinite) else { return }
        horizontalScreenBasis = basis
    }

    func currentHorizontalScreenBasis() -> HorizontalScreenBasis? {
        horizontalScreenBasis
    }

    func updateAutomaticHeadingCorrectionFromRenderer(_ degrees: Double) {
        guard degrees.isFinite else { return }
        automaticHeadingCorrectionDegrees = Self.normalizedDegrees(degrees)
    }

    /// RealityKitのrootへ実際に適用した3軸変換を記録する。
    /// 中心更新はモデル上の「次の値」ではなく、ユーザーが画面で見ているこの値を使う。
    func updateRenderedTransform(
        panEastMeters: Double,
        panNorthMeters: Double,
        rootHeightMeters: Double,
        totalHeadingDegrees: Double
    ) {
        guard panEastMeters.isFinite,
              panNorthMeters.isFinite,
              rootHeightMeters.isFinite,
              totalHeadingDegrees.isFinite else { return }
        renderedTransformSnapshot = RenderedTransformSnapshot(
            panEastMeters: panEastMeters,
            panNorthMeters: panNorthMeters,
            rootHeightMeters: rootHeightMeters,
            totalHeadingDegrees: Self.normalizedDegrees(totalHeadingDegrees)
        )
    }

    func setPlanePanFromScreenDrag(
        startEast: Double,
        startNorth: Double,
        translation: CGSize,
        metersPerPoint: Double,
        screenBasis: HorizontalScreenBasis,
        totalHeadingDegrees: Double
    ) {
        let screenRight = Double(translation.width) * metersPerPoint
        let screenForward = -Double(translation.height) * metersPerPoint

        let screenWorldEast = screenRight * screenBasis.rightEast
            + screenForward * screenBasis.forwardEast
        let screenWorldNorth = screenRight * screenBasis.rightNorth
            + screenForward * screenBasis.forwardNorth

        // パッドはゲームの移動スティックと同じく、表示物ではなく利用者の移動方向を表す。
        // 画面／ARワールド方向をroot回転前の地理座標へ戻し、現在位置の移動量として保持する。
        // ドラッグ開始時の基底と方位を固定するため、操作中に端末や自動補正が少し動いても軸は変わらない。
        let angle = totalHeadingDegrees * .pi / 180.0
        let cosA = cos(angle)
        let sinA = sin(angle)
        let playerEast = screenWorldEast * cosA + screenWorldNorth * sinA
        let playerNorth = -screenWorldEast * sinA + screenWorldNorth * cosA
        planePanEastMeters = startEast + playerEast
        planePanNorthMeters = startNorth + playerNorth
    }

    func currentRenderedTotalHeadingDegrees() -> Double {
        renderedTransformSnapshot?.totalHeadingDegrees
            ?? Self.normalizedDegrees(headingOffsetDegrees + automaticHeadingCorrectionDegrees)
    }

    func updateOriginToCurrentPanCenter() {
        guard let origin else { return }
        let centerOffset = currentPanCenterOffsetMeters()
        let renderedRootHeight = renderedTransformSnapshot?.rootHeightMeters
            ?? effectiveDisplayPlaneOffsetMeters
        let temporaryHeight = renderedRootHeight - committedVerticalDisplayOffsetMeters
        let hasHorizontalChange = abs(centerOffset.east) > 0.0001 || abs(centerOffset.north) > 0.0001
        let hasHeightChange = abs(temporaryHeight - Self.defaultDisplayPlaneOffsetMeters) > 0.0001
        guard hasHorizontalChange || hasHeightChange else {
            statusMessage = "中心位置と高さは更新済みです"
            return
        }

        // 相対標高表示中に水平原点を変えると基準標高も変わる。
        // その差をroot高さへ足し、DEM上でも更新前後の世界Y座標を維持する。
        let oldAltitudeBaseline = hasHorizontalChange ? relativeAltitudeBaseline() : nil
        if hasHorizontalChange {
            self.origin = CoordinateConverter.coordinate(
                fromEast: centerOffset.east,
                north: centerOffset.north,
                origin: origin,
                name: "中心更新"
            )
        }
        let newAltitudeBaseline = hasHorizontalChange ? relativeAltitudeBaseline() : nil
        let altitudeBaselineDelta: Double
        if let oldAltitudeBaseline, let newAltitudeBaseline {
            altitudeBaselineDelta = newAltitudeBaseline - oldAltitudeBaseline
        } else {
            altitudeBaselineDelta = 0
        }

        let preservedRootHeight = renderedRootHeight + altitudeBaselineDelta
        committedVerticalDisplayOffsetMeters = preservedRootHeight - Self.defaultDisplayPlaneOffsetMeters
        displayPlaneOffsetMeters = Self.defaultDisplayPlaneOffsetMeters
        resetPlanePan()
        if hasHorizontalChange && hasHeightChange {
            statusMessage = "現在の表示中心と高さを新しい基準に反映しました"
        } else if hasHeightChange {
            statusMessage = "現在の表示高さを新しい基準に反映しました"
        } else {
            statusMessage = "現在の表示中心を現在地に反映しました"
        }
    }

    private func currentPanCenterOffsetMeters() -> (east: Double, north: Double) {
        // planePanは表示物の平行移動ではなく、root回転前の地理座標における
        // 「利用者の現在位置の移動量」。したがって中心更新では回転も符号反転もせず、
        // 実際に描画済みの値をそのまま新しい原点へ加える。
        let snapshot = renderedTransformSnapshot
        return (
            east: snapshot?.panEastMeters ?? planePanEastMeters,
            north: snapshot?.panNorthMeters ?? planePanNorthMeters
        )
    }

    func selectPointForAR(_ point: GeoCoordinate) {
        selectedPoint = point
        statusMessage = "AR強調点：\(point.name ?? "名称なし")"
    }

    func resetScreenAdjustments() {
        headingOffsetDegrees = 0
        resetDisplayHeight()
        resetPlanePan()
        distancesEnabled = false
    }

    func resetHeadingOffset() {
        headingOffsetDegrees = 0
    }

    func resetDisplaySettings() {
        settings = .defaults
    }

    /// AR写真を1枚要求する。撮影・保存中の連打は破棄せず、次の1枚として1件だけ保留する。
    ///
    /// - Returns: 直ちに新しい要求を開始した場合は `true`、保留した場合は `false`。
    @discardableResult
    func requestARPhotoCapture() -> Bool {
        if photoCaptureState.isBusy {
            hasPendingPhotoCaptureRequest = true
            photoCaptureMessage = "現在の写真を保存後、もう1枚撮影します"
            statusMessage = photoCaptureMessage ?? "AR写真の撮影を予約しました"
            return false
        }

        beginPhotoCaptureRequest()
        return true
    }

    /// RealityKitのスナップショット処理が実際に開始したことを通知する。
    func photoCaptureDidStart(requestID: Int) {
        guard requestID == activePhotoCaptureRequestID,
              photoCaptureState == .capturing else { return }
        photoCaptureMessage = "AR写真を撮影中…"
        statusMessage = photoCaptureMessage ?? "AR写真を撮影中…"
        schedulePhotoCaptureTimeout(for: requestID, after: 12)
    }

    /// 画像生成が終わり、写真アプリへの保存処理へ進んだことを通知する。
    func photoCaptureDidBeginSaving(requestID: Int) {
        guard requestID == activePhotoCaptureRequestID,
              photoCaptureState == .capturing else { return }
        photoCaptureTimeoutTask?.cancel()
        photoCaptureTimeoutTask = nil
        photoCaptureState = .saving
        photoCaptureMessage = "写真アプリへ保存中…"
        statusMessage = photoCaptureMessage ?? "AR写真を保存中…"
        // 通常はCoordinator側の保存監視が先に完了する。ビュー破棄などで
        // コールバックが届かない場合にも、UIが保存中のまま固まらないための予備監視。
        schedulePhotoCaptureTimeout(
            for: requestID,
            after: 20,
            message: "写真アプリへの保存が時間内に完了しませんでした。もう一度お試しください"
        )
    }

    func photoCaptureSucceeded(
        requestID: Int,
        message: String = "AR写真を写真アプリへ保存しました"
    ) {
        guard requestID == activePhotoCaptureRequestID else { return }
        finishPhotoCapture(requestID: requestID, result: .success, message: message)
    }

    func photoCaptureFailed(requestID: Int, message: String) {
        guard requestID == activePhotoCaptureRequestID else { return }
        finishPhotoCapture(requestID: requestID, result: .failure(message), message: message)
    }

    /// 成功・失敗表示を閉じる。処理中は何もしない。
    func dismissPhotoCaptureFeedback() {
        guard !photoCaptureState.isBusy else { return }
        photoCaptureFeedbackTask?.cancel()
        photoCaptureFeedbackTask = nil
        photoCaptureState = .idle
        photoCaptureMessage = nil
    }

    private func beginPhotoCaptureRequest() {
        photoCaptureFeedbackTask?.cancel()
        photoCaptureFeedbackTask = nil
        photoCaptureTimeoutTask?.cancel()
        photoCaptureTimeoutTask = nil

        photoCaptureRequestID &+= 1
        if photoCaptureRequestID <= 0 {
            photoCaptureRequestID = 1
        }
        activePhotoCaptureRequestID = photoCaptureRequestID
        photoCaptureState = .capturing
        photoCaptureMessage = "AR写真を準備中…"
        statusMessage = photoCaptureMessage ?? "AR写真を準備中…"
        // 初回は写真追加権限のOSダイアログが表示されることがあるため、
        // RealityKitが実際に撮影を始めるまでの待機には余裕を持たせる。
        schedulePhotoCaptureTimeout(
            for: photoCaptureRequestID,
            after: 60,
            message: "写真撮影の準備が時間内に完了しませんでした。もう一度お試しください"
        )
    }

    private func finishPhotoCapture(
        requestID: Int,
        result: PhotoCaptureState,
        message: String
    ) {
        photoCaptureTimeoutTask?.cancel()
        photoCaptureTimeoutTask = nil
        activePhotoCaptureRequestID = nil
        photoCaptureState = result
        photoCaptureMessage = message
        statusMessage = message

        if hasPendingPhotoCaptureRequest {
            hasPendingPhotoCaptureRequest = false
            photoCaptureFeedbackTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self?.beginPhotoCaptureRequest()
            }
        } else {
            schedulePhotoCaptureFeedbackDismissal(for: requestID)
        }
    }

    private func schedulePhotoCaptureTimeout(
        for requestID: Int,
        after seconds: TimeInterval,
        message: String = "AR写真の作成が時間内に完了しませんでした。もう一度お試しください"
    ) {
        photoCaptureTimeoutTask?.cancel()
        photoCaptureTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled,
                  let self,
                  self.activePhotoCaptureRequestID == requestID,
                  self.photoCaptureState.isBusy else { return }
            self.finishPhotoCapture(
                requestID: requestID,
                result: .failure(message),
                message: message
            )
        }
    }

    private func schedulePhotoCaptureFeedbackDismissal(for requestID: Int) {
        photoCaptureFeedbackTask?.cancel()
        photoCaptureFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  let self,
                  self.activePhotoCaptureRequestID == nil,
                  self.photoCaptureRequestID == requestID,
                  !self.photoCaptureState.isBusy else { return }
            self.photoCaptureState = .idle
            self.photoCaptureMessage = nil
        }
    }


    func importCSV(text: String, fileName: String, mapping: CSVColumnMapping) {
        importCSVAsync(text: text, fileName: fileName, mapping: mapping)
    }

    func importCSVAsync(text: String, fileName: String, mapping: CSVColumnMapping) {
        var safeMapping = mapping
        safeMapping.planeSystemNumber = Swift.max(1, Swift.min(safeMapping.planeSystemNumber, 19))
        let operationID = beginImportProgress("CSV読込中：\(fileName)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let parseResult = try CSVParser.parse(text: text, mapping: safeMapping)
                let result = ParsedImportResult(
                    name: fileName,
                    features: parseResult.features,
                    points: parseResult.points,
                    rasters: [],
                    elevationGrids: [],
                    statusMessage: "CSV読込：\(fileName) / \(parseResult.points.count)点",
                    planeSystemNumber: safeMapping.coordinateKind == .planeXY ? safeMapping.planeSystemNumber : nil,
                    enableRasters: false
                )
                Task { @MainActor in
                    self.applyParsedImport(result)
                    self.finishImportProgress(operationID: operationID)
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "CSV読込エラー：\(error.localizedDescription)"
                    self.finishImportProgress(operationID: operationID)
                }
            }
        }
    }

    func importGeoTIFF(data: Data, fileName: String, coordinateMode: GeoTIFFCoordinateMode) {
        importGeoTIFFAsync(data: data, fileName: fileName, coordinateMode: coordinateMode)
    }

    func importGeoTIFFAsync(data: Data, fileName: String, coordinateMode: GeoTIFFCoordinateMode) {
        let operationID = beginImportProgress("GeoTIFF読込中：\(fileName)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let raster = try GeoTIFFParser.parse(data: data, fileName: fileName, coordinateMode: coordinateMode)
                let planeSystem: Int?
                if case .planeRectangular(let system) = coordinateMode {
                    planeSystem = system
                } else {
                    planeSystem = nil
                }
                let result = ParsedImportResult(
                    name: fileName,
                    features: [],
                    points: [],
                    rasters: [raster],
                    elevationGrids: [],
                    statusMessage: "GeoTIFF読込：\(coordinateMode.description) / \(raster.renderedPixelWidth)x\(raster.renderedPixelHeight) / \(raster.notes)",
                    planeSystemNumber: planeSystem,
                    enableRasters: true
                )
                Task { @MainActor in
                    self.applyParsedImport(result)
                    self.finishImportProgress(operationID: operationID)
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "GeoTIFF読込エラー：\(error.localizedDescription)"
                    self.finishImportProgress(operationID: operationID)
                }
            }
        }
    }

    func importElevationGeoTIFF(
        data: Data,
        fileName: String,
        coordinateMode: GeoTIFFCoordinateMode
    ) {
        let operationID = beginImportProgress("標高GeoTIFF読込中：\(fileName)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let grid = try ElevationGeoTIFFParser.parse(
                    data: data,
                    fileName: fileName,
                    coordinateMode: coordinateMode
                )
                let planeSystem: Int?
                if case .planeRectangular(let system) = coordinateMode {
                    planeSystem = system
                } else {
                    planeSystem = nil
                }
                let result = ParsedImportResult(
                    name: fileName,
                    features: [],
                    points: [],
                    rasters: [],
                    elevationGrids: [grid],
                    statusMessage: Self.elevationImportStatus(
                        fileName: fileName,
                        grids: [grid]
                    ),
                    planeSystemNumber: planeSystem,
                    enableRasters: false
                )
                Task { @MainActor in
                    self.applyParsedImport(result)
                    self.finishImportProgress(operationID: operationID)
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "標高GeoTIFF読込エラー：\(error.localizedDescription)"
                    self.finishImportProgress(operationID: operationID)
                }
            }
        }
    }

    nonisolated private static func elevationImportStatus(
        fileName: String,
        grids: [ElevationGrid]
    ) -> String {
        let validCellCount = grids.reduce(0) { $0 + $1.validValueCount }
        let cellSize = grids.map(\.estimatedCellSizeMeters).min() ?? 0
        let spacingText = cellSize > 0
            ? " / 最小解像度約\(cellSize.formatted(.number.precision(.fractionLength(1))))m"
            : ""
        return "DEM読込：\(fileName) / \(grids.count)面 / 有効\(validCellCount)セル\(spacingText)"
    }

    var hasElevationDEM: Bool {
        !elevationGrids.isEmpty
    }

    var elevationDEMSummary: String {
        guard !elevationGrids.isEmpty else { return "標高DEMは未読込です" }
        let cellCount = elevationGrids.reduce(0) { $0 + $1.width * $1.height }
        let names = Set(elevationGrids.map(\.name))
        let smallestCell = elevationGrids.map(\.estimatedCellSizeMeters).min() ?? 0
        return "DEM \(elevationGrids.count)面（\(names.count)ファイル） / \(cellCount)セル / 最小解像度約\(smallestCell.formatted(.number.precision(.fractionLength(1))))m"
    }

    var displayLimitResult: DisplayLimitResult {
        let signature = makeDisplayLimitCacheSignature()
        if signature == displayLimitCacheSignature, let cached = displayLimitCache {
            return cached
        }
        let result = makeLimitedFeatures()
        displayLimitCacheSignature = signature
        displayLimitCache = result
        return result
    }

    var planFeatures: [GeoFeature] {
        displayLimitResult.features
    }

    var renderFeatures: [RenderFeature] {
        rebuildRenderCacheIfNeeded()
        return renderFeaturesCache
    }

    var renderLabels: [RenderLabel] {
        rebuildRenderCacheIfNeeded()
        return renderLabelsCache
    }

    var selectedRenderPosition: SIMD3<Float>? {
        rebuildRenderCacheIfNeeded()
        return selectedRenderPositionCache
    }

    var renderRasters: [RenderRaster] {
        makeRenderRasters()
    }

    var renderLimitMessage: String {
        displayLimitResult.message
    }

    var renderStyle: RenderStyle {
        let sizeScale = settings.masterSizeScale
        return RenderStyle(
            pointRadius: Float(settings.arPointSize * sizeScale),
            selectedPointRadius: Float(settings.arSelectedSphereSize * sizeScale),
            lineRadius: Float(settings.arLineWidth * sizeScale),
            farMinimumSizeEnabled: settings.farMinimumSizeEnabled,
            farPointMinRadius: Float(settings.farPointMinSize * sizeScale),
            farLineMinRadius: Float(settings.farLineMinWidth * sizeScale),
            rasterOpacity: Float(settings.rasterOpacity)
        )
    }

    private var effectiveDisplayRadiusMeters: Double {
        guard settings.displayRadiusMeters > 0 else { return 0 }
        return settings.displayRadiusMeters * settings.masterRangeScale
    }

    private var effectiveLabelDistanceMeters: Double {
        guard settings.labelDistanceMeters > 0 else { return 0 }
        return settings.labelDistanceMeters * settings.masterRangeScale
    }


    private func rebuildRenderCacheIfNeeded() {
        let limit = displayLimitResult
        let signature = makeRenderCacheSignature(limit: limit)
        guard signature != renderCacheSignature else { return }

        // 標高差表示用の基準標高は1回だけ求め、点・線・ラベルで共通利用する。
        // 以前はRenderFeature生成とラベル生成の双方で計算経路に入っていたため、
        // 標高付きの大きなSIMA面データでは更新時の負荷が出やすかった。
        let altitudeBaseline = settings.useRelativeAltitude ? relativeAltitudeBaseline() : nil
        let features = makeRenderFeatures(from: limit.features, altitudeBaseline: altitudeBaseline)
        let selected = makeSelectedRenderPosition(altitudeBaseline: altitudeBaseline)
        let labels = makeRenderLabels(
            from: features,
            parcelLabelFeatures: limit.parcelLabelFeatures,
            selectedPosition: selected,
            altitudeBaseline: altitudeBaseline
        )

        renderCacheSignature = signature
        renderFeaturesCache = features
        selectedRenderPositionCache = selected
        renderLabelsCache = labels
    }

    private func makeRenderCacheSignature(limit: DisplayLimitResult) -> String {
        let originText: String
        if let origin {
            originText = "\(origin.latitude.rounded(toPlaces: 8)),\(origin.longitude.rounded(toPlaces: 8))"
        } else {
            originText = "no-origin"
        }
        return [
            makeDisplayLimitCacheSignature(),
            "origin=\(originText)",
            "sel=\(selectedPoint?.id.uuidString ?? "no-selected")",
            "alt=\(settings.useRelativeAltitude)-\(settings.relativeAltitudeLimitMeters)",
            "dem=\(elevationGrids.map { $0.id.uuidString }.joined(separator: ","))-\(settings.boundaryTerrainFollowEnabled)-\(settings.demSampleSpacingMeters)",
            "labels=\(settings.showLabels)-\(settings.maxLabelCount)-\(settings.labelDistanceMeters)-master\(settings.masterRangeScale)",
            "size=\(settings.arPointSize)-\(settings.arSelectedSphereSize)-\(settings.arLineWidth)-master\(settings.masterSizeScale)-auto\(settings.farMinimumSizeEnabled)-\(settings.farPointMinSize)-\(settings.farLineMinWidth)",
            "limit=\(limit.pointCount)-\(limit.lineCount)-pLabel\(limit.parcelLabelFeatures.count)"
        ].joined(separator: "|")
    }

    private func makeSelectedRenderPosition(altitudeBaseline: Double?) -> SIMD3<Float>? {
        guard let origin, let selectedPoint else { return nil }
        let terrainElevation = settings.boundaryTerrainFollowEnabled
            ? sampledDEMElevation(at: selectedPoint)
            : nil
        return CoordinateConverter.localARPosition(
            from: selectedPoint,
            origin: origin,
            headingOffsetDegrees: 0,
            verticalOffsetMeters: terrainElevation.map {
                relativeHeightMeters(
                    elevation: $0,
                    baseline: altitudeBaseline,
                    allowsZero: true,
                    preservesSubmeter: true
                )
            } ?? relativeHeightMeters(for: selectedPoint, baseline: altitudeBaseline)
        )
    }

    private func makeRenderLabels(
        from renderFeatures: [RenderFeature],
        parcelLabelFeatures: [GeoFeature],
        selectedPosition: SIMD3<Float>?,
        altitudeBaseline: Double?
    ) -> [RenderLabel] {
        let style = renderStyle
        let parcelLabelOffset = Float(max(style.lineRadius * 2.0 + 0.03, 0.04))
        let selectedDistance = selectedPosition.map { horizontalDistance($0) } ?? 0
        let selectedRadius = style.effectivePointRadius(distance: selectedDistance, baseRadius: style.selectedPointRadius)
        let selectedLabelOffset = max(0.05 + selectedRadius * 1.15 + 0.035, 0.075)

        guard settings.showLabels else {
            if let selected = selectedPosition, let selectedPoint {
                return [RenderLabel(id: selectedPoint.id, text: selectedPoint.name ?? "選択点", position: selected + SIMD3<Float>(0, selectedLabelOffset, 0), distance: horizontalDistance(selected), labelRole: .point, isSelected: true, screenYOffset: 12)]
            }
            return []
        }

        var labels: [RenderLabel] = []

        // 点名だけを表示する。ライン名は表示しない。
        for feature in renderFeatures where feature.kind == .point {
            for position in feature.positions {
                let distance = horizontalDistance(position)
                if effectiveLabelDistanceMeters <= 0 || Double(distance) <= effectiveLabelDistanceMeters {
                    let visibleRadius = style.effectivePointRadius(distance: distance)
                    let pointLabelOffset = max(visibleRadius * 1.15 + 0.025, 0.035)
                    labels.append(RenderLabel(id: UUID(), text: feature.name, position: position + SIMD3<Float>(0, pointLabelOffset, 0), distance: distance, labelRole: .point, screenYOffset: 10))
                }
            }
        }

        // 画地名は、表示用に分割した線分の中心ではなく、元の面要素から作った代表点に表示する。
        // これにより、線分の一部だけが表示対象になった場合でも、画地名が辺上や意図しない高さへ飛びにくくなる。
        if settings.showLines {
            for feature in parcelLabelFeatures where feature.labelRole == .parcel {
                guard let coord = feature.coordinates.first else { continue }
                guard let origin else { continue }
                let position = CoordinateConverter.localARPosition(
                    from: coord,
                    origin: origin,
                    headingOffsetDegrees: 0,
                    verticalOffsetMeters: {
                        if settings.boundaryTerrainFollowEnabled,
                           let terrainElevation = sampledDEMElevation(at: coord) {
                            return relativeHeightMeters(
                                elevation: terrainElevation,
                                baseline: altitudeBaseline,
                                allowsZero: true,
                                preservesSubmeter: true
                            )
                        }
                        return relativeHeightMeters(for: coord, baseline: altitudeBaseline)
                    }()
                )
                let distance = horizontalDistance(position)
                if effectiveLabelDistanceMeters <= 0 || Double(distance) <= effectiveLabelDistanceMeters {
                    labels.append(RenderLabel(id: feature.id, text: feature.name, position: position + SIMD3<Float>(0, parcelLabelOffset, 0), distance: distance, labelRole: .parcel, screenYOffset: 0))
                }
            }
        }

        if let selected = selectedPosition, let selectedPoint {
            labels.append(RenderLabel(id: selectedPoint.id, text: "選択：\(selectedPoint.name ?? "名称なし")", position: selected + SIMD3<Float>(0, selectedLabelOffset, 0), distance: horizontalDistance(selected), labelRole: .point, isSelected: true, screenYOffset: 12))
        }

        let maxCount = settings.maxLabelCount
        guard maxCount > 0, labels.count > maxCount else { return labels }
        let selectedLabels = labels.filter { $0.isSelected }
        let normal = labels.filter { !$0.isSelected }.sorted { $0.distance < $1.distance }
        let remaining = max(0, maxCount - selectedLabels.count)
        return selectedLabels + Array(normal.prefix(remaining))
    }

    private func relativeHeightMeters(for coord: GeoCoordinate) -> Double {
        relativeHeightMeters(for: coord, baseline: settings.useRelativeAltitude ? relativeAltitudeBaseline() : nil)
    }

    private func relativeHeightMeters(for coord: GeoCoordinate, baseline: Double?) -> Double {
        relativeHeightMeters(
            elevation: coord.altitude,
            baseline: baseline,
            allowsZero: false,
            preservesSubmeter: false
        )
    }

    private func relativeHeightMeters(
        elevation: Double?,
        baseline: Double?,
        allowsZero: Bool,
        preservesSubmeter: Bool
    ) -> Double {
        guard settings.useRelativeAltitude, let baseline else { return 0 }
        let altitude: Double
        if allowsZero {
            guard let elevation, elevation.isFinite else { return 0 }
            altitude = elevation
        } else {
            guard let value = validAltitudeValue(elevation) else { return 0 }
            altitude = value
        }

        // 従来の座標標高は概略表示の1m単位を維持する。
        // DEMだけは地形の連続性を失わないよう0.1m単位で扱う。標高0mも有効値。
        var height = altitude - baseline
        height = preservesSubmeter
            ? (height * 10).rounded() / 10
            : height.rounded()
        if settings.relativeAltitudeLimitMeters > 0 {
            height = max(-settings.relativeAltitudeLimitMeters, min(settings.relativeAltitudeLimitMeters, height))
        }
        return height
    }

    private func relativeAltitudeBaseline() -> Double? {
        guard settings.useRelativeAltitude, let origin else { return nil }
        rebuildAltitudeCacheIfNeeded()
        if let cached = altitudeBaselineCache { return cached }
        if settings.boundaryTerrainFollowEnabled,
           let terrainElevation = sampledDEMElevation(at: origin) {
            altitudeBaselineCache = terrainElevation
            return terrainElevation
        }
        if settings.boundaryTerrainFollowEnabled,
           let terrainElevation = nearestBoundaryDEMElevation(to: origin) {
            altitudeBaselineCache = terrainElevation
            return terrainElevation
        }
        guard !altitudeReferenceCache.isEmpty else { return nil }

        let nearest = nearestAltitudeReference(to: origin)
        altitudeBaselineCache = nearest?.altitude.rounded()
        return altitudeBaselineCache
    }

    private func validAltitudeValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        // SIMA/KML/CSVでは「0」が未設定扱いで入ることがあるため、相対高さの基準には使わない。
        if abs(value) < 0.001 { return nil }
        return value
    }

    /// 表示中のDEMを解像度の細かい順に調べる。
    /// 標高0mは有効で、範囲外・欠測の場合だけ次のDEMへ進む。
    private func sampledDEMElevation(at coordinate: GeoCoordinate) -> Double? {
        for grid in elevationGrids {
            if let elevation = grid.elevation(at: coordinate), elevation.isFinite {
                return elevation
            }
        }
        return nil
    }

    /// 立ち位置がDEMの外でも、重なっている境界のうち立ち位置に最も近い地点を
    /// 高さ0mの代替基準にして、地形の起伏だけは表示できるようにする。
    private func nearestBoundaryDEMElevation(to coordinate: GeoCoordinate) -> Double? {
        var bestDistance = Double.greatestFiniteMagnitude
        var bestElevation: Double?

        func consider(_ candidate: GeoCoordinate) {
            guard let elevation = sampledDEMElevation(at: candidate) else { return }
            let offset = CoordinateConverter.enuMeters(from: candidate, origin: coordinate)
            let distance = hypot(offset.east, offset.north)
            if distance < bestDistance {
                bestDistance = distance
                bestElevation = elevation
            }
        }

        // 表示上限適用後の境界を使い、最寄り探索の負荷も描画対象と同程度に抑える。
        let boundaryFeatures = displayLimitResult.features.filter {
            $0.kind == .line || $0.kind == .polygon
        }
        for feature in boundaryFeatures {
            for candidate in feature.coordinates {
                consider(candidate)
            }
        }

        // 両端がDEM外でも線分途中だけがDEMを横切る場合に備え、DEMの外接矩形と
        // 交差する区間を直接サンプリングする。
        for feature in boundaryFeatures {
            var pairs: [(GeoCoordinate, GeoCoordinate)] = []
            if feature.coordinates.count >= 2 {
                for index in 0..<(feature.coordinates.count - 1) {
                    pairs.append((feature.coordinates[index], feature.coordinates[index + 1]))
                }
            }
            if feature.kind == .polygon,
               let first = feature.coordinates.first,
               let last = feature.coordinates.last,
               !isSameCoordinate(first, last) {
                pairs.append((last, first))
            }

            for pair in pairs {
                for grid in elevationGrids {
                    guard let range = segmentParameterRange(
                        from: pair.0,
                        to: pair.1,
                        intersecting: grid
                    ) else { continue }
                    let lower = range.lowerBound
                    let upper = range.upperBound
                    for index in 0...8 {
                        let ratio = lower
                            + (upper - lower) * Double(index) / 8.0
                        consider(
                            GeoCoordinate(
                                latitude: pair.0.latitude
                                    + (pair.1.latitude - pair.0.latitude) * ratio,
                                longitude: pair.0.longitude
                                    + (pair.1.longitude - pair.0.longitude) * ratio
                            )
                        )
                    }
                }
            }
        }
        return bestElevation
    }

    private func segmentParameterRange(
        from start: GeoCoordinate,
        to end: GeoCoordinate,
        intersecting grid: ElevationGrid
    ) -> ClosedRange<Double>? {
        var lower = 0.0
        var upper = 1.0

        func clip(
            startValue: Double,
            delta: Double,
            minimum: Double,
            maximum: Double
        ) -> Bool {
            guard startValue.isFinite,
                  delta.isFinite,
                  minimum.isFinite,
                  maximum.isFinite else { return false }
            if abs(delta) < 1.0e-15 {
                return startValue >= minimum && startValue <= maximum
            }
            let first = (minimum - startValue) / delta
            let second = (maximum - startValue) / delta
            let entry = min(first, second)
            let exit = max(first, second)
            lower = max(lower, entry)
            upper = min(upper, exit)
            return lower <= upper
        }

        guard clip(
            startValue: start.longitude,
            delta: end.longitude - start.longitude,
            minimum: grid.minimumLongitude,
            maximum: grid.maximumLongitude
        ), clip(
            startValue: start.latitude,
            delta: end.latitude - start.latitude,
            minimum: grid.minimumLatitude,
            maximum: grid.maximumLatitude
        ) else {
            return nil
        }
        return max(0, lower)...min(1, upper)
    }

    private func rebuildAltitudeCacheIfNeeded() {
        let signature = makeAltitudeCacheSignature()
        guard signature != altitudeCacheSignature else { return }
        altitudeCacheSignature = signature
        altitudeBaselineCache = nil
        altitudeReferenceCache = []
        altitudeGrid = [:]

        let validPairs: [(coord: GeoCoordinate, altitude: Double)] = features.flatMap { feature in
            feature.coordinates.compactMap { coord in
                guard let altitude = validAltitudeValue(coord.altitude) else { return nil }
                return (coord: coord, altitude: altitude.rounded())
            }
        }

        altitudeGridOrigin = origin ?? validPairs.first?.coord
        guard let gridOrigin = altitudeGridOrigin else { return }

        altitudeReferenceCache = validPairs.map { pair in
            let meters = CoordinateConverter.enuMeters(from: pair.coord, origin: gridOrigin)
            return AltitudeReference(coord: pair.coord, altitude: pair.altitude, east: meters.east, north: meters.north)
        }

        for (index, reference) in altitudeReferenceCache.enumerated() {
            let key = altitudeGridKey(east: reference.east, north: reference.north)
            altitudeGrid[key, default: []].append(index)
        }
    }

    private func nearestAltitudeReference(to coord: GeoCoordinate) -> AltitudeReference? {
        guard !altitudeReferenceCache.isEmpty else { return nil }

        // 小規模データでは厳密探索。大規模データではグリッド近傍探索。
        if altitudeReferenceCache.count <= altitudeExactSearchLimit {
            return altitudeReferenceCache.min { lhs, rhs in
                let dl = CoordinateConverter.enuMeters(from: lhs.coord, origin: coord)
                let dr = CoordinateConverter.enuMeters(from: rhs.coord, origin: coord)
                return hypot(dl.east, dl.north) < hypot(dr.east, dr.north)
            }
        }

        guard let gridOrigin = altitudeGridOrigin else { return altitudeReferenceCache.first }
        let target = CoordinateConverter.enuMeters(from: coord, origin: gridOrigin)
        let centerKey = altitudeGridKey(east: target.east, north: target.north)

        var best: AltitudeReference?
        var bestDistance = Double.greatestFiniteMagnitude

        for ring in 0...altitudeNearestSearchMaxRings {
            var foundInRing = false
            for x in (centerKey.x - ring)...(centerKey.x + ring) {
                for y in (centerKey.y - ring)...(centerKey.y + ring) {
                    if ring > 0 && x > centerKey.x - ring && x < centerKey.x + ring && y > centerKey.y - ring && y < centerKey.y + ring {
                        continue
                    }
                    guard let indices = altitudeGrid[AltitudeGridKey(x: x, y: y)] else { continue }
                    foundInRing = true
                    for index in indices {
                        let reference = altitudeReferenceCache[index]
                        let distance = hypot(reference.east - target.east, reference.north - target.north)
                        if distance < bestDistance {
                            bestDistance = distance
                            best = reference
                        }
                    }
                }
            }
            if foundInRing, best != nil { break }
        }

        return best
    }

    private func altitudeGridKey(east: Double, north: Double) -> AltitudeGridKey {
        AltitudeGridKey(
            x: Int(floor(east / altitudeGridCellSizeMeters)),
            y: Int(floor(north / altitudeGridCellSizeMeters))
        )
    }

    private func makeAltitudeCacheSignature() -> String {
        let featureCoordinateCount = features.reduce(0) { $0 + $1.coordinates.count }
        let firstFeatureID = features.first?.id.uuidString ?? "none"
        let lastFeatureID = features.last?.id.uuidString ?? "none"
        let originText: String
        if let origin {
            originText = "\(origin.latitude.rounded(toPlaces: 8)),\(origin.longitude.rounded(toPlaces: 8))"
        } else {
            originText = "no-origin"
        }
        let demIDs = elevationGrids.map { $0.id.uuidString }.joined(separator: ",")
        return "f=\(features.count)|c=\(featureCoordinateCount)|first=\(firstFeatureID)|last=\(lastFeatureID)|o=\(originText)|dem=\(demIDs)|follow=\(settings.boundaryTerrainFollowEnabled)"
    }

    private func makeRenderRasters() -> [RenderRaster] {
        guard let origin, rastersEnabled else { return [] }
        return rasters.prefix(maxRasterCount).map { raster in
            let positions = raster.corners.map { coord in
                return CoordinateConverter.localARPosition(
                    from: coord,
                    origin: origin,
                    headingOffsetDegrees: 0,
                    verticalOffsetMeters: 0
                )
            }
            return RenderRaster(id: raster.id, name: raster.name, image: raster.image, positions: positions, notes: raster.notes)
        }
    }

    private func makeRenderFeatures(from limited: [GeoFeature], altitudeBaseline: Double?) -> [RenderFeature] {
        guard let origin else { return [] }
        let lineFeatures = limited.filter { $0.kind == .line || $0.kind == .polygon }
        var terrainSpacingByID: [UUID: Double] = [:]
        if settings.boundaryTerrainFollowEnabled, settings.useRelativeAltitude {
            for feature in lineFeatures where feature.coordinates.count >= 2 {
                let matchingGrids = elevationGridsIntersectingBoundary(feature.coordinates)
                guard !matchingGrids.isEmpty else { continue }
                let nativeSpacing = matchingGrids
                    .map(\.estimatedCellSizeMeters)
                    .filter { $0.isFinite && $0 > 0 }
                    .min() ?? 1
                terrainSpacingByID[feature.id] = max(
                    settings.demSampleSpacingMeters,
                    nativeSpacing
                )
            }
        }
        let maximumGeneratedSegments = max(5_000, lineFeatures.count)
        var spacingMultiplier = 1.0

        func generatedSegmentCount(multiplier: Double) -> Int {
            var count = 0
            for feature in lineFeatures {
                if let baseSpacing = terrainSpacingByID[feature.id] {
                    count += desiredBoundarySegmentCount(
                        feature.coordinates,
                        spacingMeters: baseSpacing * multiplier
                    )
                } else {
                    count += max(1, feature.coordinates.count - 1)
                }
                if count > maximumGeneratedSegments { return count }
            }
            return count
        }

        if generatedSegmentCount(multiplier: spacingMultiplier) > maximumGeneratedSegments {
            var lower = 1.0
            var upper = 2.0
            for _ in 0..<64 {
                if generatedSegmentCount(multiplier: upper) <= maximumGeneratedSegments {
                    break
                }
                lower = upper
                upper *= 2
            }
            // 全線を同じ間隔で粗くするため、近い線だけが細かくなりすぎない。
            for _ in 0..<24 {
                let middle = (lower + upper) * 0.5
                if generatedSegmentCount(multiplier: middle) > maximumGeneratedSegments {
                    lower = middle
                } else {
                    upper = middle
                }
            }
            spacingMultiplier = upper
        }

        return limited.map { feature in
            let terrainSpacing = terrainSpacingByID[feature.id].map {
                $0 * spacingMultiplier
            }
            let shouldFollowTerrain = terrainSpacing != nil
            // 境界線だけを細分化する処理とは別に、点は元の頂点位置のまま
            // DEMを補間すればよい。従来はこの分岐が線にしか存在せず、
            // 「高さ情報を使う」がONでも点だけ元データの高度に留まっていた。
            let shouldSamplePointTerrain = feature.kind == .point
                && settings.useRelativeAltitude
                && settings.boundaryTerrainFollowEnabled

            let coordinates: [GeoCoordinate]
            if let terrainSpacing {
                coordinates = densifiedBoundaryCoordinates(
                    feature.coordinates,
                    spacingMeters: terrainSpacing,
                    maximumSegments: desiredBoundarySegmentCount(
                        feature.coordinates,
                        spacingMeters: terrainSpacing
                    )
                )
            } else {
                coordinates = feature.coordinates
            }

            let positions: [SIMD3<Float>] = coordinates.map { coord in
                let verticalOffset: Double
                if (shouldFollowTerrain || shouldSamplePointTerrain),
                   let terrainElevation = sampledDEMElevation(at: coord) {
                    verticalOffset = relativeHeightMeters(
                        elevation: terrainElevation,
                        baseline: altitudeBaseline,
                        allowsZero: true,
                        preservesSubmeter: true
                    )
                } else {
                    verticalOffset = relativeHeightMeters(for: coord, baseline: altitudeBaseline)
                }
                return CoordinateConverter.localARPosition(
                    from: coord,
                    origin: origin,
                    headingOffsetDegrees: 0,
                    verticalOffsetMeters: verticalOffset
                )
            }
            let pillarPositions: [SIMD3<Float>]?
            if shouldFollowTerrain, let first = positions.first, let last = positions.last {
                pillarPositions = [first, last]
            } else {
                pillarPositions = nil
            }
            return RenderFeature(
                id: feature.id,
                name: feature.name,
                kind: feature.kind,
                positions: positions,
                labelRole: feature.labelRole,
                pillarPositions: pillarPositions
            )
        }
    }

    private func desiredBoundarySegmentCount(
        _ coordinates: [GeoCoordinate],
        spacingMeters: Double
    ) -> Int {
        guard coordinates.count >= 2 else { return 0 }
        var count = 0
        for index in 0..<(coordinates.count - 1) {
            let offset = CoordinateConverter.enuMeters(
                from: coordinates[index + 1],
                origin: coordinates[index]
            )
            let segmentLength = hypot(offset.east, offset.north)
            count += max(
                1,
                segmentLength.isFinite
                    ? Int(ceil(segmentLength / max(1, spacingMeters)))
                    : 1
            )
        }
        return count
    }

    private func elevationGridsIntersectingBoundary(
        _ coordinates: [GeoCoordinate]
    ) -> [ElevationGrid] {
        guard !coordinates.isEmpty else { return [] }
        return elevationGrids.filter { grid in
            if coordinates.contains(where: grid.contains) {
                return true
            }
            guard coordinates.count >= 2 else { return false }
            for index in 0..<(coordinates.count - 1) {
                if segmentParameterRange(
                    from: coordinates[index],
                    to: coordinates[index + 1],
                    intersecting: grid
                ) != nil {
                    return true
                }
            }
            return false
        }
    }

    private func densifiedBoundaryCoordinates(
        _ coordinates: [GeoCoordinate],
        spacingMeters: Double,
        maximumSegments: Int
    ) -> [GeoCoordinate] {
        guard coordinates.count >= 2, maximumSegments > 0 else { return coordinates }
        var output: [GeoCoordinate] = [coordinates[0]]
        var remaining = maximumSegments

        for index in 0..<(coordinates.count - 1) where remaining > 0 {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            let vector = CoordinateConverter.enuMeters(from: b, origin: a)
            let length = hypot(vector.east, vector.north)
            let segments = min(
                remaining,
                length.isFinite
                    ? max(1, Int(ceil(length / max(1, spacingMeters))))
                    : 1
            )
            for step in 1...segments {
                let ratio = Double(step) / Double(segments)
                var coordinate = CoordinateConverter.coordinate(
                    fromEast: vector.east * ratio,
                    north: vector.north * ratio,
                    origin: a,
                    name: step == segments ? b.name : nil
                )
                if let altitudeA = a.altitude,
                   altitudeA.isFinite,
                   let altitudeB = b.altitude,
                   altitudeB.isFinite {
                    coordinate.altitude = altitudeA + (altitudeB - altitudeA) * ratio
                } else {
                    coordinate.altitude = step == segments ? b.altitude : a.altitude
                }
                output.append(coordinate)
            }
            remaining -= segments
        }
        return output
    }

    private func makeLimitedFeatures() -> DisplayLimitResult {
        let pointFeatures = features.filter { $0.kind == .point && settings.showPoints }
        let lineFeatures = features.filter { ($0.kind == .line || $0.kind == .polygon) && settings.showLines }

        let totalPointCount = pointFeatures.reduce(0) { $0 + $1.coordinates.count }
        let totalLineCount = totalLineSegmentCount(in: lineFeatures)

        let filteredPoints = filterByRadius(pointFeatures)

        var selectedPointFeatures: [GeoFeature] = []
        var pointItems: [(feature: GeoFeature, nearest: Double, count: Int)] = filteredPoints.map { feature in
            (feature, nearestDistanceMeters(for: feature.coordinates), feature.coordinates.count)
        }

        if let selectedPoint, settings.showPoints {
            let selectedFeature = GeoFeature(name: selectedPoint.name ?? "選択点", kind: .point, coordinates: [selectedPoint])
            selectedPointFeatures = [selectedFeature]
            pointItems.removeAll { item in
                item.feature.coordinates.contains { coord in
                    isSameCoordinate(coord, selectedPoint)
                }
            }
        }

        var selectedPointsUsed = selectedPointFeatures.reduce(0) { $0 + $1.coordinates.count }
        var selectedFeatures = selectedPointFeatures
        let pointBudget = max(settings.maxDisplayPoints - selectedPointsUsed, 0)
        let limitedPoints = limitPointFeatures(pointItems.sorted { $0.nearest < $1.nearest }, budget: pointBudget)
        selectedFeatures.append(contentsOf: limitedPoints.features)
        selectedPointsUsed += limitedPoints.count

        let lineBudget = max(settings.maxDisplayLines, 0)
        let lineSegments = makeLimitedLineSegmentFeatures(from: lineFeatures, budget: lineBudget)
        let output = selectedFeatures + lineSegments.features

        let visibleParcelNames = Set(lineSegments.features.filter { $0.labelRole == .parcel }.map { $0.name })
        let parcelLabelFeatures = makeParcelLabelFeatures(from: lineFeatures, visibleParcelNames: visibleParcelNames)

        let pointText = "点\(selectedPointsUsed)/\(totalPointCount)"
        let lineText = "線\(lineSegments.count)/\(totalLineCount)"
        let radiusText = effectiveDisplayRadiusMeters > 0 ? " / 半径\(Int(effectiveDisplayRadiusMeters))m" : ""
        let message = "表示：\(pointText)・\(lineText)\(radiusText)"
        return DisplayLimitResult(features: output, parcelLabelFeatures: parcelLabelFeatures, message: message, pointCount: selectedPointsUsed, lineCount: lineSegments.count, totalPointCount: totalPointCount, totalLineCount: totalLineCount)
    }


    private func makeParcelLabelFeatures(from source: [GeoFeature], visibleParcelNames: Set<String>) -> [GeoFeature] {
        guard settings.showLabels, settings.showLines, !visibleParcelNames.isEmpty else { return [] }

        var usedNames = Set<String>()
        var labels: [GeoFeature] = []

        for feature in source where feature.labelRole == .parcel && visibleParcelNames.contains(feature.name) && !usedNames.contains(feature.name) {
            guard let coord = parcelLabelCoordinate(for: feature) else { continue }
            labels.append(GeoFeature(name: feature.name, kind: .point, coordinates: [coord], labelRole: .parcel))
            usedNames.insert(feature.name)
        }

        return labels
    }

    private func parcelLabelCoordinate(for feature: GeoFeature) -> GeoCoordinate? {
        var coords = feature.coordinates
        guard coords.count >= 3, let localOrigin = coords.first else { return coords.first }

        if let first = coords.first, let last = coords.last, isSameCoordinate(first, last), coords.count > 3 {
            coords.removeLast()
        }

        let localPoints = coords.map { coord -> SIMD2<Double> in
            let meters = CoordinateConverter.enuMeters(from: coord, origin: localOrigin)
            return SIMD2<Double>(meters.east, meters.north)
        }

        let centroid = polygonCentroid(localPoints) ?? averagePoint(localPoints)
        let labelPoint: SIMD2<Double>

        if pointInPolygon(centroid, polygon: localPoints) {
            labelPoint = centroid
        } else if let candidate = interiorPointNearCentroid(localPoints, centroid: centroid) {
            labelPoint = candidate
        } else {
            labelPoint = averagePoint(localPoints)
        }

        let altitudeValues = coords.compactMap { validAltitudeValue($0.altitude) }
        let altitude = altitudeValues.isEmpty ? nil : altitudeValues.reduce(0, +) / Double(altitudeValues.count)
        var geo = CoordinateConverter.coordinate(fromEast: labelPoint.x, north: labelPoint.y, origin: localOrigin, name: feature.name)
        geo.altitude = altitude?.rounded()
        return geo
    }

    private func polygonCentroid(_ points: [SIMD2<Double>]) -> SIMD2<Double>? {
        guard points.count >= 3 else { return nil }
        var twiceArea = 0.0
        var cx = 0.0
        var cy = 0.0

        for index in points.indices {
            let p0 = points[index]
            let p1 = points[(index + 1) % points.count]
            let cross = p0.x * p1.y - p1.x * p0.y
            twiceArea += cross
            cx += (p0.x + p1.x) * cross
            cy += (p0.y + p1.y) * cross
        }

        guard abs(twiceArea) > 0.000001 else { return nil }
        return SIMD2<Double>(cx / (3.0 * twiceArea), cy / (3.0 * twiceArea))
    }

    private func averagePoint(_ points: [SIMD2<Double>]) -> SIMD2<Double> {
        guard !points.isEmpty else { return SIMD2<Double>(0, 0) }
        let sum = points.reduce(SIMD2<Double>(0, 0)) { $0 + $1 }
        return sum / Double(points.count)
    }

    private func interiorPointNearCentroid(_ points: [SIMD2<Double>], centroid: SIMD2<Double>) -> SIMD2<Double>? {
        guard points.count >= 3 else { return nil }
        let mean = averagePoint(points)

        var candidates: [SIMD2<Double>] = [mean]
        for i in 1..<(points.count - 1) {
            candidates.append((points[0] + points[i] + points[i + 1]) / 3.0)
        }
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            candidates.append((points[index] + next + centroid) / 3.0)
        }

        let inside = candidates.filter { pointInPolygon($0, polygon: points) }
        return inside.min { lhs, rhs in
            simd_length(lhs - centroid) < simd_length(rhs - centroid)
        }
    }

    private func pointInPolygon(_ point: SIMD2<Double>, polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1

        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            let intersects = ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / ((pj.y - pi.y) == 0 ? 0.0000001 : (pj.y - pi.y)) + pi.x)
            if intersects { inside.toggle() }
            j = i
        }

        return inside
    }

    private func filterByRadius(_ source: [GeoFeature]) -> [GeoFeature] {
        guard effectiveDisplayRadiusMeters > 0, let origin else { return source }
        return source.compactMap { feature in
            let coords = feature.coordinates.filter { coordinate in
                let meters = CoordinateConverter.enuMeters(from: coordinate, origin: origin)
                return hypot(meters.east, meters.north) <= effectiveDisplayRadiusMeters
            }
            if coords.isEmpty { return nil }
            switch feature.kind {
            case .point:
                return GeoFeature(name: feature.name, kind: feature.kind, coordinates: coords, labelRole: feature.labelRole)
            case .line:
                return coords.count >= 2 ? GeoFeature(name: feature.name, kind: feature.kind, coordinates: coords, labelRole: feature.labelRole) : nil
            case .polygon:
                return coords.count >= 3 ? GeoFeature(name: feature.name, kind: feature.kind, coordinates: coords, labelRole: feature.labelRole) : nil
            }
        }
    }

    private func limitPointFeatures(_ items: [(feature: GeoFeature, nearest: Double, count: Int)], budget: Int) -> (features: [GeoFeature], count: Int) {
        guard budget > 0 else { return ([], 0) }
        var remaining = budget
        var output: [GeoFeature] = []
        var count = 0
        for item in items where remaining > 0 {
            if item.count <= remaining {
                output.append(item.feature)
                count += item.count
                remaining -= item.count
            } else {
                let sorted = item.feature.coordinates.sorted { nearestDistanceMeters(for: [$0]) < nearestDistanceMeters(for: [$1]) }
                let coords = Array(sorted.prefix(remaining))
                output.append(GeoFeature(name: item.feature.name, kind: .point, coordinates: coords, labelRole: item.feature.labelRole))
                count += coords.count
                remaining = 0
            }
        }
        return (output, count)
    }

    private func totalLineSegmentCount(in lineFeatures: [GeoFeature]) -> Int {
        lineFeatures.reduce(0) { total, feature in
            switch feature.kind {
            case .line:
                return total + max(0, feature.coordinates.count - 1)
            case .polygon:
                return total + max(0, feature.coordinates.count)
            case .point:
                return total
            }
        }
    }

    private func makeLimitedLineSegmentFeatures(from source: [GeoFeature], budget: Int) -> (features: [GeoFeature], count: Int) {
        guard budget > 0 else { return ([], 0) }

        var segments: [(order: Int, feature: GeoFeature, nearest: Double)] = []
        var order = 0

        for feature in source {
            let coords = feature.coordinates
            guard coords.count >= 2 else { continue }

            for index in 0..<(coords.count - 1) {
                appendLineSegment(name: feature.name, labelRole: feature.labelRole, a: coords[index], b: coords[index + 1], order: &order, into: &segments)
            }

            if feature.kind == .polygon, coords.count >= 3, let first = coords.first, let last = coords.last, !isSameCoordinate(first, last) {
                appendLineSegment(name: feature.name, labelRole: feature.labelRole, a: last, b: first, order: &order, into: &segments)
            }
        }

        if origin != nil {
            segments.sort { lhs, rhs in
                if lhs.nearest == rhs.nearest { return lhs.order < rhs.order }
                return lhs.nearest < rhs.nearest
            }
        }

        let selected = Array(segments.prefix(budget))
        return (selected.map { $0.feature }, selected.count)
    }

    private func appendLineSegment(name: String, labelRole: GeoFeatureLabelRole, a: GeoCoordinate, b: GeoCoordinate, order: inout Int, into segments: inout [(order: Int, feature: GeoFeature, nearest: Double)]) {
        defer { order += 1 }

        if effectiveDisplayRadiusMeters > 0, let origin {
            let da = CoordinateConverter.enuMeters(from: a, origin: origin)
            let db = CoordinateConverter.enuMeters(from: b, origin: origin)
            let nearest = min(hypot(da.east, da.north), hypot(db.east, db.north))
            guard nearest <= effectiveDisplayRadiusMeters else { return }
            let feature = GeoFeature(name: name, kind: .line, coordinates: [a, b], labelRole: labelRole)
            segments.append((order, feature, nearest))
        } else {
            let feature = GeoFeature(name: name, kind: .line, coordinates: [a, b], labelRole: labelRole)
            segments.append((order, feature, nearestDistanceMeters(for: [a, b])))
        }
    }

    private func makeDisplayLimitCacheSignature() -> String {
        let featureCoordinateCount = features.reduce(0) { $0 + $1.coordinates.count }
        let firstFeatureID = features.first?.id.uuidString ?? "none"
        let lastFeatureID = features.last?.id.uuidString ?? "none"
        let originText: String
        if let origin {
            originText = "\(origin.latitude.rounded(toPlaces: 8)),\(origin.longitude.rounded(toPlaces: 8))"
        } else {
            originText = "no-origin"
        }
        let selectedText = selectedPoint?.id.uuidString ?? "no-selected"
        return [
            "f=\(features.count)",
            "c=\(featureCoordinateCount)",
            "first=\(firstFeatureID)",
            "last=\(lastFeatureID)",
            "o=\(originText)",
            "sel=\(selectedText)",
            "p=\(settings.showPoints)-\(settings.maxDisplayPoints)",
            "l=\(settings.showLines)-\(settings.maxDisplayLines)",
            "r=\(settings.displayRadiusMeters)-master\(settings.masterRangeScale)",
            "n=\(settings.showLabels)-\(settings.maxLabelCount)-\(settings.labelDistanceMeters)-master\(settings.masterRangeScale)"
        ].joined(separator: "|")
    }

    private func nearestDistanceMeters(for coords: [GeoCoordinate]) -> Double {
        guard let origin else { return 0 }
        return coords.map { coord in
            let m = CoordinateConverter.enuMeters(from: coord, origin: origin)
            return hypot(m.east, m.north)
        }.min() ?? Double.greatestFiniteMagnitude
    }

    private func isSameCoordinate(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Bool {
        if let an = a.name, let bn = b.name, an == bn { return true }
        return abs(a.latitude - b.latitude) < 0.0000001 && abs(a.longitude - b.longitude) < 0.0000001
    }

    private func horizontalDistance(_ position: SIMD3<Float>) -> Float {
        simd_length(SIMD2<Float>(position.x, position.z))
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private static func loadSettings(key: String) -> DisplaySettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var decoded = try? JSONDecoder().decode(DisplaySettings.self, from: data) else {
            return .defaults
        }
        decoded.clamp()
        return decoded
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
