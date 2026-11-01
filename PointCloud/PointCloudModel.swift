import Foundation
import simd
import CoreGraphics

/// Independent immutable input format. Coordinates: ARKit local metres, Y up,
/// camera forward -Z. No geographic coordinates or accuracy guarantee.
/// Shared capture/read limits. Display budgets never discard persisted vertices.
enum PCLimits {
    static let maximumFrames=2_400
    static let maximumPoints=20_000_000
    static let maximumRecordBytes:Int64=5*1024*1024*1024
    static let maximumRecordEntries=16_000
    static let maximumCheckpointBytes=32*1024*1024
    static let maximumEventBytes=48*1024*1024
    static let maximumTrajectorySamples=16_384
    static let maximumPreviewPoints=2_000_000
    static let maximumLivePoints=50_000
}
/// Batched camera-facing points, not a mesh sphere or node per measurement.
/// World size is a display cue only; screen clamps bound fill rate/obstruction.
/// Capture coordinates and persisted RGB never depend on these display values.
enum PCCoverageDisplayStyle {
    static let opacity:CGFloat=1
    static let renderScale:CGFloat=1
    static let pointDiameterMetres:CGFloat=0.03
    // Metal raster calibration: SceneKit uses this local-space pointSize as
    // a radius. Keep the user-facing world diameter separate from that API.
    static let nativePointSize:CGFloat=pointDiameterMetres/2
    static let minimumPointRadius:CGFloat=1
    static let pointRadius:CGFloat=7
    // Retained only by the legacy build70 comparison helper; no live rim nodes.
    static let outlineRadius:CGFloat=3.5
}
enum PCFailure: String, Error {case invalidInput,unsupportedColour,capacity,recordLimit,storageSpace,corrupt,empty,interrupted,cancelled,correctionUnavailable,foreignEpoch}
enum PCMessage {
    static func error(_ error:Error)->String {
        if let e=error as? PCFailure {
            switch e {
            case .invalidInput:return "同じフレームの入力や時刻・姿勢を確認できません"
            case .unsupportedColour:return "画像の色形式が対応範囲外です"
            case .capacity:return "保存領域へ書き込めません。空き容量と保存状態を確認してください"
            case .recordLimit:return "この記録の上限（2,000万点・2,400枚・5GiB）です"
            case .storageSpace:return "端末の空き容量が不足しています（256MiBを保護します）"
            case .corrupt:return "保存内容の整合性を確認できません。原本は保持しています"
            case .empty:return "保存できる有効な深度点がありません"
            case .interrupted:return "処理を完了できませんでした。保存途中の内容を保持しています"
            case .cancelled:return "処理を取り消しました"
            case .correctionUnavailable:return "補正に必要なGCP再観測、または前後の自動フレームが不足しています"
            case .foreignEpoch:return "追跡の座標系が異なるため結合しません"
            }
        }
        if let e=error as? GCPFailure {return "GCP補正を確定できません（\(e.rawValue)）"}
        return error.localizedDescription
    }

}
struct PCFrame: Codable, Equatable, Identifiable {
    var id=UUID()
    var sourceCameraTransform:[Double]? = nil
    var sourceCameraIntrinsics:[Double]? = nil
    var sourceImageAttributes:[String:String]? = nil
    var time:Double
    var epoch:GCPEpoch
    var automatic:Bool
    var pose:GCPPose
    var intrinsics:GCPIntrinsics
    var depthWidth:Int; var depthHeight:Int
    var fullRange:Bool
    var colourMatrix:String // 709 or 601
    var transfer:String // 709 or sRGB, primaries are always 709
    var orientation:Int
    var imageToView:[Double]
    func validate() throws {
        let k=intrinsics
        guard time.isFinite,time>=0,pose.valid,k.width>0,k.height>0,k.width<=2048,k.height<=2048,
              k.width%2==0,k.height%2==0,k.width*k.height<=3_200_000,
              depthWidth>=3,depthHeight>=3,depthWidth<=512,depthHeight<=512,
              imageToView.count==6,imageToView.allSatisfy(\.isFinite),
              abs(imageToView[0]*imageToView[3]-imageToView[1]*imageToView[2])>1e-10,
              [1,2,3,4].contains(orientation),epoch.generation>=0 else {throw PCFailure.invalidInput}
        _=try k.cameraPoint(x:0,y:0,z:1)
        if let matrix=sourceCameraTransform {guard try GCPCaptureEvidence.pose(matrix)==pose else {throw PCFailure.invalidInput}}
        if let values=sourceCameraIntrinsics {
            guard values.count==9,values.allSatisfy(\.isFinite),values[0]==k.fx,values[4]==k.fy,values[6]==k.cx,values[7]==k.cy,
                  [1,2,3,5].allSatisfy({abs(values[$0])<1e-6}),abs(values[8]-1)<1e-6 else {throw PCFailure.invalidInput}
        }
        guard ["709","601"].contains(colourMatrix),["709","sRGB"].contains(transfer) else {throw PCFailure.unsupportedColour}
    }
}
struct PCRawFrame {var frame:PCFrame;var image:Data;var depth:Data;var confidence:Data}
struct PCVertex:Equatable {
    var position:SIMD3<Float>;var r:UInt8;var g:UInt8;var b:UInt8
    static let stride=15
    func append(to data:inout Data) {
        for v in [position.x,position.y,position.z] {var b=v.bitPattern.littleEndian;withUnsafeBytes(of:&b){data.append(contentsOf:$0)}}
        data.append(contentsOf:[r,g,b])
    }
    static func decode(_ data:Data)throws->[PCVertex] {
        guard data.count%stride==0,data.count<=512*512*stride else {throw PCFailure.corrupt}
        return try data.withUnsafeBytes {b in try strideThrough(data.count).map {i in
            let p=SIMD3<Float>(Float(bitPattern:UInt32(littleEndian:b.loadUnaligned(fromByteOffset:i,as:UInt32.self))),Float(bitPattern:UInt32(littleEndian:b.loadUnaligned(fromByteOffset:i+4,as:UInt32.self))),Float(bitPattern:UInt32(littleEndian:b.loadUnaligned(fromByteOffset:i+8,as:UInt32.self))))
            guard p.x.isFinite,p.y.isFinite,p.z.isFinite,simd_length(p)<1e6 else {throw PCFailure.corrupt}
            return PCVertex(position:p,r:b[i+12],g:b[i+13],b:b[i+14])
        }}
    }
    private static func strideThrough(_ count:Int)->[Int] {Array(Swift.stride(from:0,to:count,by:stride))}
}
enum PCProjection {
    /// Only measured high-confidence, non-edge depth contributes. Holes remain holes.
    static func vertices(_ raw:PCRawFrame,sampleStep:Int=2)throws->[PCVertex] {
        let f=raw.frame;try f.validate();let w=f.depthWidth,h=f.depthHeight,k=f.intrinsics,n=w*h
        guard sampleStep>=1,sampleStep<=16,raw.depth.count==n*4,raw.confidence.count==n,
              raw.image.count==k.width*k.height*3/2 else {throw PCFailure.invalidInput}
        let depths:[Float]=raw.depth.withUnsafeBytes {b in (0..<n).map {Float(bitPattern:UInt32(littleEndian:b.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self)))}}
        let kr=f.colourMatrix=="709" ? 0.2126:0.299,kb=f.colourMatrix=="709" ? 0.0722:0.114
        func channel(_ value:Double)->UInt8 {
            var v=max(0,min(1,value/255))
            if f.transfer=="709" {let linear=v<0.081 ? v/4.5:pow((v+0.099)/1.099,1/0.45);v=linear<=0.0031308 ? linear*12.92:1.055*pow(linear,1/2.4)-0.055}
            return UInt8(max(0,min(255,(v*255).rounded())))
        }
        var points:[PCVertex]=[];points.reserveCapacity(n/(sampleStep*sampleStep))
        for y in stride(from:1,to:h-1,by:sampleStep) {for x in stride(from:1,to:w-1,by:sampleStep) {
            let index=y*w+x,z=Double(depths[index])
            guard z.isFinite,z>=0.15,z<=12,raw.confidence[index]==2 else {continue}
            var valid=true
            for dy in -1...1 {for dx in -1...1 {let q=(y+dy)*w+x+dx,d=Double(depths[q]);if !d.isFinite || raw.confidence[q] != 2 || abs(d-z)>max(0.03,z*0.02) {valid=false}}}
            guard valid else {continue}
            let px=(Double(x)+0.5)*Double(k.width)/Double(w),py=(Double(y)+0.5)*Double(k.height)/Double(h)
            let camera=try k.cameraPoint(x:px,y:py,z:z),world=f.pose.position.v+f.pose.rotation.act(camera)
            let ix=min(k.width-1,Int(px)),iy=min(k.height-1,Int(py)),c=k.width*k.height+(iy/2)*k.width+(ix/2)*2
            let yy=(Double(raw.image[iy*k.width+ix])-(f.fullRange ? 0:16))*(f.fullRange ? 1:255/219)
            let cb=(Double(raw.image[c])-128)*(f.fullRange ? 1:255/224),cr=(Double(raw.image[c+1])-128)*(f.fullRange ? 1:255/224)
            let r=yy+2*(1-kr)*cr,b=yy+2*(1-kb)*cb,g=(yy-kr*r-kb*b)/(1-kr-kb)
            points.append(PCVertex(position:SIMD3<Float>(world),r:channel(r),g:channel(g),b:channel(b)))
        }}
        return points
    }
}
/// Bounded acquisition telemetry, not an assertion that the physical cause is known.
struct PCIMUInputSummary:Codable,Equatable {
    var version=1
    var arFrames=0
    var framesWithSamples=0
    var framesWithMapping=0
    var sensorStatus:String? = nil
    var maximumSamples=0
    var newestSampleAge:Double? = nil
    var cameraAxes="CoreMotion portrait device axes to raw ARCamera via portrait viewMatrix"
    var valid:Bool {
        version==1 && arFrames>=0 && framesWithSamples>=0 && framesWithSamples<=arFrames &&
        framesWithMapping>=0 && framesWithMapping<=arFrames &&
        (sensorStatus.map{$0.utf8.count<=128} ?? true) && maximumSamples>=0 && maximumSamples<=400 &&
        (newestSampleAge.map{$0.isFinite && $0>=0 && $0<=60} ?? true) && cameraAxes.utf8.count<256
    }
}
struct PCCheckpoint:Codable,Equatable {
    var schema=1
    var raw:GCPRawSession
    var fits:[GCPTranslationFit]
    var stopped:Bool
    var reason:String
    var continuationID:UUID? = nil
    /// Heuristic pose steps, never a claim that ARKit reported a correction.
    /// Raw observations/points and historic fits remain unchanged.
    var poseEvents:[PCPosePulseEvent]? = nil
    /// Binary policy decisions; these never add a transform or block correction.
    var motionDecisions:[PCPoseMotionDecision]? = nil
    var motionDecisionCount:Int? = nil // Includes coalesced entries after the bounded sample.
    var imuInput:PCIMUInputSummary? = nil
}
struct PCSelection:Codable {var corrected:Bool;var offsets:[UUID:GCPVector];var continuationID:UUID? = nil}

