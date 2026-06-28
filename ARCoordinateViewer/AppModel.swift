import Foundation
import CoreLocation
import simd

@MainActor
final class AppModel: ObservableObject {
    @Published var layers: [ImportedDataLayer] = []
    @Published var features: [GeoFeature] = []
    @Published var importedPointList: [GeoCoordinate] = []
    @Published var origin: GeoCoordinate?
    @Published var selectedPoint: GeoCoordinate?
    @Published var headingOffsetDegrees: Double = 0
    @Published var displayPlaneOffsetMeters: Double = -1.0
    @Published var planePanEastMeters: Double = 0
    @Published var planePanNorthMeters: Double = 0
    @Published var pillarsEnabled: Bool = false
    @Published var rastersEnabled: Bool = true
    @Published var distancesEnabled: Bool = false
    @Published var lidarEnabled: Bool = false
    @Published var lidarSupported: Bool = false
    @Published var arCameraActive: Bool = true
    @Published var screenLabels: [ScreenLabel] = []
    @Published var rasters: [GeoRaster] = []
    @Published var statusMessage: String = "KML / KMZ / CSV / SIMA / GeoTIFFを読み込んでください。"
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
    private let settingsKey = "ARCoordinateViewer.DisplaySettings.v33"
    private struct ParsedImportResult {
        var name: String
        var features: [GeoFeature]
        var points: [GeoCoordinate]
        var rasters: [GeoRaster]
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

    private let altitudeGridCellSizeMeters: Double = 25
    private let altitudeNearestSearchMaxRings: Int = 8
    private let altitudeExactSearchLimit: Int = 2000
    private var altitudeReferenceCache: [AltitudeReference] = []
    private var altitudeGridOrigin: GeoCoordinate?
    private var altitudeGrid: [AltitudeGridKey: [Int]] = [:]
    private var altitudeBaselineCache: Double?
    
    init() {
        settings = Self.loadSettings(key: settingsKey)
    }

    func importFile(url: URL) {
        importFileAsync(url: url)
    }

    func importFileAsync(url: URL) {
        let fileName = url.lastPathComponent
        let planeSystem = planeSystemNumber
        statusMessage = "読込中：\(fileName)"

        DispatchQueue.global(qos: .userInitiated).async {
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                let result: ParsedImportResult

                if ext == "kml" {
                    let parsed = try KMLParser.parse(data: data)
                    result = ParsedImportResult(
                        name: fileName,
                        features: parsed,
                        points: Self.pointsForVectorFeaturesStatic(parsed),
                        rasters: [],
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
                            statusMessage: "CSV読込：\(fileName) / \(parseResult.points.count)点",
                            planeSystemNumber: nil,
                            enableRasters: false
                        )
                    }
                }

                Task { @MainActor in
                    self.applyParsedImport(result)
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "読込エラー：\(error.localizedDescription)"
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
        addLayer(name: result.name, features: result.features, points: result.points, rasters: result.rasters)
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

    private func addLayer(name: String, features: [GeoFeature], points: [GeoCoordinate], rasters: [GeoRaster]) {
        let normalized = normalizeAltitudesAtImport(features: features, points: points)
        layers.append(ImportedDataLayer(name: name, features: normalized.features, points: normalized.points, rasters: rasters, isVisible: true))
        selectedPoint = nil
        rebuildVisibleData()
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
        resetHorizontalPan()
        origin = GeoCoordinate(
            name: "iOS現在地",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: nil
        )
        statusMessage = "現在地を更新：\(location.coordinate.latitude.formatted(.number.precision(.fractionLength(7)))), \(location.coordinate.longitude.formatted(.number.precision(.fractionLength(7))))"
    }

    func setOrigin(latitude: Double, longitude: Double) {
        resetHorizontalPan()
        origin = GeoCoordinate(name: "手入力", latitude: latitude, longitude: longitude, altitude: nil)
        statusMessage = "現在地を手入力で設定"
    }

    func setOriginFromPlane(system: Int, x: Double, y: Double) {
        do {
            let geo = try JapanesePlaneRectangularSystem.toGeodetic(system: system, x: x, y: y)
            resetHorizontalPan()
            origin = GeoCoordinate(name: "平面直角\(system)系", latitude: geo.latitude, longitude: geo.longitude, altitude: nil)
            planeSystemNumber = system
            statusMessage = "現在地を平面直角座標で設定：\(system)系"
        } catch {
            statusMessage = "平面直角座標変換エラー：\(error.localizedDescription)"
        }
    }

    func setOriginFromPoint(_ point: GeoCoordinate) {
        resetHorizontalPan()
        origin = GeoCoordinate(name: point.name ?? "CSV選択点", latitude: point.latitude, longitude: point.longitude, altitude: nil)
        statusMessage = "現在地を選択点に設定：\(point.name ?? "名称なし")"
    }

    func selectPointForAR(_ point: GeoCoordinate, centerInView: Bool = false) {
        selectedPoint = point

        if centerInView {
            if centerPointInAR(point) {
                statusMessage = "AR中心へ移動：\(point.name ?? "名称なし")"
            }
        } else {
            statusMessage = "AR強調点：\(point.name ?? "名称なし")"
        }
    }

    func centerSelectedPointInAR() {
        guard let selectedPoint else {
            statusMessage = "中心移動する点が選択されていません"
            return
        }
        if centerPointInAR(selectedPoint) {
            statusMessage = "AR中心へ移動：\(selectedPoint.name ?? "名称なし")"
        }
    }

    @discardableResult
    private func centerPointInAR(_ point: GeoCoordinate) -> Bool {
        guard let origin else {
            statusMessage = "現在地を設定してから中心移動してください"
            return false
        }

        let enu = CoordinateConverter.enuMeters(from: point, origin: origin)
        // Render entities are kept in unrotated ENU space and the AR root entity applies heading.
        // Therefore the pan needed to bring a point to the screen/world center is the negative
        // of the point's local ENU position, regardless of the current heading angle.
        planePanEastMeters = -enu.east
        planePanNorthMeters = -enu.north
        return true
    }

    func resetScreenAdjustments() {
        headingOffsetDegrees = 0
        displayPlaneOffsetMeters = -1.0
        resetHorizontalPan()
        distancesEnabled = false
    }

    func resetHorizontalPan() {
        planePanEastMeters = 0
        planePanNorthMeters = 0
    }

    func resetHeadingOffset() {
        headingOffsetDegrees = 0
    }

    func resetDisplaySettings() {
        settings = .defaults
    }


    func importCSV(text: String, fileName: String, mapping: CSVColumnMapping) {
        importCSVAsync(text: text, fileName: fileName, mapping: mapping)
    }

    func importCSVAsync(text: String, fileName: String, mapping: CSVColumnMapping) {
        var safeMapping = mapping
        safeMapping.planeSystemNumber = Swift.max(1, Swift.min(safeMapping.planeSystemNumber, 19))
        statusMessage = "CSV読込中：\(fileName)"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let parseResult = try CSVParser.parse(text: text, mapping: safeMapping)
                let result = ParsedImportResult(
                    name: fileName,
                    features: parseResult.features,
                    points: parseResult.points,
                    rasters: [],
                    statusMessage: "CSV読込：\(fileName) / \(parseResult.points.count)点",
                    planeSystemNumber: safeMapping.coordinateKind == .planeXY ? safeMapping.planeSystemNumber : nil,
                    enableRasters: false
                )
                Task { @MainActor in
                    self.applyParsedImport(result)
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "CSV読込エラー：\(error.localizedDescription)"
                }
            }
        }
    }

