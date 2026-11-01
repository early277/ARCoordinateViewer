import Foundation
import simd

enum TreeColor: String, Codable, CaseIterable {
    case red, yellow, white, blue, pink, cyan
    var title: String {
        switch self {
        case .red: return "赤"
        case .yellow: return "黄色"
        case .white: return "白"
        case .blue: return "青"
        case .pink: return "ピンク"
        case .cyan: return "水色"
        }
    }
}

/// Fixed survey ENU, metres. This is never mutated by the display root transform.
struct TreePoint: Codable, Equatable {
    var east: Double
    var north: Double
    var up: Double
    var finite: Bool { east.isFinite && north.isFinite && up.isFinite }
    var vector: SIMD3<Double> { SIMD3(east,north,up) }
    init(east: Double, north: Double, up: Double) { self.east=east;self.north=north;self.up=up }
}
struct TreeGeoOrigin: Codable, Equatable {
    var latitude: Double
    var longitude: Double
}
struct TreeSurveyFrame: Codable, Equatable, Identifiable {
    var id = UUID()
    var created = Date()
    var origin: TreeGeoOrigin?
    var verticalDatum: Double?
    var description: String {
        let horizontal = origin.map { "開始原点 緯度\($0.latitude) 経度\($0.longitude)" } ?? "開始時のローカル原点"
        let vertical = verticalDatum.map { "相対Zの基準 \($0)m" } ?? "開始時の表示平面を相対Z=0"
        return "\(horizontal); X=東,Y=北,Z=上; \(vertical); 座標m,直径cm,樹高m"
    }
}
struct TreeCircle: Codable, Equatable {
    var center: TreePoint
    var radius: Double
    var diameter: Double { radius*2 }
}
struct TreeHeight: Codable, Equatable {
    var base: TreePoint
    var top: TreePoint
    var metres: Double { top.up-base.up }
    var valid: Bool { base.finite && top.finite && metres.isFinite && metres>0 && metres<100 }
}
enum TreePointSource: String, Codable { case lidar, twoRays }
struct TreeGeometry: Codable, Equatable {
    var frameID: UUID
    var circle: TreeCircle
    var surface: [TreePoint]
    var sources: [TreePointSource]
    var height: TreeHeight?
    var cylinder: TreeCylinderObservation? = nil
}
struct TreeRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var created = Date()
    var creationOrder = 0
    var color: TreeColor
    var number: Int
    var geometry: TreeGeometry
    /// Missing in older records. An empty name is never a measured classification.
    var species: String? = nil
    /// The latest confirmed MRU travels in the same durable pair as its record.
    /// Keeping a snapshot preserves earlier names even after a metadata edit.
    var speciesHistory: TreeSpeciesHistory? = nil
}
struct TreeSpeciesHistory: Codable, Equatable {
    var sequence: Int
    var names: [String]
}
enum TreeSpecies {
    static let recentLimit = 10
    static func name(_ input: String?) -> String? {
        guard let input else {return nil}
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return value.isEmpty ? nil:value
    }
    static func recent(_ inputs: [String]) -> [String] {
        var result:[String]=[],seen=Set<String>()
        for input in inputs {
            if let value=name(input),seen.insert(value).inserted {result.append(value)}
            if result.count==recentLimit {break}
        }
        return result
    }
}
struct TreeDraft: Codable, Equatable {
    var record: TreeRecord?
    var numberInput: String
    var color: TreeColor
    var discarded = false
}
enum TreeRecordChangeKind:String,Codable {case delete,restore}
/// A mirrored, append-only disposition operation. Original tree files are never removed.
struct TreeRecordChange:Codable,Equatable,Identifiable {
    var id=UUID()
    var frameID:UUID
    var created=Date()
    var sequence=0
    var kind:TreeRecordChangeKind
    var recordIDs:[UUID]
}
struct TreeSurveyFailure: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message=message }
}

/// Historical direction in the fixed survey ENU frame; every observation keeps its own camera position.
struct TreeSightRay: Codable, Equatable {
    var origin: TreePoint
    var direction: TreePoint
    var unit: SIMD3<Double>? {
        let v=direction.vector,n=simd_length(v)
        guard origin.finite,direction.finite,n.isFinite,n>0.999,n<1.001 else {return nil}
        return v/n
    }
}
enum TreeHeightMethod:String,Codable {case elevationDistance}

