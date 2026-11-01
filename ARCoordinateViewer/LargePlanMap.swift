import SwiftUI
import MapKit

struct DXFCoordinateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var system: Int
    @State private var scale = 1.0
    @State private var eastFirst = true
    let restoredReference: DXFImportOptions?
    var onApply: (DXFImportOptions) -> Void
    init(initialSystem: Int, restoredReference:DXFImportOptions? = nil, onApply: @escaping (DXFImportOptions) -> Void) {
        self.restoredReference=restoredReference
        _system = State(initialValue: restoredReference?.planeSystem ?? initialSystem)
        _scale = State(initialValue: restoredReference?.metersPerUnit ?? 1)
        _eastFirst = State(initialValue: restoredReference?.xIsEasting ?? true)
        self.onApply = onApply
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("水平座標") {
                    if restoredReference != nil { Text("書き出し時の座標設定を引き継いでいます。").font(.caption).foregroundStyle(.secondary) }
                    Picker("平面直角座標系", selection: $system) { ForEach(1...19, id: \.self) { Text("\($0)系").tag($0) } }
                    Picker("CADの座標軸", selection: $eastFirst) { Text("X＝東、Y＝北").tag(true); Text("X＝北、Y＝東").tag(false) }
                    Picker("図面の単位", selection: $scale) { Text("メートル").tag(1.0); Text("ミリメートル").tag(0.001); Text("センチメートル").tag(0.01) }
                        .accessibilityIdentifier("import.dxf.units")
                }
                Section("標高") {
                    Text("DEMを追加すると、CADのZ値に関係なくDEMの標高を優先します。水平位置は変えません。")
                    Text("ASCII DXFの点・線・ポリライン・円・円弧・文字位置・ブロック参照に対応。未対応要素は読み込み後にお知らせします。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("DXF読込")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("読み込む") { onApply(DXFImportOptions(planeSystem: system, metersPerUnit: scale, xIsEasting: eastFirst)); dismiss() } }
            }
        }
    }
}

