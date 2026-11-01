import Foundation
import CoreVideo
import simd

/// Product-level suspension only. Preserve stored scans and shared measurement depth.
/// Re-enabling requires a source change; no saved preference can bypass this gate.
enum ScanFeatureAvailability {
    static let isEnabled = false
}

struct ScanLimits {
    var maximumImages=120
    var maximumImageSide=2048
    var maximumImagePixels=3_200_000
    var maximumImageBytes=8*1024*1024
    var maximumAnchors=64
    var maximumVertices=131_072
    var maximumIndices=786_432
    var maximumPacketBytes=32*1024*1024
    var maximumSessionBytes=512*1024*1024
    var minimumFreeBytes=512*1024*1024
    var maximumPendingFrames=2
    var maximumPendingBytes=48*1024*1024
    var interval=1.0
}
enum ScanFailure:String,Error {case capacity,lowSpace,queueFull,corrupt,foreignPath,incomplete,unsupportedImage,invalidGeometry,mixedFrame,busy,noSurface}
enum ScanMeshInputIssue:Error,Equatable {
    case notReady(String)
    case invalid(String)
    var message:String {
        switch self {
        case .notReady:return "メッシュ準備待ち"
        case .invalid:return "メッシュを確認できません"
        }
    }
    var diagnostic:String {
        switch self {
        case .notReady(let detail),.invalid(let detail):return message+" ["+detail+"]"
        }
    }
}
enum ScanErrorMessage {
    static func text(_ error:Error)->String {
        if let issue=error as? ScanExportFailure {return issue.message}
        if let issue=error as? ScanPackageFailure {return issue.message}
        if let issue=error as? ScanMeshInputIssue {return issue.message}
        guard let issue=error as? ScanFailure else {return "保存または記録の検証に失敗しました（原本は保持）"}
        switch issue {
        case .capacity:return "記録量の上限です"
        case .lowSpace:return "空き容量が不足しています"
        case .queueFull:return "保存待ちが上限です"
        case .unsupportedImage:return "画像の形式または大きさが保存範囲外です"
        case .invalidGeometry:return "メッシュの値を確認できません"
        case .mixedFrame:return "画像とカメラ情報の一致を確認できません"
        case .incomplete:return "保存途中のファイルを保持しています。確認が必要です"
        case .corrupt:return "保存内容の検証に失敗しました。原本を保持しています"
        case .foreignPath:return "専用の保存先を確認できません"
        case .busy:return "保存先を使用中です"
        case .noSurface:return "出力できる非退化面がありません。原本は保持しています"
        }
    }
}
enum ScanEvent:String,Codable {case began,capture,paused,ended,cancelled,correction}
struct ScanImageInfo:Codable,Equatable {
    var pixelFormat:UInt32
    var width:Int
    var height:Int
    var planeWidths:[Int]
    var planeHeights:[Int]
    var packedRowBytes:[Int]
    var attributes:[String:String]
    var byteCount:Int {zip(packedRowBytes,planeHeights).reduce(0) {$0+$1.0*$1.1}}
}
struct ScanFrameInfo:Codable,Equatable {
    var frameID:UUID
    var time:Double
    var camera:[Double]
    var intrinsics:[Double]
    var width:Int
    var height:Int
    var displayTransform:[Double]
    var viewport:[Double]
    var orientation:Int
    var tracking:GCPTracking
    var imageInfo:ScanImageInfo? = nil
    init(_ f:GCPFrameSnapshot) {
        frameID=f.frameID;time=f.time;camera=f.matrix
        intrinsics=(0..<3).flatMap {c in (0..<3).map {Double(f.intrinsics[c][$0])}}
        width=Int(f.imageSize.width);height=Int(f.imageSize.height)
        let t=f.imageToView;displayTransform=[t.a,t.b,t.c,t.d,t.tx,t.ty].map(Double.init)
        viewport=[Double(f.viewport.width),Double(f.viewport.height)];orientation=f.orientationToken;tracking=f.tracking
    }
    func validate() throws {
        _=try GCPCaptureEvidence.pose(camera)
        guard time.isFinite,time>=0,width>0,height>0,intrinsics.count==9,intrinsics.allSatisfy(\.isFinite),intrinsics[0]>0,intrinsics[4]>0,
              displayTransform.count==6,displayTransform.allSatisfy(\.isFinite),viewport.count==2,viewport.allSatisfy({$0.isFinite && $0>0}) else {throw ScanFailure.mixedFrame}
    }
}
/// Explicit missing attribute evidence. Raw normal Float32 bits remain untouched.
struct ScanNormalStatus:Codable,Equatable {
    var schema=1
    var policy="raw_missing_normals; derive_flat_faces_only_for_export_v1"
    var nonfiniteScalars:Int
    var missingVertices:Int
    var firstScalar:Int
    var sourceChecksum:UInt64
}
/// Little-endian float32 XYZ, raw normal XYZ, uint32 triangle indices; anchor-local.
struct ScanMesh:Codable,Equatable {
    var anchorID:UUID
    var transform:[Double]
    var vertices:Data
    var normals:Data
    var indices:Data
    var normalStatus:ScanNormalStatus? = nil
    var fingerprint:UInt64 {
        var matrix=Data();for number in transform {var bits=number.bitPattern.littleEndian;withUnsafeBytes(of:&bits) {matrix.append(contentsOf:$0)}}
        if let status=normalStatus {
            matrix.append(Data(status.policy.utf8))
            for value in [status.schema,status.nonfiniteScalars,status.missingVertices,status.firstScalar].map({UInt64(bitPattern:Int64($0))})+[status.sourceChecksum] {
                var bits=value.littleEndian;withUnsafeBytes(of:&bits) {matrix.append(contentsOf:$0)}
            }
        }
        return GCPStore.checksum(vertices+normals+indices+matrix)
    }
    var sourceNormalStatus:ScanNormalStatus? {
        guard normals.count%12==0 else {return nil}
        var count=0,first:Int?,missing=0
        for i in stride(from:0,to:normals.count,by:12) {
            var unavailable=false
            for c in 0..<3 where !Float(bitPattern:Self.word(normals,i+c*4)).isFinite {
                count+=1;unavailable=true;if first==nil {first=i/4+c}
            }
            if unavailable {missing+=1}
        }
        guard let first else {return nil}
        return ScanNormalStatus(nonfiniteScalars:count,missingVertices:missing,firstScalar:first,sourceChecksum:GCPStore.checksum(normals))
    }
    func validate(_ limits:ScanLimits) throws {
        _=try GCPCaptureEvidence.pose(transform)
        guard geometryIssue(limits,includeNormals:false)==nil,normalStatus==sourceNormalStatus else {throw ScanFailure.invalidGeometry}
    }
    /// Metadata only: no vertex positions, normal values or image content in diagnostics.
    func geometryIssue(_ limits:ScanLimits,includeNormals:Bool=true)->String? {
        guard !vertices.isEmpty,vertices.count%12==0,normals.count==vertices.count,vertices.count/12<=limits.maximumVertices,
              indices.count%12==0,indices.count/4<=limits.maximumIndices else {return "packed-size; vertexBytes=\(vertices.count),normalBytes=\(normals.count),indexBytes=\(indices.count)"}
        var issues:[String]=[]
        for (name,bytes) in [("vertex",vertices),("normal",normals)] {
            if name=="normal" && !includeNormals {continue}
            var invalid=0,first:Int?
            for i in stride(from:0,to:bytes.count,by:4) {
                if !Float(bitPattern:Self.word(bytes,i)).isFinite {invalid+=1;if first==nil {first=i/4}}
            }
            if let first {issues.append("\(name)-nonfinite; count=\(invalid),firstScalar=\(first)")}
        }
        var invalid=0,first:Int?,maximum:UInt32=0
        for i in stride(from:0,to:indices.count,by:4) {
            let value=Self.word(indices,i);maximum=max(maximum,value)
            if value>=vertices.count/12 {invalid+=1;if first==nil {first=i/4}}
        }
        if let first {issues.append("index-range; count=\(invalid),firstIndex=\(first),maxIndex=\(maximum),vertexCount=\(vertices.count/12)")}
        return issues.isEmpty ? nil:issues.joined(separator:"; ")
    }
    static func word(_ data:Data,_ offset:Int)->UInt32 {data.withUnsafeBytes {UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))}}
}
struct ScanMeshChange:Codable,Equatable {
    var anchorID:UUID
    /// Time interval of snapshots, NOT per-vertex acquisition timestamps.
    var observedFrom:Double
    var observedAt:Double
    var mesh:ScanMesh? // nil is a tombstone; prior snapshots remain immutable.
}
struct ScanMeshTracker {
    private var previous:[UUID:UInt64]=[:]
    private var lastTime:Double?
    mutating func reset() {previous=[:];lastTime=nil}
    mutating func changes(_ meshes:[ScanMesh],time:Double,start:Double,limits:ScanLimits) throws -> [ScanMeshChange] {
        guard time.isFinite,start.isFinite,time>=start,lastTime.map({time>$0}) ?? true,
              meshes.count<=limits.maximumAnchors,Set(meshes.map(\.anchorID)).count==meshes.count else {throw ScanFailure.invalidGeometry}
        var next:[UUID:UInt64]=[:],result:[ScanMeshChange]=[]
        var vertices=0,indices=0
        for mesh in meshes {
            try mesh.validate(limits);vertices+=mesh.vertices.count/12;indices+=mesh.indices.count/4
            guard vertices<=limits.maximumVertices,indices<=limits.maximumIndices else {throw ScanFailure.capacity}
            let hash=mesh.fingerprint;next[mesh.anchorID]=hash
            if previous[mesh.anchorID] != hash {result.append(ScanMeshChange(anchorID:mesh.anchorID,observedFrom:lastTime ?? start,observedAt:time,mesh:mesh))}
        }
        for id in previous.keys where next[id]==nil {result.append(ScanMeshChange(anchorID:id,observedFrom:lastTime ?? start,observedAt:time,mesh:nil))}
        previous=next;lastTime=time
        return result.sorted {$0.anchorID.uuidString<$1.anchorID.uuidString}
    }
}
struct ScanPacket:Codable,Equatable {
    var schema=1
    var id=UUID()
    var sessionID:UUID
    var sequence:Int
    var segmentID:UUID
    var segmentStart:Double
    var epoch:GCPEpoch
    var event:ScanEvent
    var reason:String?
    var time:Double
    var frame:ScanFrameInfo?
    var meshes:[ScanMeshChange]=[]
    var raw:GCPRawSession
    var hasImage=false
    var previewIssue:String? = nil
    var corrections:ScanCorrectionState? = nil
    var proposedFit:GCPTranslationFit? = nil
    var terminalEvent:ScanEvent? = nil
    var recoverySource:ScanRecoverySource? = nil
    var depthMap:ScanDepthMap? = nil
    var depthIssue:String? = nil
    var createdAt=Date()
}
struct ScanNativePayload {var meshes:[ScanMesh];var image:CVPixelBuffer;var depthMap:ScanDepthMap? = nil}
struct ScanRecovery {
    var sessionID:UUID
    var last:ScanPacket?
    var packets=0
    var images=0
    var previewFailures=0
    var normalWarnings=0
    var bytes=0
    var issues:[String]=[]
    var canResume:Bool {last != nil && issues.isEmpty && last?.event != .ended && last?.event != .cancelled && last?.terminalEvent != .ended && last?.terminalEvent != .cancelled}
}
/// Checked extraction handles arbitrary Metal buffer stride/offset, never pointer-casts packed SIMD3.
enum ScanGeometryReader {
    static func vectors(_ bytes:Data,offset:Int,stride:Int,count:Int,maximum:Int) throws -> Data {
        guard count>0,count<=maximum,offset>=0,stride>=12,offset<=bytes.count,
              count<=(bytes.count-offset-12)/stride+1,bytes.count-offset>=12 else {throw ScanFailure.invalidGeometry}
        var result=Data();result.reserveCapacity(count*12)
        for n in 0..<count {result.append(bytes[(offset+n*stride)..<(offset+n*stride+12)])}
        return result
    }
    static func triangles(_ bytes:Data,bytesPerIndex:Int,count:Int,maximum:Int) throws -> Data {
        guard [2,4].contains(bytesPerIndex),count>=0,count<=maximum,count%3==0,count<=bytes.count/bytesPerIndex else {throw ScanFailure.invalidGeometry}
        var result=Data();result.reserveCapacity(count*4)
        for n in 0..<count {
            var value:UInt32=bytes.withUnsafeBytes {b in bytesPerIndex==2 ? UInt32(UInt16(littleEndian:b.loadUnaligned(fromByteOffset:n*2,as:UInt16.self))) : UInt32(littleEndian:b.loadUnaligned(fromByteOffset:n*4,as:UInt32.self))}
            value=value.littleEndian;withUnsafeBytes(of:&value) {result.append(contentsOf:$0)}
        }
        return result
    }
}