enum TreeCaptureStyle {
    static let scale:Float = 1.0/3.0
    static let directionRadius:Float = 0.004*scale
    static let observationRadius:Float = 0.008*scale
}
struct TreeCylinderObservation: Codable, Equatable {
    var surface: TreePoint
    var surfaceRay: TreeSightRay
    var source: TreePointSource
    var left: TreeSightRay
    var right: TreeSightRay
    var bottom: TreeSightRay?
    var top: TreeSightRay?
    /// Absent in build47 and earlier: retain their original stored-height calculation.
    var heightMethod:TreeHeightMethod? = nil
}

enum TreeCylinderMath {
    /// Two signed tangent lines plus |axis - surface| = radius.
    /// The initial point is required to be visible, but is not fixed to the exact nearest point.
    static func circle(_ observation: TreeCylinderObservation) throws -> TreeCircle {
        let p=observation.surface
        guard p.finite,let initial=observation.surfaceRay.unit else {throw TreeSurveyFailure("正面表面の観測を取り直してください")}
        let delta=p.vector-observation.surfaceRay.origin.vector
        let along=simd_dot(delta,initial)
        guard along>0.15,along<100,simd_length(delta-along*initial)<0.08 else {throw TreeSurveyFailure("表面点と最初の照準が一致しません")}
        let ph=SIMD2(p.east,p.north)
        func line(_ ray:TreeSightRay) throws -> (SIMD2<Double>,SIMD2<Double>,SIMD2<Double>) {
            guard let direction=ray.unit else {throw TreeSurveyFailure("方向を確認できません。端を取り直してください")}
            let h=SIMD2(direction.x,direction.y),length=simd_length(h)
            guard length>0.02 else {throw TreeSurveyFailure("左右端は幹の横方向を狙ってください")}
            let u=h/length,o=SIMD2(ray.origin.east,ray.origin.north)-ph
            var n=SIMD2(-u.y,u.x)
            if simd_dot(n,-o)<0 {n = -n}
            guard simd_dot(n,-o)>0.0002 else {throw TreeSurveyFailure("正面表面と端が重なっています。左右端を取り直してください")}
            return (o,u,n)
        }
        let l=try line(observation.left),r=try line(observation.right)
        let determinant=l.2.x*r.2.y-l.2.y*r.2.x
        guard abs(determinant)>0.0001 else {throw TreeSurveyFailure("左右の方向が平行に近く、直径が不安定です。近づいて取り直してください")}
        func solve(_ b:SIMD2<Double>)->SIMD2<Double> {
            SIMD2((b.x*r.2.y-l.2.y*b.y)/determinant,(l.2.x*b.y-b.x*r.2.x)/determinant)
        }
        let a=solve(SIMD2(simd_dot(l.2,l.0),simd_dot(r.2,r.0))),v=solve(SIMD2(1,1))
        let A=simd_length_squared(v)-1,B=2*simd_dot(a,v),C=simd_length_squared(a)
        var radii:[Double]=[]
        if abs(A)<1e-10 {
            if abs(B)>1e-10 {radii=[-C/B]}
        } else {
            let discriminant=B*B-4*A*C,tolerance=1e-12*max(1,B*B+abs(4*A*C))
            guard discriminant >= -tolerance else {throw TreeSurveyFailure("左右端と表面点が円柱に一致しません。端を取り直してください")}
            let q = -0.5*(B+(B>=0 ? 1.0 : -1.0)*sqrt(max(0,discriminant)))
            if abs(q)>1e-14 {radii=[q/A,C/q]}
        }
        let initialOrigin=SIMD2(observation.surfaceRay.origin.east,observation.surfaceRay.origin.north)-ph
        var solutions:[(Double,SIMD2<Double>,Double)]=[]
        for radius in radii where radius.isFinite && radius>=0.015 && radius<=1.5 {
            let center=a+radius*v
            guard center.x.isFinite,center.y.isFinite else {continue}
            let frontness=simd_dot(-center,initialOrigin)/(radius*simd_length(initialOrigin))
            // Visible front hemisphere, allowing an approximately central bark point.
            guard frontness>0.05,simd_length(initialOrigin-center)>radius+0.02 else {continue}
            let valid=[l,r].allSatisfy {line in
                let t=simd_dot(center-line.0,line.1)
                return t>0.02 && t<100 && simd_length(center-line.0)>radius+0.02 && abs(simd_dot(line.2,center-line.0)-radius)<1e-6
            }
            if valid,abs(simd_length(center)-radius)<1e-6 {solutions.append((radius,center,frontness))}
        }
        solutions.sort {$0.2>$1.2}
        guard let best=solutions.first else {throw TreeSurveyFailure("有効な円柱を求められません。正面表面・左右端を取り直してください")}
        if solutions.count>1,abs(best.0-solutions[1].0)>1e-5 {
            throw TreeSurveyFailure("円柱の解が複数あり不確かです。正面中央の表面から取り直してください")
        }
        return TreeCircle(center:TreePoint(east:p.east+best.1.x,north:p.north+best.1.y,up:p.up),radius:best.0)
    }
    /// Elevation is independent of horizontal aiming error. Each observation owns its
    /// horizontal range and camera height; never reuse the surface or previous range.
    static func axisPoint(_ ray:TreeSightRay,circle:TreeCircle,method:TreeHeightMethod? = .elevationDistance) throws -> TreePoint {
        guard method != nil else {return try legacyAxisPoint(ray,circle:circle)}
        guard let u=ray.unit,circle.center.finite else {throw TreeSurveyFailure("高さの方向を取り直してください")}
        let horizontal=hypot(u.x,u.y)
        let distance=hypot(circle.center.east-ray.origin.east,circle.center.north-ray.origin.north)
        // Numerical degeneracy only. No azimuth/miss, old 100m slant-ray, or steep-angle gate.
        guard horizontal.isFinite,horizontal>1e-8 else {throw TreeSurveyFailure("真上・真下では高さを計算できません。木から離れてください")}
        guard distance.isFinite,distance>1e-6 else {throw TreeSurveyFailure("幹の真上では高さを計算できません。木から離れてください")}
        let up=ray.origin.up+distance*(u.z/horizontal)
        guard up.isFinite else {throw TreeSurveyFailure("高さを計算できません。方向を取り直してください")}
        return TreePoint(east:circle.center.east,north:circle.center.north,up:up)
    }
    /// Exact historical calculation, used only for records without a method tag.
    private static func legacyAxisPoint(_ ray:TreeSightRay,circle:TreeCircle) throws -> TreePoint {
        guard let u=ray.unit else {throw TreeSurveyFailure("高さの方向を取り直してください")}
        let h=SIMD2(u.x,u.y),distance=SIMD2(circle.center.east-ray.origin.east,circle.center.north-ray.origin.north)
        guard simd_length_squared(h)>0.0004,simd_length(distance)>max(0.3,circle.radius+0.02) else {throw TreeSurveyFailure("真上に近く高さが不安定です。木から離れてください")}
        let t=simd_dot(distance,h)/simd_length_squared(h)
        guard t>0,t<100 else {throw TreeSurveyFailure("高さの方向が後方または遠すぎます。取り直してください")}
        let miss=simd_length(t*h-distance)
        guard miss<=max(0.15,min(0.35,max(circle.radius*0.75,simd_length(distance)*0.02))) else {
            throw TreeSurveyFailure("幹軸から方向が外れています。幹軸上と仮定できる下端・上端を狙ってください")
        }
        return TreePoint(east:circle.center.east,north:circle.center.north,up:ray.origin.up+t*u.z)
    }
    static func height(_ observation:TreeCylinderObservation,circle:TreeCircle) throws -> TreeHeight? {
        guard let bottom=observation.bottom,let top=observation.top else {return nil}
        let height=TreeHeight(base:try axisPoint(bottom,circle:circle,method:observation.heightMethod),top:try axisPoint(top,circle:circle,method:observation.heightMethod))
        guard height.valid else {throw TreeSurveyFailure("上端が下端より上にありません。上端を取り直してください")}
        return height
    }
}

