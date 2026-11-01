import Foundation
import simd
import CoreGraphics
import CoreVideo

struct ObservationRay: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
    var sessionEpoch: Int = 0
}

enum ARAdjustmentSensitivity {
    static let headingDegreesPerPoint = 0.09
    static let heightMetersPerPoint = 0.012
}

/// Displayed geometry only. This transient input is never serialized as measured work.
struct DrawingSnapPath {
    enum Source: String {case imported = "読込", saved = "保存済", input = "入力中"}
    var points:[SIMD3<Float>]
    var vertices:[SIMD3<Float>]
    var heights:[Double?]
    var vertexHeights:[Double?]
    var segments:Bool
    var closed:Bool = false
    var source:Source
    var heightSources:[DrawingElevationSource?] = []
    var vertexHeightSources:[DrawingElevationSource?] = []
}
struct DrawingSnapHit {
    var point:SIMD3<Float>
    var altitude:Double?
    var screen:CGPoint
    var source:DrawingSnapPath.Source
    var vertex:Bool
    var elevationSource:DrawingElevationSource? = nil
    var title:String {source.rawValue + (vertex ? "の点" : "の線上")}
}
struct DrawingSnapIndicator:Equatable {
    var normalized:CGPoint
    var title:String
}
enum DrawingSnap {
    static func allowed(enabled:Bool,active:Bool,selecting:Bool,treeActive:Bool,hasObservation:Bool)->Bool {
        enabled && active && !selecting && !treeActive && !hasObservation
    }
    /// One picker drives both preview and confirmation. Vertices retain priority.
    static func pick(_ tap:CGPoint,paths:[DrawingSnapPath],root:simd_float4x4,cameraFromWorld:simd_float4x4,project:(SIMD3<Float>)->CGPoint?)->DrawingSnapHit? {
        guard tap.x.isFinite,tap.y.isFinite else {return nil}
        func projected(_ local:SIMD3<Float>)->(CGPoint,Float)? {
            guard local.x.isFinite,local.y.isFinite,local.z.isFinite else {return nil}
            let world=DrawingGeometry.point(local,transformedBy:root)
            let z = -DrawingGeometry.point(world,transformedBy:cameraFromWorld).z
            guard z.isFinite,z>0.05,let p=project(world),p.x.isFinite,p.y.isFinite else {return nil}
            return (p,z)
        }
        func height(_ values:[Double?],_ i:Int)->Double? {values.indices.contains(i) ? values[i].flatMap {$0.isFinite ? $0:nil}:nil}
        func provenance(_ values:[DrawingElevationSource?],_ i:Int)->DrawingElevationSource {values.indices.contains(i) && values[i] == .sourceDrawing ? .sourceDrawing:.arEstimate}
        var nearest:(Float,DrawingSnapHit)?
        func offer(_ hit:DrawingSnapHit,threshold:Float) {
            let d=simd_length(SIMD2(Float(hit.screen.x-tap.x),Float(hit.screen.y-tap.y)))
            if d<=threshold && (nearest == nil || d<nearest!.0) {nearest=(d,hit)}
        }
        for path in paths {for (i,p) in path.vertices.enumerated() {
            if let (screen,_)=projected(p) {offer(DrawingSnapHit(point:p,altitude:height(path.vertexHeights,i),screen:screen,source:path.source,vertex:true,elevationSource:height(path.vertexHeights,i) == nil ? nil:provenance(path.vertexHeightSources,i)),threshold:18)}
        }}
        if let hit=nearest?.1 {return hit}
        for path in paths where path.segments && path.points.count>=2 {
            let count=path.points.count
            for i in 0..<(path.closed ? count:count-1) {
                let j=(i+1)%count,a=path.points[i],b=path.points[j]
                guard let (sa,za)=projected(a),let (sb,zb)=projected(b) else {continue}
                let av=SIMD2(Float(sa.x),Float(sa.y)),bv=SIMD2(Float(sb.x),Float(sb.y)),tv=SIMD2(Float(tap.x),Float(tap.y))
                let delta=bv-av,length=simd_length_squared(delta)
                guard length>0.01 else {continue}
                let screenT=max(0,min(1,simd_dot(tv-av,delta)/length))
                let t=DrawingGeometry.perspectiveFraction(screenFraction:screenT,startDepth:za,endDepth:zb)
                guard t.isFinite else {continue}
                let screen=av+screenT*delta
                let altitude=height(path.heights,i).flatMap {a in height(path.heights,j).map {a+($0-a)*Double(t)}}
                offer(DrawingSnapHit(point:DrawingGeometry.closestPoint(on:a,to:b,fraction:t),altitude:altitude,screen:CGPoint(x:CGFloat(screen.x),y:CGFloat(screen.y)),source:path.source,vertex:false,elevationSource:altitude == nil ? nil:(provenance(path.heightSources,i) == .sourceDrawing && provenance(path.heightSources,j) == .sourceDrawing ? .sourceDrawing:.arEstimate)),threshold:12)
            }
        }
        return nearest?.1
    }
}