/// Inverse of the top-left normalized viewport convention used by ARKit.
enum PCDisplayMapping {
    static func cameraImage(_ d:CGAffineTransform,width:Double,height:Double,outputWidth:Double,outputHeight:Double)->CGAffineTransform {
        let W=outputWidth,H=outputHeight
        return CGAffineTransform(a:W*d.a/width,b:-H*d.b/width,c:-W*d.c/height,d:H*d.d/height,tx:W*(d.c+d.tx),ty:H*(1-d.d-d.ty))
    }
}

/// Stored RGB/PLY are encoded sRGB bytes. SceneKit's Metal renderer shades in
/// linear sRGB; direct vertex attributes are not colour-managed objects (unlike
/// UIColor/SwiftUI Color). Decode once, only when packing the shader buffer.
/// A 256-entry table avoids per-point powers for the full stopped preview.
enum PCDisplayColour {
    private static let linearTable:[Float]=(0...255).map { byte in
        let encoded=Double(byte)/255
        return Float(encoded<=0.04045 ? encoded/12.92:pow((encoded+0.055)/1.055,2.4))
    }
    static func linearSRGB(_ byte:UInt8)->Float {linearTable[Int(byte)]}
}

/// A stopped preview window contains every saved vertex in that range. Larger
/// archives use exact, non-overlapping windows. Packing runs on the store queue,
/// one frame/chunk at a time, never one giant array of the entire archive.
struct PCPreviewChunk {
    let id=UUID() // Immutable render-buffer identity, never persisted.
    var count:Int
    var positions:Data
    var colours:Data // Linear sRGB Float RGBA, alpha 1; never a persisted RGB format.
    var indices:Data
    var minimum:SIMD3<Float>
    var maximum:SIMD3<Float>
}
struct PCDetailPreview {
    var chunks:[PCPreviewChunk]=[]
    var count:Int=0
    var totalCount:Int?=nil
    var page:Int=0
    var pageCount:Int {max(1,((totalCount ?? count)+PCLimits.maximumPreviewPoints-1)/PCLimits.maximumPreviewPoints)}
    var isPartial:Bool {(totalCount ?? count)>count}
    var minimum=SIMD3<Float>(repeating:Float.infinity)
    var maximum=SIMD3<Float>(repeating:-Float.infinity)
    var packedBytes:Int {chunks.reduce(0){$0+$1.positions.count+$1.colours.count+$1.indices.count}}
    mutating func append(_ chunk:PCPreviewChunk) {
        chunks.append(chunk);count+=chunk.count;minimum=simd_min(minimum,chunk.minimum);maximum=simd_max(maximum,chunk.maximum)
    }
    var centre:SIMD3<Float> {count>0 ? (minimum+maximum)/2:.zero}
    var radius:Float {count>0 ? max(0.5,simd_length(maximum-minimum)/2):0.5}
}
enum PCPreviewPacking {
    static let chunkSize=16_384
    static let maximumPoints=PCLimits.maximumPreviewPoints // Bounded exact window; all saved points remain accessible.
    static func chunks(_ points:[PCVertex],offset:SIMD3<Float> = .zero,transform:PCControlTransform?=nil,poseTransform:PCPosePulseTransform?=nil,control:PCWorkControl=PCWorkControl())throws->[PCPreviewChunk] {
        var result:[PCPreviewChunk]=[]
        for start in stride(from:0,to:points.count,by:chunkSize) {
            try control.check()
            let end=min(start+chunkSize,points.count),count=end-start
            var p=Data(),c=Data(),ix=Data(),lo=SIMD3<Float>(repeating:Float.infinity),hi=SIMD3<Float>(repeating:-Float.infinity)
            p.reserveCapacity(count*12);c.reserveCapacity(count*16);ix.reserveCapacity(count*4)
            for i in start..<end {
                let v=points[i],base=poseTransform?.point(SIMD3<Double>(v.position)) ?? SIMD3<Double>(v.position)
                let position=transform.map{$0.display(base+SIMD3<Double>(offset))} ?? SIMD3<Float>(base+SIMD3<Double>(offset))
                guard position.x.isFinite,position.y.isFinite,position.z.isFinite else {throw PCFailure.corrupt}
                lo=simd_min(lo,position);hi=simd_max(hi,position)
                for value in [position.x,position.y,position.z] {var value=value;withUnsafeBytes(of:&value){p.append(contentsOf:$0)}}
                for value in [PCDisplayColour.linearSRGB(v.r),PCDisplayColour.linearSRGB(v.g),PCDisplayColour.linearSRGB(v.b),Float(1)] {var value=value;withUnsafeBytes(of:&value){c.append(contentsOf:$0)}}
                var index=UInt32(i-start);withUnsafeBytes(of:&index){ix.append(contentsOf:$0)}
            }
            result.append(PCPreviewChunk(count:count,positions:p,colours:c,indices:ix,minimum:lo,maximum:hi))
        }
        return result
    }
    static func load(store:PCStore,record:PCRecord,offsets:[UUID:GCPVector],transform:PCControlTransform?=nil,poseCorrected:Bool=false,page:Int=0,control:PCWorkControl=PCWorkControl(),progress:(Double)->Void={_ in})throws->PCDetailPreview {
        let record=poseCorrected ? try PCPoseCorrection.prepare(record):record
        let total=record.frames.reduce(0){$0+$1.pointCount}
        guard total<=PCLimits.maximumPoints,page>=0 else {throw PCFailure.recordLimit}
        let pages=max(1,(total+maximumPoints-1)/maximumPoints)
        guard page<pages else {throw PCFailure.invalidInput}
        let start=page*maximumPoints,end=min(total,start+maximumPoints)
        var result=PCDetailPreview();result.totalCount=total;result.page=page
        var ordinal=0
        for entry in record.frames {
            try control.check()
            let next=ordinal+entry.pointCount
            if next>start,ordinal<end {
                // At most one decoded frame plus 64 MB packed window, independent
                // of total archive size. No point in the selected range is thinned.
                try autoreleasepool {
                    let points=try store.points(entry,id:record.id)
                    let lo=max(0,start-ordinal),hi=min(points.count,end-ordinal)
                    let selected=Array(points[lo..<hi])
                    for chunk in try chunks(selected,offset:SIMD3<Float>((offsets[entry.id] ?? GCPVector()).v),transform:transform,poseTransform:poseCorrected ? record.poseTransforms[entry.id]:nil,control:control) {result.append(chunk)}
                }
                progress(Double(min(next,end)-start)/Double(max(1,end-start)))
            }
            ordinal=next
            if ordinal>=end {break}
        }
        try control.check();guard result.count==end-start else {throw PCFailure.corrupt};return result
    }
}
/// A bounded coverage layer made only from measured saved points. Voxel merging
/// changes display density, never raw RGB/XYZ or PLY. Empty space is not filled.
struct PCRecordingCoverage {
    private struct Cell:Hashable {var x:Int;var y:Int;var z:Int}
    private var cells:[Cell:PCVertex]=[:]
    private(set) var spacing:Float=0.08
    var count:Int {cells.count}
    var points:[PCVertex] {Array(cells.values)}
    private func key(_ p:SIMD3<Float>)->Cell {Cell(x:Int(floor(p.x/spacing)),y:Int(floor(p.y/spacing)),z:Int(floor(p.z/spacing)))}
    mutating func append(_ points:[PCVertex]) {
        // At most 2,048 representatives per saved frame; no invented endpoints.
        let step=max(1,Int(ceil(Double(points.count)/2048)))
        for i in stride(from:0,to:points.count,by:step) {
            let point=points[i];guard point.position.x.isFinite,point.position.y.isFinite,point.position.z.isFinite,simd_length(point.position)<1e6 else {continue}
            cells[key(point.position)]=point
        }
        while cells.count>PCLimits.maximumLivePoints {
            spacing*=2
            let old=cells;cells=[:];cells.reserveCapacity(PCLimits.maximumLivePoints)
            for point in old.values {cells[key(point.position)]=point}
        }
    }
    func packed()throws->PCDetailPreview {
        // Keep measured RGB once linearized, with no per-point alpha blend.
        var result=PCDetailPreview()
        for chunk in try PCPreviewPacking.chunks(points) {result.append(chunk)}
        return result
    }
}