enum TreeSurveyMath {
    /// Horizontal circumcircle. Three-point residual zero is NOT a quality/accuracy check.
    static func circle(_ points: [TreePoint]) throws -> TreeCircle {
        guard points.count==3, points.allSatisfy(\.finite) else { throw TreeSurveyFailure("幹の表面を3点測ってください") }
        let p=points[0], b=SIMD2(points[1].east-p.east,points[1].north-p.north)
        let c=SIMD2(points[2].east-p.east,points[2].north-p.north)
        let lengths=[simd_length(b),simd_length(c),simd_length(c-b)]
        let span=lengths.max()!, shortest=lengths.min()!
        let cross=b.x*c.y-b.y*c.x
        guard shortest>=0.015, span.isFinite, span>0,
              abs(cross)/(span*span)>=0.06 else { throw TreeSurveyFailure("3点が近すぎるか一直線です。幹の同じ高さで広く取り直してください") }
        let b2=simd_length_squared(b), c2=simd_length_squared(c), denominator=2*cross
        let center=SIMD2((b2*c.y-c2*b.y)/denominator,(b.x*c2-c.x*b2)/denominator)
        let radius=simd_length(center)
        // A broad visible arc is needed; reject narrow arcs instead of silently fitting a huge circle.
        guard radius.isFinite, radius>=0.015, radius<=1.5, radius<=span else {
            throw TreeSurveyFailure("円が不安定です。離れた樹皮の点を取り直してください")
        }
        let heights=points.map(\.up)
        guard heights.max()!-heights.min()!<=min(0.03,radius*0.24) else {
            throw TreeSurveyFailure("3点の高さが揃っていません。同じ高さで取り直してください")
        }
        return TreeCircle(center:TreePoint(east:p.east+center.x,north:p.north+center.y,up:heights.reduce(0,+)/3),radius:radius)
    }
    static func validate(_ record: TreeRecord, frame: TreeSurveyFrame) throws {
        guard record.number>=0, record.geometry.frameID==frame.id else {throw TreeSurveyFailure("番号または座標基準が不正です")}
        let expected:TreeCircle
        if let observation=record.geometry.cylinder {
            guard record.geometry.surface==[observation.surface],record.geometry.sources==[observation.source] else {throw TreeSurveyFailure("表面点の記録が一致しません")}
            expected=try TreeCylinderMath.circle(observation)
            let calculated=try TreeCylinderMath.height(observation,circle:expected)
            switch (record.geometry.height,calculated) {
            case (.none,.none):break
            case (.some(let height),.some(let computed)):
                guard simd_length(computed.base.vector-height.base.vector)<1e-8,
                      simd_length(computed.top.vector-height.top.vector)<1e-8 else {throw TreeSurveyFailure("推定樹高と方向の記録が一致しません")}
            default:throw TreeSurveyFailure("推定樹高と方向の記録が一致しません")
            }
        } else {
            guard record.geometry.sources.count==3 else {throw TreeSurveyFailure("3点円の記録が不正です")}
            expected=try circle(record.geometry.surface)
        }
        guard simd_length(expected.center.vector-record.geometry.circle.center.vector)<1e-8,
              abs(expected.radius-record.geometry.circle.radius)<1e-8 else { throw TreeSurveyFailure("円の確定値と観測が一致しません") }
        if let height=record.geometry.height, !height.valid { throw TreeSurveyFailure("樹高を確定できません。取り直してください") }
    }
    static func triangulate(_ first: ObservationRay, _ second: ObservationRay, trunk: Bool) throws -> SIMD3<Float> {
        let point=try DrawingGeometry.triangulation(first,second,trackingNormal:true).get()
        if trunk {
            let c=simd_dot(first.direction,second.direction), w=first.origin-second.origin
            let d=simd_dot(first.direction,w),e=simd_dot(second.direction,w),denominator=1-c*c
            let t=(c*e-d)/denominator,u=(e-c*d)/denominator
            let gap=simd_length(first.origin+t*first.direction-second.origin-u*second.direction)
            guard gap<=0.02 else { throw TreeSurveyFailure("幹の2視線が一致しません。同じ樹皮の印を再指定してください") }
        }
        return point
    }
}