enum DrawingGeometry {
    /// The initial point radius stays 3.5 cm; saved work retains its original ratio.
    /// This affects newly drawn geometry only, not imported points or hit targets.
    static func pointScale(lineWidth:Double,referenceWidth:Double = 0.016) -> Float { Float(lineWidth / referenceWidth) }
    static func point(_ p: SIMD3<Float>, transformedBy m: simd_float4x4) -> SIMD3<Float> {
        let v = m * SIMD4<Float>(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
    // Thresholds reject weak geometry; they are not an accuracy guarantee.
    static func triangulation(_ a: ObservationRay, _ b: ObservationRay, trackingNormal: Bool) -> Result<SIMD3<Float>, DrawingRejection> {
        guard trackingNormal else { return .failure(.tracking) }
        guard a.sessionEpoch == b.sessionEpoch else { return .failure(.epoch) }
        guard simd_length(a.origin-b.origin).isFinite,
              abs(simd_length(a.direction)-1) < 0.001, abs(simd_length(b.direction)-1) < 0.001 else { return .failure(.invalid) }
        guard simd_length(a.origin-b.origin) >= 0.25 else { return .failure(.baseline) }
        let c = simd_dot(a.direction,b.direction), denominator = 1-c*c
        guard denominator.isFinite, denominator >= pow(sin(Float.pi/36),2) else { return .failure(.parallel) }
        let w = a.origin-b.origin, d = simd_dot(a.direction,w), e = simd_dot(b.direction,w)
        let t = (c*e-d)/denominator, u = (e-c*d)/denominator
        guard t > 0, u > 0 else { return .failure(.behind) }
        guard t < 100, u < 100 else { return .failure(.distance) }
        let p = a.origin+t*a.direction, q = b.origin+u*b.direction
        guard simd_length(p-q) <= 0.08 else { return .failure(.miss) }
        return .success((p+q)/2)
    }
    static func triangulate(_ a: ObservationRay, _ b: ObservationRay, trackingNormal: Bool) -> SIMD3<Float>? {
        try? triangulation(a,b,trackingNormal:trackingNormal).get()
    }
    // Depth is camera z, not distance along the normalized ray. AR camera looks down -Z.
    static func unproject(pixel: SIMD2<Float>, depth: Float, intrinsics k: simd_float3x3) -> SIMD3<Float>? {
        guard depth.isFinite,depth>0,pixel.x.isFinite,pixel.y.isFinite,
              (0..<3).allSatisfy({c in (0..<3).allSatisfy {k[c][$0].isFinite}}),k[0][0]>0,k[1][1]>0,abs(k[2][2]-1)<0.001 else {return nil}
        return SIMD3((pixel.x-k[2][0])*depth/k[0][0], -(pixel.y-k[2][1])*depth/k[1][1], -depth)
    }
    static func perspectiveFraction(screenFraction: Float, startDepth: Float, endDepth: Float) -> Float {
        (screenFraction/endDepth)/((1-screenFraction)/startDepth+screenFraction/endDepth)
    }
    static func closestPoint(on a: SIMD3<Float>, to b: SIMD3<Float>, fraction: Float) -> SIMD3<Float> {
        a + max(0,min(1,fraction))*(b-a)
    }
}

/// In-memory single-flight confirmation; never part of the saved drawing format.
struct DrawingConfirmation:Equatable {
    private(set) var id=0
    private(set) var pending=false
    mutating func request() {guard !pending else {return};id &+= 1;pending=true}
    mutating func finish(_ token:Int) {guard token==id else {return};pending=false}
    mutating func cancel() {id &+= 1;pending=false}
}

enum DrawingProjection {
    /// ARFrame.displayTransform maps normalized camera image -> normalized view.
    static func imagePoint(viewPoint:CGPoint,viewport:CGSize,imageToView:CGAffineTransform)->CGPoint? {
        let values=[viewPoint.x,viewPoint.y,viewport.width,viewport.height,imageToView.a,imageToView.b,imageToView.c,imageToView.d,imageToView.tx,imageToView.ty]
        guard values.allSatisfy(\.isFinite),viewport.width>0,viewport.height>0,
              abs(imageToView.a*imageToView.d-imageToView.b*imageToView.c)>1e-10 else {return nil}
        let p=CGPoint(x:viewPoint.x/viewport.width,y:viewPoint.y/viewport.height).applying(imageToView.inverted())
        guard p.x>=0,p.x<1,p.y>=0,p.y<1 else {return nil};return p
    }
    static func pixel(imagePoint:CGPoint,resolution:CGSize)->SIMD2<Float>? {
        guard resolution.width.isFinite,resolution.height.isFinite,resolution.width>0,resolution.height>0,
              imagePoint.x.isFinite,imagePoint.y.isFinite,imagePoint.x>=0,imagePoint.x<1,imagePoint.y>=0,imagePoint.y<1 else {return nil}
        return SIMD2(Float(imagePoint.x*resolution.width),Float(imagePoint.y*resolution.height))
    }
    static func ray(pixel:SIMD2<Float>,intrinsics:simd_float3x3,camera:simd_float4x4,epoch:Int)->ObservationRay? {
        guard let p=DrawingGeometry.unproject(pixel:pixel,depth:1,intrinsics:intrinsics),
              (0..<4).allSatisfy({column in (0..<4).allSatisfy {camera[column][$0].isFinite}}) else {return nil}
        let d=camera*SIMD4(p,0),u=SIMD3(d.x,d.y,d.z),length=simd_length(u)
        guard length.isFinite,length>0 else {return nil}
        return ObservationRay(origin:SIMD3(camera[3].x,camera[3].y,camera[3].z),direction:u/length,sessionEpoch:epoch)
    }
}

enum DrawingDepthFailure:Error,Equatable {
    case noDepth,noConfidence,format,buffer,outside,invalidCentre,centreConfidence(UInt8),support(Int),unstable,calibration
    var message:String {
        switch self {
        case .noDepth:return "深度フレーム待ち"
        case .noConfidence:return "深度の信頼度なし"
        case .format:return "深度形式を確認できません"
        case .buffer:return "深度を読み取れません"
        case .outside:return "照準の画像座標を確認"
        case .invalidCentre:return "中心の深度が無効"
        case .centreConfidence(let level):return level==0 ? "中心の深度信頼度が低い":"中心の深度信頼度が不足"
        case .support(let n):return "周囲の有効深度\(n)/9"
        case .unstable:return "面の境界・深度が不安定"
        case .calibration:return "カメラ情報を確認"
        }
    }
}
struct DrawingDepthPixel {var x:Int;var y:Int;var z:Float;var confidence:UInt8}
struct DrawingDepthSample {var cameraPoint:SIMD3<Float>;var cameraZ:Float;var range:Float;var support:Int}

enum DrawingDepth {
    /// A camera-facing OR oblique plane has affine inverse depth in image pixels.
    /// Fit is only a validity check: return the measured centre z, never an interpolated substitute.
    static func validatedCentre(_ samples:[DrawingDepthPixel])->Result<Float,DrawingDepthFailure> {
        guard let centre=samples.first(where:{$0.x==0 && $0.y==0}),centre.z.isFinite,centre.z>0.15,centre.z<100 else {return .failure(.invalidCentre)}
        guard centre.confidence==2 else {return .failure(.centreConfidence(centre.confidence))}
        let valid=samples.filter {$0.confidence==2 && $0.z.isFinite && $0.z>0.15 && $0.z<100}
        guard valid.count>=5 else {return .failure(.support(valid.count))}
        var matrix=Array(repeating:Array(repeating:Double(0),count:4),count:3)
        for sample in valid {
            let a=[Double(sample.x),Double(sample.y),1],b=1/Double(sample.z)
            for row in 0..<3 {for col in 0..<3 {matrix[row][col]+=a[row]*a[col]};matrix[row][3]+=a[row]*b}
        }
        for col in 0..<3 {
            let pivot=(col..<3).max {abs(matrix[$0][col])<abs(matrix[$1][col])}!
            guard abs(matrix[pivot][col])>1e-8 else {return .failure(.unstable)}
            matrix.swapAt(col,pivot);let divisor=matrix[col][col]
            for j in col..<4 {matrix[col][j]/=divisor}
            for row in 0..<3 where row != col {let scale=matrix[row][col];for j in col..<4 {matrix[row][j]-=scale*matrix[col][j]}}
        }
        let a=matrix.map {$0[3]},z=Double(centre.z)
        guard a.allSatisfy(\.isFinite),a[2]>0,abs(1/a[2]-z)<=min(0.025,max(0.005,z*0.01)) else {return .failure(.unstable)}
        let tolerance=min(0.05,max(0.012,z*0.02))
        for sample in valid {
            let inverse=a[0]*Double(sample.x)+a[1]*Double(sample.y)+a[2]
            guard inverse>0,abs(1/inverse-Double(sample.z))<=tolerance else {return .failure(.unstable)}
        }
        return .success(centre.z)
    }
    static func sample(map:CVPixelBuffer,confidence:CVPixelBuffer?,imagePoint:CGPoint,pixel:SIMD2<Float>,intrinsics:simd_float3x3)->Result<DrawingDepthSample,DrawingDepthFailure> {
        guard let confidence else {return .failure(.noConfidence)}
        let format=CVPixelBufferGetPixelFormatType(map)
        guard [kCVPixelFormatType_DepthFloat32,kCVPixelFormatType_OneComponent32Float].contains(format),
              CVPixelBufferGetPixelFormatType(confidence)==kCVPixelFormatType_OneComponent8,
              !CVPixelBufferIsPlanar(map),!CVPixelBufferIsPlanar(confidence) else {return .failure(.format)}
        let width=CVPixelBufferGetWidth(map),height=CVPixelBufferGetHeight(map)
        guard width>0,height>0,CVPixelBufferGetWidth(confidence)==width,CVPixelBufferGetHeight(confidence)==height else {return .failure(.format)}
        guard imagePoint.x.isFinite,imagePoint.y.isFinite,imagePoint.x>=0,imagePoint.x<1,imagePoint.y>=0,imagePoint.y<1 else {return .failure(.outside)}
        guard CVPixelBufferLockBaseAddress(map,.readOnly)==kCVReturnSuccess else {return .failure(.buffer)}
        defer {CVPixelBufferUnlockBaseAddress(map,.readOnly)}
        guard CVPixelBufferLockBaseAddress(confidence,.readOnly)==kCVReturnSuccess else {return .failure(.buffer)}
        defer {CVPixelBufferUnlockBaseAddress(confidence,.readOnly)}
        let depthStride=CVPixelBufferGetBytesPerRow(map),confidenceStride=CVPixelBufferGetBytesPerRow(confidence)
        guard depthStride>=width*4,depthStride%4==0,confidenceStride>=width,
              let depth=CVPixelBufferGetBaseAddress(map),let levels=CVPixelBufferGetBaseAddress(confidence) else {return .failure(.buffer)}
        let x=Int(imagePoint.x*Double(width)),y=Int(imagePoint.y*Double(height))
        var samples:[DrawingDepthPixel]=[]
        for row in max(0,y-1)...min(height-1,y+1) {for col in max(0,x-1)...min(width-1,x+1) {
            samples.append(DrawingDepthPixel(x:col-x,y:row-y,z:depth.advanced(by:row*depthStride+col*4).load(as:Float.self),confidence:levels.advanced(by:row*confidenceStride+col).load(as:UInt8.self)))
        }}
        switch validatedCentre(samples) {
        case .failure(let reason):return .failure(reason)
        case .success(let z):
            guard let camera=DrawingGeometry.unproject(pixel:pixel,depth:z,intrinsics:intrinsics),
                  camera.x.isFinite,camera.y.isFinite,camera.z.isFinite,simd_length(camera)<100 else {return .failure(.calibration)}
            return .success(DrawingDepthSample(cameraPoint:camera,cameraZ:z,range:simd_length(camera),support:samples.filter {$0.confidence==2 && $0.z.isFinite && $0.z>0.15 && $0.z<100}.count))
        }
    }
}

enum DrawingRejection: Error, Equatable {
    case tracking, epoch, baseline, parallel, behind, distance, miss, invalid
    var message: String {
        switch self {
        case .tracking: return "追跡待ち・もう一度タップ"
        case .epoch: return "追跡が変化・最初から観測"
        case .baseline: return "もう少し横へ移動"
        case .parallel: return "観測角度不足・横へ移動"
        case .behind: return "同じ対象をタップ"
        case .distance: return "対象が遠すぎます"
        case .miss: return "視線がずれています・再タップ"
        case .invalid: return "観測できません・再タップ"
        }
    }
}
enum DrawingCapture {
    enum Outcome { case hold, point(SIMD3<Float>, depth:Bool), rejected(DrawingRejection) }
    static func resolve(first: ObservationRay?, next: ObservationRay, useDepth: Bool, depth: () -> SIMD3<Float>?) -> Outcome {
        // A recovered, valid measurement resolves the CURRENT reticle point.
        // An earlier depth miss must not permanently trap drawing in two-ray mode.
        if useDepth,let point=depth(),point.x.isFinite,point.y.isFinite,point.z.isFinite {return .point(point,depth:true)}
        if let first {
            switch DrawingGeometry.triangulation(first,next,trackingNormal:true) {
            case .success(let point): return .point(point,depth:false)
            case .failure(let reason): return .rejected(reason)
            }
        }
        return .hold
    }
}
struct DrawingTapPolicy {
    static let maxTravel = 18.0
    static let maxDuration = 0.7
    static func accepts(travel:Double,duration:Double) -> Bool {
        travel.isFinite && duration.isFinite && travel <= maxTravel && duration >= 0 && duration <= maxDuration
    }
}

enum DrawingPathDelta: Equatable {
    case unchanged, append, removeLast, rebuild
    static func classify(old: [SIMD3<Float>], new: [SIMD3<Float>]) -> DrawingPathDelta {
        if old == new { return .unchanged }
        if new.count == old.count+1 && zip(old,new).allSatisfy({ $0 == $1 }) { return .append }
        if old.count == new.count+1 && zip(old,new).allSatisfy({ $0 == $1 }) { return .removeLast }
        return .rebuild
    }
}

enum DrawingKind: String, Codable { case line, points }
enum DrawingElevationSource: String, Codable { case sourceDrawing, arEstimate }
struct DrawingVertexInfo: Codable, Equatable, Identifiable {
    var id = UUID()
    var elevation: Double? = nil
    var elevationSource: DrawingElevationSource? = nil
}
struct DrawingPath: Codable, Equatable, Identifiable {
    var id = UUID()
    var points: [SIMD3<Float>] = []
    var kind: DrawingKind? = nil
    var vertices: [DrawingVertexInfo]? = nil
    var layerID: UUID? = nil
    var resolvedLayerID: UUID { layerID ?? DrawingLayer.legacyID }
    var isPointCollection: Bool { kind == .points }
    mutating func ensureVertices(legacyDatum: Double? = nil) {
        if vertices?.count == points.count { return }
        var result = Array((vertices ?? []).prefix(points.count))
        while result.count < points.count {
            let height = legacyDatum.map { $0 + Double(points[result.count].y) }
            result.append(DrawingVertexInfo(elevation:height,elevationSource:height == nil ? nil : .arEstimate))
        }
        vertices = result
    }
    mutating func append(_ point:SIMD3<Float>, elevation:Double?, source:DrawingElevationSource?) {
        ensureVertices()
        points.append(point)
        vertices!.append(DrawingVertexInfo(elevation:elevation,elevationSource:source))
    }
    mutating func removeLast() {
        guard !points.isEmpty else { return }
        ensureVertices(); points.removeLast(); vertices!.removeLast()
    }
}
struct DeletedDrawing: Codable, Equatable {
    var path: DrawingPath
    var index: Int
    var groupID: UUID? = nil
}
struct DrawingLayer: Codable, Equatable, Identifiable {
    static let legacyID = UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    var id: UUID
    var name: String
    static let legacy = DrawingLayer(id:legacyID,name:"作図1")
}
struct DrawingState: Codable, Equatable {
    var completed: [DrawingPath] = []
    var draft = DrawingPath()
    var active = false
    var resuming = false
    var resumeOriginal: DrawingPath?
    var resumeIndex: Int? = nil
    var deleted: [DeletedDrawing]? = nil
    // Optional additions preserve the build32 save format. Old paths belong to 作図1.
    var layers: [DrawingLayer]? = nil
    var selectedLayerID: UUID? = nil
    var drawingLayers: [DrawingLayer] { layers?.isEmpty == false ? layers! : [.legacy] }
    var currentLayerID: UUID { selectedLayerID.flatMap { id in drawingLayers.contains { $0.id == id } ? id : nil } ?? drawingLayers[0].id }
    var currentLayerName: String { drawingLayers.first { $0.id == currentLayerID }!.name }
    var currentPaths: [DrawingPath] { completed.filter { $0.resolvedLayerID == currentLayerID } }
    var canFinish: Bool { active && draft.points.count >= (draft.isPointCollection ? 1 : 2) }
    var resumableID: UUID? { currentPaths.last { !$0.isPointCollection && $0.points.count >= 2 }?.id }
    // Observation rays intentionally never persist across AR sessions.
    mutating func start(kind:DrawingKind = .line) {
        guard !active else { return }
        if draft.points.isEmpty { draft.kind=kind; draft.layerID=currentLayerID }
        active = true; resuming = false; resumeIndex=nil
    }
    mutating func resume() {
        guard !active, draft.points.isEmpty, let id=resumableID,
              let index=completed.firstIndex(where: { $0.id==id }) else { return }
        let last=completed.remove(at:index)
        draft = last; resumeOriginal = last; resumeIndex=index; active = true; resuming = true
    }
    mutating func undo() { if active { draft.removeLast() } }
    mutating func finish() {
        guard canFinish else { return }
        if draft.isPointCollection {
            draft.ensureVertices()
            for i in draft.points.indices { completed.append(DrawingPath(points:[draft.points[i]],kind:.points,vertices:[draft.vertices![i]],layerID:draft.layerID)) }
        } else { completed.insert(draft,at:min(resumeIndex ?? completed.count,completed.count)) }
        draft = DrawingPath(); active = false; resuming = false; resumeOriginal = nil; resumeIndex=nil
    }
    mutating func cancel() {
        if let original = resumeOriginal { completed.insert(original,at:min(resumeIndex ?? completed.count,completed.count)) }
        draft = DrawingPath(); active = false; resuming = false; resumeOriginal = nil; resumeIndex=nil
    }
    /// Discard only this input. A resumed, previously saved line is restored by cancel().
    mutating func clearInput(continueDrawing:Bool) {
        let kind=draft.kind ?? .line
        cancel()
        if continueDrawing {start(kind:kind)}
    }
    mutating func rebase(_ m: simd_float4x4) {
        self = mappingPoints { DrawingGeometry.point($0, transformedBy:m) }
    }
    /// Build a complete replacement before committing a coordinate conversion.
    /// Undo and resume history must use the same frame as the visible paths.
    func mappingPoints(_ transform:(SIMD3<Float>) throws -> SIMD3<Float>) rethrows -> DrawingState {
        var next=self
        for i in next.completed.indices { next.completed[i].points = try next.completed[i].points.map(transform) }
        if var original=next.resumeOriginal { original.points=try original.points.map(transform);next.resumeOriginal=original }
        next.draft.points=try next.draft.points.map(transform)
        if var history=next.deleted {
            for i in history.indices { history[i].path.points=try history[i].path.points.map(transform) }
            next.deleted=history
        }
        return next
    }
    mutating func delete(id:UUID) {
        guard !active, let index=completed.firstIndex(where: { $0.id==id }) else { return }
        let path=completed.remove(at:index)
        if deleted == nil { deleted=[] }
        deleted!.append(DeletedDrawing(path:path,index:index))
    }
    @discardableResult mutating func undoDeletion() -> UUID? {
        guard !active, let item=deleted?.last, !completed.contains(where: { $0.id==item.path.id }) else { return nil }
        var items = [deleted!.removeLast()]
        if let group=item.groupID {
            while deleted?.last?.groupID == group { items.append(deleted!.removeLast()) }
        }
        for entry in items.sorted(by: { $0.index < $1.index }) {
            completed.insert(entry.path,at:min(entry.index,completed.count))
        }
        selectedLayerID=item.path.resolvedLayerID
        return item.path.id
    }
    mutating func addLayer(name:String) {
        let trimmed=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40))
        let layer=DrawingLayer(id:UUID(),name:trimmed.isEmpty ? "作図\(drawingLayers.count+1)" : trimmed)
        layers=drawingLayers+[layer]
        selectLayer(layer.id)
    }
    mutating func selectLayer(_ id:UUID) {
        guard drawingLayers.contains(where: { $0.id == id }), id != currentLayerID else { return }
        let wasActive=active, kind=draft.kind ?? .line
        // A layer switch finishes the old segment; never joins the next layer's first point.
        // Keep a lone vertex as a point, instead of silently discarding it.
        if active {
            if draft.points.count == 1 && !draft.isPointCollection { draft.kind = .points }
            if canFinish { finish() } else { cancel() }
        }
        selectedLayerID=id
        if wasActive { start(kind:kind) }
    }
    mutating func deletePaths(in layer:UUID?) {
        guard !active else { return }
        let entries=completed.enumerated().filter { layer == nil || $0.element.resolvedLayerID == layer }
        guard !entries.isEmpty else { return }
        let group=UUID()
        deleted=(deleted ?? [])+entries.map { DeletedDrawing(path:$0.element,index:$0.offset,groupID:group) }
        let ids=Set(entries.map { $0.element.id })
        completed.removeAll { ids.contains($0.id) }
    }
    mutating func ensureVertices(legacyDatum:Double? = nil) {
        for i in completed.indices where !completed[i].points.isEmpty { completed[i].ensureVertices(legacyDatum:legacyDatum) }
        if !draft.points.isEmpty { draft.ensureVertices(legacyDatum:legacyDatum) }
        resumeOriginal?.ensureVertices(legacyDatum:legacyDatum)
        if var history=deleted {
            for i in history.indices { history[i].path.ensureVertices(legacyDatum:legacyDatum) }
            deleted=history
        }
    }
}

