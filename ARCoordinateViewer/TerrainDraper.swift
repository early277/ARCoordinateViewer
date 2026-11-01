import Foundation
import simd

/// 表示範囲内だけをバックグラウンドで標高サンプリングする。
/// 元の各線分を独立して処理するため、角・折れ点のXYは間引かれない。
enum TerrainDraper {
    struct Result { var features: [RenderFeature]; var missingSamples: Int; var deferredSegments: Int }
    static func interpolate(_ a: GeoCoordinate, _ b: GeoCoordinate, t: Double) -> GeoCoordinate {
        if t <= 0 { return a }; if t >= 1 { return b }
        if let system = a.planeSystem, system == b.planeSystem,
           let ax = a.planeNorth, let ay = a.planeEast, let bx = b.planeNorth, let by = b.planeEast,
           var c = try? JapanesePlaneRectangularSystem.toGeodetic(system: system, x: ax+(bx-ax)*t, y: ay+(by-ay)*t) {
            c.planeSystem = system; c.planeNorth = ax+(bx-ax)*t; c.planeEast = ay+(by-ay)*t
            return c
        }
        return GeoCoordinate(latitude: a.latitude+(b.latitude-a.latitude)*t, longitude: a.longitude+(b.longitude-a.longitude)*t)
    }
    static func render(features: [GeoFeature], origin: GeoCoordinate, grids: [ElevationGrid], baseline: Double?, heightLimit: Double, radius: Double, cancelled: () -> Bool) -> Result {
        var result = Result(features: [], missingSamples: 0, deferredSegments: 0)
        guard let baseline else { result.missingSamples = features.count; return result }
        let cell = max(0.25, grids.map(\.estimatedCellSizeMeters).filter { $0 > 0 }.min() ?? 5)
        var probes = 0
        var renderedSegments = 0
        // 上限に達したら遠方を後回しにする。近い線の品質を全体的に落とさない。
        let budget = 250_000
        func position(_ c: GeoCoordinate) -> SIMD3<Float>? {
            probes += 1
            guard let z = grids.lazy.compactMap({ $0.elevation(at: c) }).first else { result.missingSamples += 1; return nil }
            let height = z-baseline
            let y = heightLimit > 0 ? max(-heightLimit,min(heightLimit,height)) : height
            return CoordinateConverter.localARPosition(from: c, origin: origin, headingOffsetDegrees: 0, verticalOffsetMeters: y)
        }
        func simplify(_ p: [SIMD3<Float>]) -> [Int] {
            guard p.count > 2 else { return Array(p.indices) }
            var keep: Set<Int> = [0,p.count-1], stack = [(0,p.count-1)]
            var comparisons = 0
            while let (a,b) = stack.popLast() {
                if cancelled() { return [] }
                if comparisons > 2_000_000 { for (a,b) in stack { keep.formUnion(a...b) }; keep.formUnion(a...b); break }
                guard b > a+1 else { continue }
                var error: Float = 0.05, split: Int?
                let dx = p[b].x-p[a].x, dz = p[b].z-p[a].z, length2 = dx*dx+dz*dz
                for i in (a+1)..<b {
                    comparisons += 1
                    let t = length2 > 0 ? ((p[i].x-p[a].x)*dx+(p[i].z-p[a].z)*dz)/length2 : 0
                    let e = abs(p[i].y-(p[a].y+(p[b].y-p[a].y)*t))
                    if e > error { error = e; split = i }
                }
                if let i = split { keep.insert(i); stack.append((a,i)); stack.append((i,b)) }
            }
            return keep.sorted()
        }
        for feature in features {
            if cancelled() { return result }
            if feature.kind == .point {
                var p:[SIMD3<Float>]=[], heights:[Double?]=[]
                for c in feature.coordinates { if let point=position(c) { p.append(point); heights.append(c.drawingSourceAltitude) } }
                if !p.isEmpty { result.features.append(RenderFeature(id: feature.id,name: feature.name,kind: .point,positions: p,labelRole: feature.labelRole,sourceColor: feature.sourceColor,sourceAltitudes:heights)) }
                continue
            }
            var coords = feature.coordinates
            if feature.kind == .polygon, let first = coords.first { coords.append(first) }
            guard coords.count > 1 else { continue }
            for i in 0..<(coords.count-1) {
                if probes >= budget || renderedSegments >= 40_000 { result.deferredSegments += 1; continue }
                let a = coords[i], b = coords[i+1]
                let av = CoordinateConverter.enuMeters(from: a,origin: origin), bv = CoordinateConverter.enuMeters(from: b,origin: origin)
                let dx = bv.east-av.east, dy = bv.north-av.north
                var low = 0.0, high = 1.0
                // 表示領域の外に延びる長い線の不要なサンプリングを避ける。
                let r = radius > 0 ? radius : 1000
                for (start,delta) in [(av.east,dx),(av.north,dy)] {
                    if abs(delta) < 1e-12 { if abs(start) > r { low = 1; high = 0 } }
                    else { let t0 = (-r-start)/delta, t1 = (r-start)/delta; low = max(low,min(t0,t1)); high = min(high,max(t0,t1)) }
                }
                guard high >= low else { continue }
                let length = hypot(dx,dy)*(high-low)
                let steps = max(1,Int(ceil(length/cell)))
                if probes + steps + 1 > budget { result.deferredSegments += 1; continue }
                var run: [SIMD3<Float>] = []
                var runHeights:[Double?] = []
                func flush() {
                    if run.count >= 2 {
                        let indices = simplify(run)
                        let reduced = indices.map { run[$0] }
                        if renderedSegments + max(0,reduced.count-1) <= 40_000 {
                            renderedSegments += max(0,reduced.count-1)
                            result.features.append(RenderFeature(id: UUID(),name: feature.name,kind: .line,positions: reduced,labelRole: feature.labelRole,pillarPositions: [run[0],run[run.count-1]],sourceColor: feature.sourceColor,sourceAltitudes:indices.map { runHeights[$0] },pillarSourceAltitudes:[runHeights[0],runHeights[runHeights.count-1]]))
                        } else { result.deferredSegments += 1 }
                    }
                    run.removeAll(keepingCapacity: true)
                    runHeights.removeAll(keepingCapacity:true)
                }
                for step in 0...steps {
                    if step % 128 == 0 && cancelled() { return result }
                    let t = low + (high-low)*Double(step)/Double(steps)
                    let c = interpolate(a,b,t: t)
                    if let p = position(c) {
                        run.append(p)
                        if t == 0 { runHeights.append(a.drawingSourceAltitude) }
                        else if t == 1 { runHeights.append(b.drawingSourceAltitude) }
                        else if let za=a.drawingSourceAltitude, let zb=b.drawingSourceAltitude { runHeights.append(za+(zb-za)*t) }
                        else { runHeights.append(nil) }
                    } else { flush() }
                }
                flush()
            }
        }
        return result
    }
}