/// Resolve each point before starting the next, matching the existing point-input workflow.
/// Rays are ephemeral and must never be restored into a different AR session.
struct TreeTrunkCapture {
    struct Slot { var ray: ObservationRay?; var world: SIMD3<Float>?; var source: TreePointSource? }
    var slots = Array(repeating:Slot(),count:3)
    var currentIndex: Int? { slots.firstIndex { $0.world==nil } }
    var complete: Bool { currentIndex==nil }
    var worlds: [SIMD3<Float>] { slots.compactMap(\.world) }
    var sources: [TreePointSource] { slots.compactMap(\.source) }
    var rays: [ObservationRay] { slots.filter {$0.world==nil}.compactMap(\.ray) }
    mutating func accept(ray: ObservationRay, depth: SIMD3<Float>?) throws {
        guard [ray.origin.x,ray.origin.y,ray.origin.z,ray.direction.x,ray.direction.y,ray.direction.z].allSatisfy(\.isFinite) else {
            throw TreeSurveyFailure("カメラ情報を確認できません。取り直してください")
        }
        if let depth, ![depth.x,depth.y,depth.z].allSatisfy(\.isFinite) {throw TreeSurveyFailure("深度の点を確認できません")}
        guard let index=currentIndex else { return }
        // A held ray always needs its matching second view, even if depth becomes available.
        // A rejected pair retains the first ray and stays on the same point.
        if let first=slots[index].ray {
            slots[index].world=try TreeSurveyMath.triangulate(first,ray,trunk:true)
            slots[index].source = .twoRays
        } else if let depth {
            slots[index].world=depth;slots[index].source = .lidar
        } else { slots[index].ray=ray }
    }
}