/// Keep the input intact until the corresponding durable save is acknowledged.
/// This gate also makes a repeated press and a stale completion harmless.
struct DrawingLineSave:Equatable {
    struct Request:Equatable {
        let id:UUID
        let input:DrawingState
        let committed:DrawingState
    }
    private(set) var request:Request?
    var pending:Bool {request != nil}
    mutating func begin(_ input:DrawingState)->Request? {
        guard request==nil,input.canFinish else {return nil}
        var next=input;let kind=input.draft.kind ?? .line
        next.finish();next.start(kind:kind)
        let value=Request(id:UUID(),input:input,committed:next);request=value;return value
    }
    mutating func resolve(_ id:UUID,succeeded:Bool)->DrawingState? {
        guard let value=request,value.id==id else {return nil}
        request=nil
        return succeeded ? value.committed:value.input
    }
}

enum DrawingDistanceMode: String, Codable, CaseIterable {
    case slope, horizontalVertical
    var title: String { self == .slope ? "斜距離" : "水平距離＋垂直距離" }
}

struct DrawingDistance: Equatable, Identifiable {
    var id: UUID
    var midpoint: SIMD3<Float>
    var metres: Float
    var horizontalMetres: Float
    /// Stored drawing coordinates use +Y up, +X east, -Z north (metres).
    /// Root height/pan and heading alignment cannot change a segment's differences.
    var verticalMetres: Float
    var text: String { text(in:.slope) }
    func text(in mode: DrawingDistanceMode) -> String {
        switch mode {
        case .slope: return String(format:"斜 %.2f m",metres)
        case .horizontalVertical:
            // Avoid a misleading -0.00 for a tiny negative difference.
            let vertical = abs(verticalMetres) < 0.005 ? Float.zero : verticalMetres
            return String(format:"水平 %.2f m / 上下差 %+.2f m",horizontalMetres,vertical)
        }
    }
    static func segments(_ paths:[DrawingPath]) -> [DrawingDistance] {
        paths.filter { !$0.isPointCollection }.flatMap { path in
            zip(path.points,path.points.dropFirst()).enumerated().compactMap { index,pair in
                let delta=pair.1-pair.0
                let distance=simd_length(delta)
                guard distance.isFinite, distance > 0 else { return nil }
                // Vertex IDs persist through Undo/save/restore; do not create labels for point collections.
                var bytes=path.id.uuid
                let ordinal=UInt32(truncatingIfNeeded:index+1)
                bytes.12 ^= UInt8(truncatingIfNeeded:ordinal >> 24); bytes.13 ^= UInt8(truncatingIfNeeded:ordinal >> 16)
                bytes.14 ^= UInt8(truncatingIfNeeded:ordinal >> 8); bytes.15 ^= UInt8(truncatingIfNeeded:ordinal)
                let id=path.vertices.flatMap { $0.indices.contains(index+1) ? $0[index+1].id : nil } ?? UUID(uuid:bytes)
                return DrawingDistance(id:id,midpoint:(pair.0+pair.1)/2,metres:distance,
                                       horizontalMetres:simd_length(SIMD2(delta.x,delta.z)),verticalMetres:delta.y)
            }
        }
    }
}