/// 2DではARの点数制限を使わず、表示範囲で描画する。
struct LargePlanMap: UIViewRepresentable {
    var survey: SurveyOverlay?
    var showRasters: Bool
    var opacity: Double
    var showLabels: Bool
    var showPoints: Bool
    var showLines: Bool
    var showBasemap = true
    var isPreparing = false
    @Binding var tracking: MKUserTrackingMode
    var fitRequest: Int
    var onSelect: (GeoCoordinate) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = PlanMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = false
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance:10)
        let coordinator=context.coordinator
        map.onLayout = { [weak map,weak coordinator] in
            guard let map else { return }
            coordinator?.applyPendingFit(to:map)
        }
        map.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        updateMap(map,coordinator:context.coordinator)
    }
    func updateMap(_ map:MKMapView,coordinator c:Coordinator) {
        c.parent = self
        if c.displayedSurvey !== survey {
            if let previous=c.displayedSurvey { map.removeOverlay(previous) }
            c.displayedSurvey=survey
            c.needsFit=true
            if let overlay = survey, !overlay.boundingMapRect.isNull {
                map.addOverlay(overlay, level: .aboveLabels)
            }
        }
        if showBasemap, let blank=c.blankBasemap {
            map.removeOverlay(blank);c.blankBasemap=nil
        } else if !showBasemap, c.blankBasemap == nil {
            let blank=BlankBasemapOverlay()
            c.blankBasemap=blank
            map.insertOverlay(blank,at:0,level:.aboveRoads)
        }
        if c.fitRequest != fitRequest { c.needsFit=true }
        if c.requestedTracking != tracking {
            c.requestedTracking = tracking
            map.setUserTrackingMode(tracking, animated: true)
            if tracking == .follow { let camera = map.camera; camera.heading = 0; map.setCamera(camera, animated: true) }
        }
        c.applyPendingFit(to:map)
        for overlay in map.overlays {
            if let renderer = map.renderer(for: overlay) as? SurveyRenderer {
                if renderer.imageOpacity != opacity || renderer.labels != showLabels || renderer.showRasters != showRasters || renderer.showPoints != showPoints || renderer.showLines != showLines {
                    renderer.imageOpacity = opacity; renderer.labels = showLabels; renderer.showRasters = showRasters; renderer.showPoints = showPoints; renderer.showLines = showLines; renderer.setNeedsDisplay()
                }
            }
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LargePlanMap
        var displayedSurvey:SurveyOverlay?
        var blankBasemap:BlankBasemapOverlay?
        var needsFit = true
        var fitRequest = -1
        var requestedTracking: MKUserTrackingMode = .none
        init(_ parent: LargePlanMap) { self.parent = parent }
        func applyPendingFit(to map:MKMapView) {
            guard needsFit,!parent.isPreparing,map.bounds.width>0,map.bounds.height>0 else { return }
            guard let bounds=parent.survey?.fitRect(showPoints:parent.showPoints,showLines:parent.showLines,showRasters:parent.showRasters) else {
                needsFit=false;fitRequest=parent.fitRequest;return
            }
            // Consume the request only after the current data and view size exist.
            // A request made during an asynchronous import must survive its nil overlay.
            needsFit=false;fitRequest=parent.fitRequest
            if map.userTrackingMode != .none {
                map.setUserTrackingMode(.none,animated:false)
                DispatchQueue.main.async { [weak self] in self?.parent.tracking = .none }
            }
            map.setVisibleMapRect(bounds,edgePadding:UIEdgeInsets(top:76,left:24,bottom:24,right:24),animated:false)
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles=overlay as? BlankBasemapOverlay { return MKTileOverlayRenderer(tileOverlay:tiles) }
            let renderer = SurveyRenderer(overlay: overlay)
            renderer.imageOpacity = parent.opacity; renderer.labels = parent.showLabels; renderer.showRasters = parent.showRasters; renderer.showPoints = parent.showPoints; renderer.showLines = parent.showLines
            return renderer
        }
        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            requestedTracking = mode
            DispatchQueue.main.async { [weak self] in self?.parent.tracking = mode }
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let screen = gesture.location(in: map), coordinate = map.convert(screen, toCoordinateFrom: map)
            let point = MKMapPoint(coordinate)
            let radius = map.visibleMapRect.width / max(Double(map.bounds.width), 1) * 24
            let rect = MKMapRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2)
            let overlay = parent.survey
            var best: GeoCoordinate?, distance = 24.0
            for feature in overlay?.query(rect) ?? [] where (feature.kind == .point ? parent.showPoints : parent.showLines) { for c in feature.coordinates {
                let p = map.convert(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude), toPointTo: map)
                let d = hypot(p.x-screen.x, p.y-screen.y)
                if d < distance { distance = d; best = c }
            } }
            parent.onSelect(best ?? GeoCoordinate(name: "地図選択点", latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }
}

final class PlanMapView:MKMapView {
    var onLayout:(() -> Void)?
    override func layoutSubviews() { super.layoutSubviews();onLayout?() }
}

/// An opaque local tile replaces the Apple basemap. MapKit still owns the
/// geographic projection, zoom, pan and selection; survey overlays stay above it.
final class BlankBasemapOverlay:MKTileOverlay {
    private let tile:Data
    init() {
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
        tile=UIGraphicsImageRenderer(size:CGSize(width:256,height:256),format:format).image { context in
            UIColor.systemBackground.setFill();context.fill(CGRect(x:0,y:0,width:256,height:256))
        }.pngData()!
        super.init(urlTemplate:nil)
        canReplaceMapContent=true;minimumZ=0;maximumZ=30
    }
    override func loadTile(at path:MKTileOverlayPath,result:@escaping (Data?,Error?) -> Void) { result(tile,nil) }
}