    func importGeoTIFF(data: Data, fileName: String, coordinateMode: GeoTIFFCoordinateMode) {
        importGeoTIFFAsync(data: data, fileName: fileName, coordinateMode: coordinateMode)
    }

    func importGeoTIFFAsync(data: Data, fileName: String, coordinateMode: GeoTIFFCoordinateMode) {
        statusMessage = "GeoTIFF読込中：\(fileName)"

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
                    statusMessage: "GeoTIFF読込：\(coordinateMode.description) / \(raster.renderedPixelWidth)x\(raster.renderedPixelHeight) / \(raster.notes)",
                    planeSystemNumber: planeSystem,
                    enableRasters: true
                )
                Task { @MainActor in
                    self.applyParsedImport(result)
                }
            } catch {
                Task { @MainActor in
                    self.statusMessage = "GeoTIFF読込エラー：\(error.localizedDescription)"
                }
            }
        }
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
        RenderStyle(
            pointRadius: Float(settings.arPointSize),
            selectedPointRadius: Float(settings.arSelectedSphereSize),
            lineRadius: Float(settings.arLineWidth),
            farMinimumSizeEnabled: settings.farMinimumSizeEnabled,
            farPointMinRadius: Float(settings.farPointMinSize),
            farLineMinRadius: Float(settings.farLineMinWidth),
            rasterOpacity: Float(settings.rasterOpacity)
        )
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
            "labels=\(settings.showLabels)-\(settings.maxLabelCount)-\(settings.labelDistanceMeters)",
            "size=\(settings.arPointSize)-\(settings.arSelectedSphereSize)-\(settings.arLineWidth)",
            "limit=\(limit.pointCount)-\(limit.lineCount)-pLabel\(limit.parcelLabelFeatures.count)"
        ].joined(separator: "|")
    }

    private func makeSelectedRenderPosition(altitudeBaseline: Double?) -> SIMD3<Float>? {
        guard let origin, let selectedPoint else { return nil }
        return CoordinateConverter.localARPosition(
            from: selectedPoint,
            origin: origin,
            headingOffsetDegrees: 0,
            verticalOffsetMeters: relativeHeightMeters(for: selectedPoint, baseline: altitudeBaseline)
        )
    }

    private func makeRenderLabels(
        from renderFeatures: [RenderFeature],
        parcelLabelFeatures: [GeoFeature],
        selectedPosition: SIMD3<Float>?,
        altitudeBaseline: Double?
    ) -> [RenderLabel] {
        let pointLabelOffset = Float(max(settings.arPointSize * 1.25 + 0.04, 0.055))
        let parcelLabelOffset = Float(max(settings.arLineWidth * 2.0 + 0.03, 0.04))
        let selectedLabelOffset = Float(max(settings.arSelectedSphereSize * 1.15 + 0.06, 0.12))

        guard settings.showLabels else {
            if let selected = selectedPosition, let selectedPoint {
                return [RenderLabel(id: selectedPoint.id, text: selectedPoint.name ?? "選択点", position: selected + SIMD3<Float>(0, selectedLabelOffset, 0), distance: horizontalDistance(selected), labelRole: .point, isSelected: true, screenYOffset: 26)]
            }
            return []
        }

        var labels: [RenderLabel] = []

        // 点名だけを表示する。ライン名は表示しない。
        for feature in renderFeatures where feature.kind == .point {
            for position in feature.positions {
                let distance = horizontalDistance(position)
                if settings.labelDistanceMeters <= 0 || Double(distance) <= settings.labelDistanceMeters {
                    labels.append(RenderLabel(id: UUID(), text: feature.name, position: position + SIMD3<Float>(0, pointLabelOffset, 0), distance: distance, labelRole: .point, screenYOffset: 20))
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
                    verticalOffsetMeters: relativeHeightMeters(for: coord, baseline: altitudeBaseline)
                )
                let distance = horizontalDistance(position)
                if settings.labelDistanceMeters <= 0 || Double(distance) <= settings.labelDistanceMeters {
                    labels.append(RenderLabel(id: feature.id, text: feature.name, position: position + SIMD3<Float>(0, parcelLabelOffset, 0), distance: distance, labelRole: .parcel, screenYOffset: 0))
                }
            }
        }

        if let selected = selectedPosition, let selectedPoint {
            labels.append(RenderLabel(id: selectedPoint.id, text: "選択：\(selectedPoint.name ?? "名称なし")", position: selected + SIMD3<Float>(0, selectedLabelOffset, 0), distance: horizontalDistance(selected), labelRole: .point, isSelected: true, screenYOffset: 26))
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
        guard settings.useRelativeAltitude else { return 0 }
        guard let baseline else { return 0 }
        guard let altitude = validAltitudeValue(coord.altitude) else { return 0 }

        // 標高0・欠損値の補完は読み込み時に完了させる。
        // AR表示中は近傍検索を行わず、座標に保持済みの概略標高だけを使う。
        // 現場確認用なので1m単位へ丸め、過剰な微小差で再描画が増えないようにする。
        var height = (altitude - baseline).rounded()
        if settings.relativeAltitudeLimitMeters > 0 {
            height = max(-settings.relativeAltitudeLimitMeters, min(settings.relativeAltitudeLimitMeters, height))
        }
        return height
    }

    private func relativeAltitudeBaseline() -> Double? {
        guard settings.useRelativeAltitude, let origin else { return nil }
        rebuildAltitudeCacheIfNeeded()
        guard !altitudeReferenceCache.isEmpty else { return nil }
        if let cached = altitudeBaselineCache { return cached }

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
        return "f=\(features.count)|c=\(featureCoordinateCount)|first=\(firstFeatureID)|last=\(lastFeatureID)|o=\(originText)"
    }

    private func makeRenderRasters() -> [RenderRaster] {
        guard let origin, rastersEnabled else { return [] }
        return rasters.prefix(maxRasterCount).map { raster in
            let positions = raster.corners.map { coord in
                CoordinateConverter.localARPosition(
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
        return limited.map { feature in
            let positions = feature.coordinates.map { coord in
                CoordinateConverter.localARPosition(
                    from: coord,
                    origin: origin,
                    headingOffsetDegrees: 0,
                    verticalOffsetMeters: relativeHeightMeters(for: coord, baseline: altitudeBaseline)
                )
            }
            return RenderFeature(id: feature.id, name: feature.name, kind: feature.kind, positions: positions, labelRole: feature.labelRole)
        }
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
        let radiusText = settings.displayRadiusMeters > 0 ? " / 半径\(Int(settings.displayRadiusMeters))m" : ""
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
        guard settings.displayRadiusMeters > 0, let origin else { return source }
        return source.compactMap { feature in
            let coords = feature.coordinates.filter { coordinate in
                let meters = CoordinateConverter.enuMeters(from: coordinate, origin: origin)
                return hypot(meters.east, meters.north) <= settings.displayRadiusMeters
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

        if settings.displayRadiusMeters > 0, let origin {
            let da = CoordinateConverter.enuMeters(from: a, origin: origin)
            let db = CoordinateConverter.enuMeters(from: b, origin: origin)
            let nearest = min(hypot(da.east, da.north), hypot(db.east, db.north))
            guard nearest <= settings.displayRadiusMeters else { return }
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
            "r=\(settings.displayRadiusMeters)",
            "n=\(settings.showLabels)-\(settings.maxLabelCount)-\(settings.labelDistanceMeters)"
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