/// Pick only real displayed vertices. Input is the same projection/view matrix
/// and viewport as the model camera; no screen-centre or camera focus heuristic.
enum PCOrbitPicking {
    static func point(chunks:[PCPreviewChunk],clipFromWorld:simd_float4x4,viewport:SIMD2<Float>,tap:SIMD2<Float>,radius:Float=22,control:PCWorkControl?=nil)->SIMD3<Float>? {
        guard viewport.x>0,viewport.y>0,radius>0 else {return nil}
        var chosen:SIMD3<Float>?,bestDepth=Float.infinity,bestDistance=Float.infinity
        for chunk in chunks {
            if let control,(try? control.check())==nil {return nil}
            chunk.positions.withUnsafeBytes {bytes in
                for i in 0..<chunk.count {
                    let p=SIMD3<Float>(bytes.loadUnaligned(fromByteOffset:i*12,as:Float.self),bytes.loadUnaligned(fromByteOffset:i*12+4,as:Float.self),bytes.loadUnaligned(fromByteOffset:i*12+8,as:Float.self))
                    let clip=clipFromWorld*SIMD4<Float>(p,1)
                    guard clip.w>0,clip.x.isFinite,clip.y.isFinite,clip.z.isFinite else {continue}
                    let n=SIMD3<Float>(clip.x,clip.y,clip.z)/clip.w
                    guard abs(n.x)<=1,abs(n.y)<=1,n.z>=(-1),n.z<=1 else {continue}
                    let screen=SIMD2<Float>((n.x+1)*viewport.x/2,(1-n.y)*viewport.y/2)
                    let d=simd_distance_squared(screen,tap)
                    guard d<=radius*radius else {continue}
                    // Prefer the visible front surface within a 2px picking tie.
                    if d<bestDistance-4 || (abs(d-bestDistance)<=4 && clip.w<bestDepth) {
                        chosen=p;bestDistance=d;bestDepth=clip.w
                    }
                }
            }
        }
        return chosen
    }
}