final class SurveyOverlay: NSObject, MKOverlay {
    let features: [GeoFeature]
    let rasters: [GeoRaster]
    let boundingMapRect: MKMapRect
    private let pointBounds:MKMapRect
    private let lineBounds:MKMapRect
    private let rasterBounds:MKMapRect
    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }
    private let index: [Int64: [Int]]
    private let broad: [Int]
    private let featureBounds: [MKMapRect]
    private static let cell = 2048.0
    init(features: [GeoFeature], rasters: [GeoRaster]) {
        self.features = features; self.rasters = rasters
        var rects: [MKMapRect] = []
        var bounds = MKMapRect.null, buckets: [Int64: [Int]] = [:], broad: [Int] = []
        var points=MKMapRect.null,lines=MKMapRect.null,images=MKMapRect.null
        for (i,f) in features.enumerated() {
            let rect = Self.bounds(f.coordinates); rects.append(rect); bounds = bounds.union(rect)
            if f.kind == .point { points=points.union(rect) } else { lines=lines.union(rect) }
            let keys = Self.keys(rect)
            if keys.isEmpty { broad.append(i) } else { for k in keys { buckets[k, default: []].append(i) } }
        }
        for r in rasters { images=images.union(Self.bounds(r.corners)) }
        bounds=bounds.union(images)
        pointBounds=points;lineBounds=lines;rasterBounds=images
        boundingMapRect = bounds; index = buckets; self.broad = broad; featureBounds = rects
    }
    func fitRect(showPoints:Bool = true,showLines:Bool = true,showRasters:Bool = true) -> MKMapRect? {
        var bounds=MKMapRect.null
        if showPoints { bounds=bounds.union(pointBounds) }
        if showLines { bounds=bounds.union(lineBounds) }
        if showRasters { bounds=bounds.union(rasterBounds) }
        guard !bounds.isNull,bounds.width.isFinite,bounds.height.isFinite else { return nil }
        let center=MKMapPoint(x:bounds.midX,y:bounds.midY)
        let units=MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        guard units.isFinite,units>0 else { return nil }
        // MapKit can stop rendering both its basemap and overlays at sub-metre
        // extents. Keep a small local context in both background modes so toggling
        // the background preserves the viewport and short lines remain visible.
        let minimum=8.0*units
        let width=max(minimum,bounds.width*1.1),height=max(minimum,bounds.height*1.1)
        return MKMapRect(x:center.x-width/2,y:center.y-height/2,width:width,height:height)
    }
    static func bounds(_ coordinates: [GeoCoordinate]) -> MKMapRect {
        coordinates.reduce(MKMapRect.null) { rect, c in
            guard c.latitude.isFinite,c.longitude.isFinite,abs(c.latitude)<=85,abs(c.longitude)<=180 else { return rect }
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
            return rect.union(MKMapRect(x: p.x, y: p.y, width: 0.001, height: 0.001))
        }
    }
    private static func keys(_ r: MKMapRect) -> [Int64] {
        guard !r.isNull, r.minX.isFinite, r.minY.isFinite else { return [] }
        let x0 = Int64(floor(r.minX/cell)), x1 = Int64(floor(r.maxX/cell))
        let y0 = Int64(floor(r.minY/cell)), y1 = Int64(floor(r.maxY/cell))
        guard (x1-x0+1)*(y1-y0+1) <= 4096 else { return [] }
        return (x0...x1).flatMap { x in (y0...y1).map { (x << 32) ^ $0 } }
    }
    func query(_ rect: MKMapRect, minimumSpan: Double = 0, nearestTo center: MKMapPoint? = nil, maximumFeatures: Int? = nil) -> [GeoFeature] {
        let keys = Self.keys(rect)
        let candidates: [Int]
        if keys.isEmpty { candidates = Array(features.indices) }
        else { candidates = Array(Set(keys.flatMap { index[$0] ?? [] } + broad)).sorted() }
        var visible = candidates.filter { i in featureBounds[i].intersects(rect) && (features[i].kind == .point || max(featureBounds[i].width, featureBounds[i].height) >= minimumSpan) }
        if let center, let maximumFeatures {
            func distance(_ i: Int) -> Double {
                let r = featureBounds[i]
                return hypot(max(0,max(r.minX-center.x,center.x-r.maxX)),max(0,max(r.minY-center.y,center.y-r.maxY)))
            }
            visible.sort { a,b in let da=distance(a),db=distance(b); return da == db ? a<b : da<db }
            return visible.prefix(maximumFeatures).map { features[$0] }
        }
        return visible.map { features[$0] }
    }
}