struct TreeCaptureMarker: Equatable, Identifiable {
    var id: UUID
    var number: Int
    var point: TreePoint
}

/// Render-only extents. Unknown ends never become TreeHeight or saved measurements.
struct TreePreviewBounds:Equatable {
    static let previewHeight:Double=50
    var lower:Double
    var upper:Double
    var lowerProvisional:Bool
    var upperProvisional:Bool
    var provisional:Bool {lowerProvisional || upperProvisional}
    var title:String {lowerProvisional ? "下端・上端を指定":(upperProvisional ? "上端を指定":String(format:"%.2f m",upper-lower))}
    static func make(_ geometry:TreeGeometry,preview:Bool)->TreePreviewBounds? {
        if let h=geometry.height,h.valid {return TreePreviewBounds(lower:h.base.up,upper:h.top.up,lowerProvisional:false,upperProvisional:false)}
        guard preview,let observation=geometry.cylinder else {return nil}
        if let bottom=observation.bottom,let point=try? TreeCylinderMath.axisPoint(bottom,circle:geometry.circle,method:observation.heightMethod) {
            return TreePreviewBounds(lower:point.up,upper:point.up+previewHeight,lowerProvisional:false,upperProvisional:true)
        }
        return TreePreviewBounds(lower:geometry.circle.center.up-1,upper:geometry.circle.center.up+previewHeight,lowerProvisional:true,upperProvisional:true)
    }
    /// Metre positions stay exact; taller rulers retain five-metre marks across
    /// their full extent, then fill nearby one-metre marks within the same budget.
    var metreTicks:[Int] {
        guard let n=wholeMetres,n>0 else {return []}
        if n<=TreeDisplayBudget.maximumTicksPerTree {return Array(1...n)}
        var selected=Set(stride(from:5,through:n,by:5));selected.insert(n)
        for metre in 1...n where selected.count<TreeDisplayBudget.maximumTicksPerTree {selected.insert(metre)}
        return selected.sorted()
    }
    var labelledMetres:[Int] {
        guard let n=wholeMetres else {return []}
        let ticks=metreTicks
        return n>TreeDisplayBudget.maximumTicksPerTree ? ticks.filter {$0%10==0 || $0==n}:Array(ticks.prefix(5))
    }
    private var wholeMetres:Int? {
        guard !lowerProvisional,lower.isFinite,upper.isFinite,upper>lower else {return nil}
        return Int(min(99,max(0,floor(upper-lower+1e-4))))
    }

}
struct TreeDirectionSight:Equatable {
    enum Side:String {case left="左方向 ✓",right="右方向 ✓"}
    var side:Side
    var ray:TreeSightRay
    var target:TreePoint
}
enum TreeDisplayBudget {
    static let maximumCircles=128
    static let maximumLabels=20
    static let maximumRays=3
    static let maximumTicks=256
    static let maximumTicksPerTree=24
    static let maximumDistance:Float=60
    static func selected(_ distances:[(UUID,Float)],priority:UUID?=nil)->[UUID] {
        distances.filter {$0.1.isFinite && $0.1>=0 && ($0.1<=maximumDistance || $0.0==priority)}
            .sorted {if ($0.0==priority) != ($1.0==priority) {return $0.0==priority};if $0.1 != $1.1 {return $0.1<$1.1};return $0.0.uuidString<$1.0.uuidString}
            .prefix(maximumCircles).map(\.0)
    }
    static func distance(camera:SIMD3<Float>,center:SIMD3<Float>,lower:Float?,upper:Float?)->Float {
        let y:Float
        if let lower,let upper {y=max(lower,min(upper,camera.y))} else {y=center.y}
        return simd_length(camera-SIMD3(center.x,y,center.z))
    }
    static func tickAllocation(_ requested:[(UUID,[Int])])->[UUID:[Int]] {
        var remaining=maximumTicks,result:[UUID:[Int]]=[:]
        for (id,values) in requested {
            let chosen=Array(values.prefix(min(remaining,maximumTicksPerTree)))
            result[id]=chosen;remaining-=chosen.count
        }
        return result
    }
}
/// Two small immutable meshes shared by every cylinder, ring, tick and sight glyph.
/// Unit body: radius 1, Y -0.5...0.5. Ring: radius 1, horizontal, both faces.
struct TreeUnitMesh {
    var positions:[SIMD3<Float>]
    var indices:[UInt32]
    static func make(ring:Bool)->TreeUnitMesh {
        let count=12
        var p:[SIMD3<Float>]=[],indices:[UInt32]=[]
        for i in 0..<count {
            let a=Float(i)*2*Float.pi/Float(count),b=Float(i+1)*2*Float.pi/Float(count)
            let x=SIMD3(cos(a),Float(0),sin(a)),y=SIMD3(cos(b),Float(0),sin(b)),base=UInt32(p.count)
            if ring {
                p += [x*0.98,x*1.02,y*0.98,y*1.02]
                indices += [base,base+1,base+2,base+1,base+3,base+2,base+2,base+1,base,base+2,base+3,base+1]
            } else {
                p += [x+SIMD3(0,-0.5,0),x+SIMD3(0,0.5,0),y+SIMD3(0,-0.5,0),y+SIMD3(0,0.5,0),SIMD3(0,-0.5,0),SIMD3(0,0.5,0)]
                indices += [base,base+1,base+2,base+1,base+3,base+2,base+4,base,base+2,base+5,base+3,base+1]
            }
        }
        return TreeUnitMesh(positions:p,indices:indices)
    }
}