/// Shared, sensor-independent depth rules for display fading (not point measurement).
enum LiDARFade {
    /// Coverage of the actual line samples. Unavailable depth leaves that portion visible.
    /// A single hidden sample must not fade an otherwise visible mesh as a whole.
    static func linearCoverage(accumulatedWeight: Float, sampleCount: Int) -> Float {
        guard sampleCount > 0, accumulatedWeight.isFinite else { return 0 }
        return max(0, min(1, accumulatedWeight / Float(sampleCount)))
    }

    static func sampledDepth(_ samples: [(depth:Float, confidence:UInt8?)]) -> Float? {
        let valid=samples.compactMap { sample -> Float? in
            guard let confidence=sample.confidence, confidence >= 1,
                  sample.depth.isFinite, sample.depth > 0.10, sample.depth < 20 else { return nil }
            return sample.depth
        }.sorted()
        guard valid.count >= 2 else { return nil }
        return valid[1] // Reject one isolated near pixel; preserve a small real occluder.
    }
    static func behindWeight(cameraPosition:SIMD3<Float>,realDepth:Float,trackingNormal:Bool) -> Float? {
        let virtualDepth = -cameraPosition.z
        guard trackingNormal, virtualDepth.isFinite, virtualDepth > 0.05,
              realDepth.isFinite, realDepth > 0.10 else { return nil }
        return max(0,min(1,(virtualDepth-realDepth-0.12)/0.18))
    }
}