/// Viewer navigation only: preserve orientation, pan the picked point to the
/// optical axis, and move 15% closer. Raw/world/GCP coordinates never change.
enum PCOrbitFocus {
    static func camera(from pose:simd_float4x4,toward target:SIMD3<Float>,near:Float=0.02,zoom:Float=0.85)->simd_float4x4? {
        let columns=[pose.columns.0,pose.columns.1,pose.columns.2,pose.columns.3]
        guard columns.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite}),
              target.x.isFinite,target.y.isFinite,target.z.isFinite,near.isFinite,near>0,zoom>0,zoom<=1 else {return nil}
        let eye=SIMD3<Float>(pose.columns.3.x,pose.columns.3.y,pose.columns.3.z),back=SIMD3<Float>(pose.columns.2.x,pose.columns.2.y,pose.columns.2.z)
        let length=simd_length(back)
        guard length.isFinite,length>0.001 else {return nil}
        // Perspective size depends on forward depth, not distance to an
        // off-axis point. Using Euclidean distance could visibly zoom OUT at
        // the edge of a tall viewport even while moving closer in 3D.
        let depth=simd_dot(eye-target,back/length)
        guard depth.isFinite,depth>0.001 else {return nil}
        let minimum=max(0.10,near*4),next=depth<minimum ? depth:max(minimum,depth*zoom)
        let position=target+back/length*next
        guard position.x.isFinite,position.y.isFinite,position.z.isFinite else {return nil}
        var result=pose;result.columns.3=SIMD4<Float>(position,1);return result
    }
}

enum PCGCPDisplay {
    /// The marker origin is the GCP itself; only the child label is displaced.
    static func position(_ point:GCPPoint,corrected:Bool)->SIMD3<Float> {
        SIMD3<Float>(point.position.v-(corrected ? .zero:point.registrationTranslation.v))
    }
    static let labelOffset=SIMD3<Float>(0.035,0.035,0)
}