enum TreeSurveyCSV {
    static func encode(frame: TreeSurveyFrame, records: [TreeRecord]) -> Data {
        func quote(_ value: String) -> String { "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
        func number(_ value: Double) -> String { String(format:"%.5f",locale:Locale(identifier:"en_US_POSIX"),value) }
        var lines=["# "+frame.description+"; 円柱方式XYZは表面点と同じ高さの幹軸位置; 推定樹高は幹軸上の仮定（傾斜木・樹冠張出しは誤差要因）","色,番号,X_東_m,Y_北_m,相対Z_m,直径_cm,樹高_m,直径方式,樹高方式,樹種"]
        for record in records.sorted(by:{$0.creationOrder<$1.creationOrder}) {
            let p=record.geometry.circle.center
            lines.append([quote(record.color.title),String(record.number),number(p.east),number(p.north),number(p.up),number(record.geometry.circle.diameter*100),record.geometry.height.map {number($0.metres)} ?? "",quote(record.geometry.cylinder == nil ? "3点円" : "鉛直円柱・表面点と左右接線"),quote(record.geometry.height == nil ? "未測定" : (record.geometry.cylinder == nil ? "3D二点" : (record.geometry.cylinder?.heightMethod == .elevationDistance ? "水平距離と仰俯角":"幹軸上の推定・傾斜木や樹冠張出しは誤差要因"))),quote(TreeSpecies.name(record.species) ?? "")].joined(separator:","))
        }
        return Data((lines.joined(separator:"\r\n")+"\r\n").utf8)
    }
}
