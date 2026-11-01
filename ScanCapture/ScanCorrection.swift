import Foundation
import simd

struct ScanCorrectionScope:Codable,Equatable {
    var adjustmentID:UUID
    var segmentID:UUID
    var segmentStart:Double
    var epoch:GCPEpoch
}
struct ScanCorrectionState:Codable,Equatable {
    var journal:GCPJournal
    var scopes:[ScanCorrectionScope]=[]
}
struct ScanRecoverySource:Codable,Equatable {
    var sessionID:UUID
    var packetID:UUID
    var packetChecksum:UInt64
    var retainedIssues:[String]
    var limitation="Verified committed prefix copied; incomplete source files retained, not adopted as successful capture"
}
/// Translation only. Every evaluation starts from immutable raw data, never from a previously corrected mesh.
enum ScanCorrection {
    static func empty(_ id:UUID)->ScanCorrectionState {ScanCorrectionState(journal:GCPJournal(sessionID:id))}
    static func validateFit(_ fit:GCPTranslationFit,raw:GCPRawSession) throws {
        let expected=try GCPMath.fit(raw:raw,bindings:fit.bindings,context:fit.context)
        guard fit.policyVersion==expected.policyVersion,fit.rank==expected.rank,fit.firstTime==expected.firstTime,fit.lastTime==expected.lastTime,fit.lastPose==expected.lastPose,
              fit.information.count==expected.information.count,zip(fit.information,expected.information).allSatisfy({abs($0-$1)<1e-9}),
              fit.translation.finite,simd_length(fit.translation.v-expected.translation.v)<1e-9,
              fit.unconstrainedDirections.count==expected.unconstrainedDirections.count,
              zip(fit.unconstrainedDirections,expected.unconstrainedDirections).allSatisfy({simd_length($0.v-$1.v)<1e-9}),
              (fit.conditionNumber==nil && expected.conditionNumber==nil) || (fit.conditionNumber != nil && expected.conditionNumber != nil && abs(fit.conditionNumber!-expected.conditionNumber!)<1e-9*max(1,expected.conditionNumber!)) else {throw GCPFailure.invalidJournal}
    }
    static func validate(_ state:ScanCorrectionState,raw:GCPRawSession) throws {
        guard state.journal.changes.count<=64,state.scopes.count<=64,Set(state.scopes.map(\.adjustmentID)).count==state.scopes.count else {throw ScanFailure.capacity}
        try GCPStore(root:URL(fileURLWithPath:"/unused")).validateJournalForCapture(state.journal,raw:raw)
        let applied=state.journal.changes.compactMap(\.adjustment)
        guard Set(applied.map(\.id))==Set(state.scopes.map(\.adjustmentID)) else {throw GCPFailure.invalidJournal}
        for scope in state.scopes {
            guard scope.segmentStart.isFinite,scope.segmentStart>=0,
                  let a=applied.first(where:{$0.id==scope.adjustmentID}),a.fit.context.epoch==scope.epoch,
                  let first=raw.trajectory.first(where:{$0.id==a.trajectoryIDs.first}),first.time>=scope.segmentStart else {throw GCPFailure.generationMismatch}
        }
        let active=try state.journal.active()
        guard Set(active.map(\.fit.context.epoch)).count==active.count else {throw GCPFailure.doubleCorrection}
    }
    static func replacing(_ state:ScanCorrectionState,fit:GCPTranslationFit,raw:GCPRawSession,segmentID:UUID,start:Double,epoch:GCPEpoch) throws -> ScanCorrectionState {
        try validate(state,raw:raw);try validateFit(fit,raw:raw)
        guard fit.rank==3 else {throw GCPFailure.incompleteTranslation}
        guard fit.context.epoch==epoch else {throw GCPFailure.generationMismatch}
        guard state.journal.changes.count<=60 else {throw ScanFailure.capacity}
        let samples=raw.trajectory.filter {$0.epoch==epoch && $0.time>=start && $0.time<=fit.lastTime}
        let adjustment=try GCPMath.adjustment(fit:fit,samples:samples)
        var next=state
        // Replace this epoch's whole field; do not sum overlapping drift estimates.
        for old in try state.journal.active(epoch:epoch) {next.journal.changes.append(GCPChange(kind:.cancel,adjustmentID:old.id,adjustment:nil))}
        next.journal.changes.append(GCPChange(kind:.apply,adjustmentID:adjustment.id,adjustment:adjustment))
        next.scopes.append(ScanCorrectionScope(adjustmentID:adjustment.id,segmentID:segmentID,segmentStart:start,epoch:epoch))
        try validate(next,raw:raw);return next
    }
    static func cancellingLast(_ state:ScanCorrectionState,raw:GCPRawSession) throws -> ScanCorrectionState {
        try validate(state,raw:raw);let active=Set(try state.journal.active().map(\.id))
        guard state.journal.changes.count<64,let last=state.journal.changes.last(where:{$0.kind == .apply && active.contains($0.adjustmentID)}) else {throw GCPFailure.invalidJournal}
        var next=state;next.journal.changes.append(GCPChange(kind:.cancel,adjustmentID:last.adjustmentID,adjustment:nil));try validate(next,raw:raw);return next
    }
    static func offset(_ state:ScanCorrectionState,raw:GCPRawSession,segmentID:UUID,epoch:GCPEpoch,time:Double) throws -> GCPVector {
        guard time.isFinite,time>=0 else {throw GCPFailure.invalidTrajectory}
        let scopes=state.scopes.filter {$0.segmentID==segmentID && $0.epoch==epoch}
        let active=try state.journal.active(epoch:epoch).filter {a in scopes.contains(where:{$0.adjustmentID==a.id})}
        guard active.count<=1 else {throw GCPFailure.doubleCorrection}
        guard let a=active.first else {return GCPVector()}
        let samples=try a.trajectoryIDs.map {id -> GCPTrajectorySample in guard let s=raw.trajectory.first(where:{$0.id==id}) else {throw GCPFailure.invalidTrajectory};return s}
        // Recalculate the path-distance field, even after append/reload/cancel.
        let computed=try GCPMath.adjustment(fit:try GCPMath.fit(raw:raw,bindings:a.fit.bindings,context:a.fit.context),samples:samples,start:a.startTranslation)
        guard let first=samples.first,let last=samples.last else {throw GCPFailure.invalidTrajectory}
        if time<=first.time {return computed.startTranslation}
        if time>=last.time {return computed.fit.translation} // hold, never extrapolate into another epoch
        let upper=samples.firstIndex(where:{$0.time>=time})!,lower=upper-1
        let ratio=(time-samples[lower].time)/(samples[upper].time-samples[lower].time)
        return GCPVector(computed.offsets[lower].v+(computed.offsets[upper].v-computed.offsets[lower].v)*ratio)
    }
}
struct ScanNormalDerivation:Codable,Equatable {
    var policy="flat_face_winding_v1; no outward orientation guarantee"
    var sourceStatus:ScanNormalStatus
    var sourceVertices:Int
    var sourceFaces:Int
    var unreferencedSourceVertices:Int
    var unrepresentedVertices:Int
    var omittedDegenerateFaces:Int
    var sourceFaceIDs:[Int]
}
struct ScanDerivedMesh:Codable,Equatable {
    var anchorID:UUID
    var sourceFingerprint:UInt64
    /// Little-endian Float64 XYZ in raw ARKit world plus the snapshot's one translation.
    var worldVertices:Data
    var worldNormals:Data
    var indices:Data
    var normalDerivation:ScanNormalDerivation? = nil
    func validate() throws {
        guard worldVertices.count%24==0,worldNormals.count==worldVertices.count,indices.count%12==0,worldVertices.count/24<=ScanShape.maximumDerivedVertices else {throw ScanFailure.invalidGeometry}
        let count=worldVertices.count/24
        for i in 0..<count {
            let v=ScanShape.vector(worldVertices,i),n=ScanShape.vector(worldNormals,i)
            guard v.x.isFinite,v.y.isFinite,v.z.isFinite,n.x.isFinite,n.y.isFinite,n.z.isFinite,abs(simd_length(n)-1)<1e-6 else {throw ScanFailure.invalidGeometry}
        }
        for i in stride(from:0,to:indices.count,by:4) {guard ScanMesh.word(indices,i)<count else {throw ScanFailure.invalidGeometry}}
        if let d=normalDerivation {
            let s=d.sourceStatus
            guard d.policy=="flat_face_winding_v1; no outward orientation guarantee",s.schema==1,s.policy=="raw_missing_normals; derive_flat_faces_only_for_export_v1",
                  d.sourceVertices>0,d.sourceVertices<=131072,d.sourceFaces>=0,d.sourceFaces<=262144,
                  s.nonfiniteScalars>0,s.nonfiniteScalars<=d.sourceVertices*3,s.missingVertices>0,s.missingVertices<=d.sourceVertices,s.missingVertices<=s.nonfiniteScalars,s.nonfiniteScalars<=s.missingVertices*3,s.firstScalar>=0,s.firstScalar<d.sourceVertices*3,
                  d.sourceFaceIDs.count==indices.count/12,count==d.sourceFaceIDs.count*3,
                  d.omittedDegenerateFaces>=0,d.omittedDegenerateFaces<=d.sourceFaces,d.sourceFaceIDs.count==d.sourceFaces-d.omittedDegenerateFaces,
                  d.unreferencedSourceVertices>=0,d.unreferencedSourceVertices<=d.unrepresentedVertices,d.unrepresentedVertices<=d.sourceVertices,
                  d.sourceFaceIDs.allSatisfy({$0>=0 && $0<d.sourceFaces}),zip(d.sourceFaceIDs,d.sourceFaceIDs.dropFirst()).allSatisfy({$0<$1}) else {throw ScanFailure.invalidGeometry}
            for i in 0..<count {guard ScanMesh.word(indices,i*4)==i else {throw ScanFailure.invalidGeometry}}
        }
    }
}
struct ScanMeshTimeEvidence:Codable,Equatable {
    var anchorID:UUID
    var observedFrom:Double
    var observedAt:Double
}
struct ScanDerivedSnapshot:Codable,Equatable {
    var segmentID:UUID
    var epoch:GCPEpoch
    var frameID:UUID
    var time:Double
    var offset:GCPVector
    var camera:[Double]
    var meshes:[ScanDerivedMesh]
    var segmentStart:Double? = nil
    var sourceMeshIntervals:[ScanMeshTimeEvidence]=[]
    var policy="rigid_snapshot_at_frame_reference; not per-vertex acquisition times"
    func validateMeshes() throws {
        var total=0
        guard Set(meshes.map(\.anchorID)).count==meshes.count else {throw ScanFailure.invalidGeometry}
        for mesh in meshes {
            let count=mesh.worldVertices.count/24
            guard count<=ScanShape.maximumDerivedVertices-total else {throw ScanFailure.capacity};total+=count
        }
        for mesh in meshes {try mesh.validate()}
    }
}
enum ScanShape {
    static let maximumDerivedVertices=262144
    static func vector(_ data:Data,_ index:Int)->SIMD3<Double> {data.withUnsafeBytes {p in SIMD3((0..<3).map {Double(bitPattern:UInt64(littleEndian:p.loadUnaligned(fromByteOffset:index*24+$0*8,as:UInt64.self)))})}}
    private static func append(_ value:SIMD3<Double>,to data:inout Data) {for component in [value.x,value.y,value.z] {var bits=component.bitPattern.littleEndian;withUnsafeBytes(of:&bits) {data.append(contentsOf:$0)}}}
    static func make(meshes:[ScanMesh],frame:ScanFrameInfo,segmentID:UUID,epoch:GCPEpoch,state:ScanCorrectionState,raw:GCPRawSession,limits:ScanLimits=ScanLimits()) throws -> ScanDerivedSnapshot {
        try frame.validate();try ScanCorrection.validate(state,raw:raw)
        let shift=try ScanCorrection.offset(state,raw:raw,segmentID:segmentID,epoch:epoch,time:frame.time)
        var result:[ScanDerivedMesh]=[],total=0,derivedTotal=0
        for mesh in meshes.sorted(by:{$0.anchorID.uuidString<$1.anchorID.uuidString}) {
            try mesh.validate(limits);total+=mesh.vertices.count/12;guard total<=limits.maximumVertices else {throw ScanFailure.capacity}
            let m=simd_double4x4((0..<4).map {c in SIMD4((0..<4).map {mesh.transform[c*4+$0]})})
            var vertices=Data(),normals=Data()
            if let status=mesh.normalStatus {
                var indices=Data(),sourceFaces:[Int]=[],used=Set<Int>(),represented=Set<Int>()
                func read(_ i:Int)->SIMD3<Double> {SIMD3((0..<3).map {Double(Float(bitPattern:ScanMesh.word(mesh.vertices,i*12+$0*4)))})}
                for offset in stride(from:0,to:mesh.indices.count,by:12) {
                    let ids=(0..<3).map {Int(ScanMesh.word(mesh.indices,offset+$0*4))};used.formUnion(ids)
                    let local=ids.map(read),ab=local[1]-local[0],ac=local[2]-local[0],cross=simd_cross(ab,ac)
                    let length=simd_length(cross),scale=max(simd_length_squared(ab),simd_length_squared(ac))
                    // Selection is anchor-local, identical before/after GCP translation.
                    guard length.isFinite,length>max(1e-12,scale*1e-10) else {continue}
                    guard derivedTotal<=maximumDerivedVertices-3 else {throw ScanFailure.capacity}
                    let n=m*SIMD4(cross/length,0),worldNormal=simd_normalize(SIMD3(n.x,n.y,n.z))
                    for v in local {
                        let world=m*SIMD4(v,1);append(SIMD3(world.x,world.y,world.z)+shift.v,to:&vertices);append(worldNormal,to:&normals)
                        var index=UInt32(indices.count/4).littleEndian;withUnsafeBytes(of:&index) {indices.append(contentsOf:$0)}
                    }
                    derivedTotal+=3;sourceFaces.append(offset/12);represented.formUnion(ids)
                }
                let count=mesh.vertices.count/12
                let evidence=ScanNormalDerivation(sourceStatus:status,sourceVertices:count,sourceFaces:mesh.indices.count/12,unreferencedSourceVertices:count-used.count,unrepresentedVertices:count-represented.count,omittedDegenerateFaces:mesh.indices.count/12-sourceFaces.count,sourceFaceIDs:sourceFaces)
                let derived=ScanDerivedMesh(anchorID:mesh.anchorID,sourceFingerprint:mesh.fingerprint,worldVertices:vertices,worldNormals:normals,indices:indices,normalDerivation:evidence)
                try derived.validate();result.append(derived);continue
            }
            guard derivedTotal<=maximumDerivedVertices-mesh.vertices.count/12 else {throw ScanFailure.capacity};derivedTotal+=mesh.vertices.count/12
            for i in 0..<(mesh.vertices.count/12) {
                func read(_ data:Data)->SIMD3<Double> {SIMD3((0..<3).map {Double(Float(bitPattern:ScanMesh.word(data,i*12+$0*4)))})}
                let v=read(mesh.vertices),n=read(mesh.normals),world=m*SIMD4(v,1),normal=m*SIMD4(n,0)
                let nn=SIMD3(normal.x,normal.y,normal.z)
                guard simd_length(nn)>1e-9 else {throw ScanFailure.invalidGeometry}
                append(SIMD3(world.x,world.y,world.z)+shift.v,to:&vertices);append(simd_normalize(nn),to:&normals)
            }
            let derived=ScanDerivedMesh(anchorID:mesh.anchorID,sourceFingerprint:mesh.fingerprint,worldVertices:vertices,worldNormals:normals,indices:mesh.indices)
            try derived.validate();result.append(derived)
        }
        var camera=frame.camera;camera[12]+=shift.x;camera[13]+=shift.y;camera[14]+=shift.z
        return ScanDerivedSnapshot(segmentID:segmentID,epoch:epoch,frameID:frame.frameID,time:frame.time,offset:shift,camera:camera,meshes:result)
    }
}