final class SurveyRenderer: MKOverlayRenderer {
    var imageOpacity = 0.35
    var labels = true
    var showRasters = true
    var showPoints = true
    var showLines = true
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let survey = overlay as? SurveyOverlay else { return }
        let scale = max(zoomScale, 1e-9)
        context.saveGState(); defer { context.restoreGState() }
        for raster in survey.rasters where showRasters && SurveyOverlay.bounds(raster.corners).intersects(mapRect) {
            guard let store = raster.tileStore else { drawImage(raster.image, corners: raster.corners, context: context); continue }
            let bounds = SurveyOverlay.bounds(raster.corners)
            let screenWidth = max(bounds.width * scale * Double(UIScreen.main.scale), 1)
            let ratio = Double(raster.sourcePixelWidth) / screenWidth
            let level = max(0, min(store.levels.count-1, Int(floor(log2(max(1,ratio))))))
            // まず軽い全体像を描き、その上へ必要な原寸タイルを載せる。
            for tile in store.tiles(level: level) where SurveyOverlay.bounds(tile.corners).intersects(mapRect) {
                if let image = RasterTileImages.shared.image(tile.url, onReady: { [weak self] in self?.setNeedsDisplay(mapRect) }) ?? store.preview(tile: tile, image: raster.image) {
                    drawImage(image, corners: tile.corners, context: context)
                }
            }
        }
        context.setStrokeColor(UIColor.cyan.cgColor); context.setFillColor(UIColor.systemYellow.cgColor)
        context.setLineWidth(1.4 / scale)
        var occupied: [CGRect] = []
        for feature in survey.query(mapRect, minimumSpan: 1.2 / scale) {
            guard feature.kind == .point ? showPoints : showLines else { continue }
            context.setStrokeColor((feature.sourceColor?.uiColor ?? UIColor.cyan).cgColor)
            context.setFillColor((feature.sourceColor?.uiColor ?? UIColor.systemYellow).cgColor)
            let points = feature.coordinates.map { point(for: MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))) }
            guard let first = points.first else { continue }
            if feature.kind == .point {
                let r = 3 / scale
                context.fillEllipse(in: CGRect(x: first.x-r,y: first.y-r,width: r*2,height: r*2))
                if labels {
                    let labelRect = CGRect(x: first.x + 5/scale, y: first.y - 14/scale, width: CGFloat(min(220, feature.name.count*13+10))/scale, height: 18/scale)
                    if !occupied.contains(where: { $0.intersects(labelRect) }) {
                        occupied.append(labelRect)
                        UIGraphicsPushContext(context)
                        (feature.name as NSString).draw(in: labelRect, withAttributes: [.font: UIFont.systemFont(ofSize: 12/scale), .foregroundColor: UIColor.label, .backgroundColor: UIColor.systemBackground.withAlphaComponent(0.8)])
                        UIGraphicsPopContext()
                    }
                }
            } else {
                context.setLineWidth(1.4 / scale)
                context.beginPath(); context.move(to: first)
                for p in points.dropFirst() { context.addLine(to: p) }
                if feature.kind == .polygon { context.closePath() }
                context.strokePath()
            }
        }
    }
    private func drawImage(_ image: UIImage, corners: [GeoCoordinate], context: CGContext) {
        guard corners.count == 4, let cg = image.cgImage else { return }
        let points = corners.map { point(for: MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))) }
        let a = points[0], b = points[1], d = points[3]
        context.saveGState(); defer { context.restoreGState() }
        context.setAlpha(imageOpacity)
        context.concatenate(CGAffineTransform(a: b.x-a.x, b: b.y-a.y, c: d.x-a.x, d: d.y-a.y, tx: a.x, ty: a.y))
        context.translateBy(x: 0, y: 1); context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0,y: 0,width: 1,height: 1))
    }
}