enum DrawingSelection {
    static func hit(paths:[DrawingPath],tap:SIMD2<Float>,project:(SIMD3<Float>)->SIMD2<Float>?) -> UUID? {
        var best:(Float,UUID)?
        func offer(_ distance:Float,_ id:UUID,_ threshold:Float) {
            if distance <= threshold, best == nil || distance < best!.0 { best=(distance,id) }
        }
        // A visible standalone point takes precedence over a line passing through it.
        for path in paths where path.isPointCollection || path.points.count==1 {
            for point in path.points { if let p=project(point) { offer(simd_length(p-tap),path.id,20) } }
        }
        if let best { return best.1 }
        for path in paths {
            let screen=path.points.map(project)
            for p in screen.compactMap({ $0 }) { offer(simd_length(p-tap),path.id,20) }
            if !path.isPointCollection {
                for (a,b) in zip(screen,screen.dropFirst()) {
                    guard let a, let b else { continue }
                    let d=b-a, length=simd_length_squared(d)
                    guard length > 0.01 else { continue }
                    let t=max(0,min(1,simd_dot(tap-a,d)/length))
                    offer(simd_length(a+t*d-tap),path.id,16)
                }
            }
        }
        return best?.1
    }
}

// Two alternating generations. Each replacement is atomic; a damaged latest generation
// falls back to the previous complete snapshot. An interrupted write cannot delete both.
struct AtomicWorkStore {
    let directory: URL
    struct Envelope: Codable { var revision: Int; var payload: Data; var checksum: UInt64 }
    static func checksum(_ data: Data) -> UInt64 { data.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 } }
    func candidates() -> [Envelope] {
        (0...1).compactMap { slot in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("work-\(slot).json")),
                  let e = try? JSONDecoder().decode(Envelope.self,from:data),
                  Self.checksum(e.payload) == e.checksum else { return nil }
            return e
        }.sorted { $0.revision > $1.revision }
    }
    func save(_ payload: Data) throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories:true)
        let revision = (candidates().first?.revision ?? 0)+1
        let e = Envelope(revision:revision,payload:payload,checksum:Self.checksum(payload))
        try JSONEncoder().encode(e).write(to:directory.appendingPathComponent("work-\(revision%2).json"),options:.atomic)
    }
}
