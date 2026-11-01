import Foundation
import simd

// Independent first-stage core. World values use the raw ARKit session basis,
// in metres, Y-up. Camera points use image-right X, image-up Y, forward -Z.
// No geographic axes or external/survey coordinates are implied.
struct GCPVector: Codable, Equatable {
    var x: Double; var y: Double; var z: Double
    init(_ x:Double=0,_ y:Double=0,_ z:Double=0) {self.x=x;self.y=y;self.z=z}
    init(_ v:SIMD3<Double>) {self.init(v.x,v.y,v.z)}
    var v:SIMD3<Double> {SIMD3(x,y,z)}
    var finite:Bool {x.isFinite && y.isFinite && z.isFinite}
}
struct GCPEpoch: Codable, Hashable {
    var arSessionID=UUID()
    var generation=0
    var alignmentRevision=0
}
struct GCPPose: Codable, Equatable {
    var position=GCPVector()
    var qx=0.0; var qy=0.0; var qz=0.0; var qw=1.0
    var rotation:simd_quatd {simd_normalize(simd_quatd(ix:qx,iy:qy,iz:qz,r:qw))}
    var valid:Bool {
        position.finite && simd_length(position.v)<=1e6 && [qx,qy,qz,qw].allSatisfy(\.isFinite)
            && abs(qx*qx+qy*qy+qz*qz+qw*qw-1)<1e-6
    }
}
struct GCPIntrinsics: Codable, Equatable {
    var width:Int; var height:Int
    var fx:Double; var fy:Double; var cx:Double; var cy:Double
    func cameraPoint(x:Double,y:Double,z:Double) throws -> SIMD3<Double> {
        guard width>0,height>0,[fx,fy,cx,cy,x,y,z].allSatisfy(\.isFinite),
              fx>0,fy>0,x>=0,y>=0,x<Double(width),y<Double(height) else {throw GCPFailure.calibration}
        // z is optical-axis depth, NOT range along a normalized bearing.
        let point=SIMD3((x-cx)*z/fx,-(y-cy)*z/fy,-z)
        guard point.x.isFinite,point.y.isFinite,point.z.isFinite else {throw GCPFailure.calibration}
        return point
    }
}
enum GCPTracking:String,Codable {case normal,limited,relocalizing,unavailable}
enum GCPDepthConfidence:String,Codable {case low,medium,high}
struct GCPDepth:Codable,Equatable {
    var cameraZ:Double
    var confidence:GCPDepthConfidence
    var neighbourhoodSpread:Double
    var boundaryRisk:Bool
}
enum GCPMatchPolicy:String,Codable {case conservative,scanOneMetre}
struct GCPAssociationEvidence:Codable,Equatable {
    var policy:GCPMatchPolicy
    var directionOnly:Bool
    var candidates:[UUID]
    var outcome:String
    var matchedPointID:UUID? = nil
}
struct GCPObservation:Codable,Equatable,Identifiable {
    var id=UUID()
    var epoch:GCPEpoch
    var time:Double
    var pose:GCPPose
    var intrinsics:GCPIntrinsics
    var pixelX:Double
    var pixelY:Double
    var tracking:GCPTracking
    var depth:GCPDepth?
    var captureEvidence:GCPCaptureEvidence? = nil
    var associationEvidence:GCPAssociationEvidence? = nil
    func ray() throws -> GCPRay {
        guard pose.valid,time.isFinite,time>=0,epoch.generation>=0,epoch.alignmentRevision>=0 else {throw GCPFailure.invalidObservation}
        let p=try intrinsics.cameraPoint(x:pixelX,y:pixelY,z:1)
        guard simd_length(p).isFinite,simd_length(p)>0 else {throw GCPFailure.calibration}
        return GCPRay(origin:pose.position.v,direction:pose.rotation.act(simd_normalize(p)))
    }
    func depthPoint() throws -> SIMD3<Double> {
        _=try ray()
        guard let depth,depth.cameraZ.isFinite,depth.neighbourhoodSpread.isFinite else {throw GCPFailure.depthUnavailable}
        return pose.position.v+pose.rotation.act(try intrinsics.cameraPoint(x:pixelX,y:pixelY,z:depth.cameraZ))
    }
}
struct GCPRay {var origin:SIMD3<Double>;var direction:SIMD3<Double>}
struct GCPTriangulation:Codable,Equatable {
    var position:GCPVector
    var baseline:Double
    var angleRadians:Double
    var closestDistance:Double
    var firstDistance:Double
    var secondDistance:Double
    var conditionNumber:Double
}
struct GCPCaptureOperation:Codable,Equatable,Identifiable {
    var id=UUID()
    var observationIDs:[UUID]
    var pointID:UUID
    var registered:Bool
}
struct GCPCaptureCancellation:Codable,Equatable,Identifiable {
    var id=UUID()
    var operationID:UUID?
    var observationIDs:[UUID]
}
struct GCPPoint:Codable,Equatable,Identifiable {
    var id=UUID()
    var epoch:GCPEpoch
    var position:GCPVector
    var registrationObservationID:UUID
    var registrationTranslation=GCPVector()
    var secondRegistrationObservationID:UUID? = nil
    var triangulation:GCPTriangulation? = nil
    var referenceDescription:String {"ローカル基準点（外部既知座標なし）"}
}
struct GCPTrajectorySample:Codable,Equatable,Identifiable {
    var id=UUID()
    var epoch:GCPEpoch
    var time:Double
    var rawPose:GCPPose
    var tracking:GCPTracking
    var frameID:UUID? = nil
    var cameraTransform:[Double]? = nil
}
enum GCPCoordinates:String,Codable {case arkitLocalMetres}
struct GCPRawSession:Codable,Equatable,Identifiable {
    var schema=1
    var coordinates=GCPCoordinates.arkitLocalMetres
    var id=UUID()
    var observations:[GCPObservation]=[]
    var points:[GCPPoint]=[]
    var trajectory:[GCPTrajectorySample]=[]
    // Optional for older recordings. Raw evidence is never removed on undo.
    var captureOperations:[GCPCaptureOperation]? = nil
    var captureCancellations:[GCPCaptureCancellation]? = nil
    var activePoints:[GCPPoint] {
        let cancelled=Set((captureCancellations ?? []).compactMap(\.operationID))
        let hidden=Set((captureOperations ?? []).filter {$0.registered && cancelled.contains($0.id)}.map(\.pointID))
        return points.filter {!hidden.contains($0.id)}
    }
    func isObservationActive(_ id:UUID)->Bool {
        observations.contains {$0.id==id} && !(captureCancellations ?? []).contains {$0.observationIDs.contains(id)}
    }
    func activeBindings(_ bindings:[GCPBinding])->[GCPBinding] {
        let ids=Set(activePoints.map(\.id))
        return bindings.filter {ids.contains($0.pointID) && isObservationActive($0.observationID)}
    }
}
struct GCPBinding:Codable,Equatable,Hashable {
    var observationID:UUID
    var pointID:UUID
    /// Preserve rejected depth evidence, but explicitly constrain bearing only.
    var directionOnly=false
}
struct GCPFitContext:Codable,Equatable {
    var epoch:GCPEpoch
    /// Adapter must explicitly attest a short interval of stable relative AR poses.
    var relativePoseTrusted:Bool
}
struct GCPTranslationFit:Codable,Equatable {
    var policyVersion=1
    var context:GCPFitContext
    var bindings:[GCPBinding]
    var translation:GCPVector
    var rank:Int
    var information:[Double]
    var unconstrainedDirections:[GCPVector]
    var conditionNumber:Double?
    var firstTime:Double
    var lastTime:Double
    var lastPose:GCPPose
}
struct GCPAdjustment:Codable,Equatable,Identifiable {
    var id=UUID()
    var fit:GCPTranslationFit
    var trajectoryIDs:[UUID]
    var startTranslation=GCPVector()
    /// Derived, never substituted into raw poses/observations.
    var offsets:[GCPVector]
}
struct GCPChange:Codable,Equatable,Identifiable {
    enum Kind:String,Codable {case apply,cancel}
    var id=UUID()
    var kind:Kind
    var adjustmentID:UUID
    var adjustment:GCPAdjustment?
}
struct GCPJournal:Codable,Equatable {
    var schema=1
    var sessionID:UUID
    var changes:[GCPChange]=[]
    func active(epoch:GCPEpoch?=nil) throws -> [GCPAdjustment] {
        var active:[UUID:GCPAdjustment]=[:],seen=Set<UUID>(),applied=Set<UUID>()
        for change in changes {
            guard seen.insert(change.id).inserted else {throw GCPFailure.invalidJournal}
            switch change.kind {
            case .apply:
                guard let a=change.adjustment,a.id==change.adjustmentID,applied.insert(a.id).inserted else {throw GCPFailure.invalidJournal}
                guard !active.values.contains(where:{$0.fit.context.epoch==a.fit.context.epoch && !Set($0.trajectoryIDs).isDisjoint(with:a.trajectoryIDs)}) else {throw GCPFailure.doubleCorrection}
                active[a.id]=a
            case .cancel:
                guard change.adjustment==nil,active.removeValue(forKey:change.adjustmentID) != nil else {throw GCPFailure.invalidJournal}
            }
        }
        return active.values.filter {epoch==nil || $0.fit.context.epoch==epoch}.sorted {$0.id.uuidString<$1.id.uuidString}
    }
}
struct GCPClosure:Codable,Equatable {
    var epoch:GCPEpoch
    var from:UUID;var to:UUID
    var delta:GCPVector
}
enum GCPFailure:String,Error,Codable,Equatable {
    case calibration,invalidObservation,tracking,depthUnavailable,depthQuality,generationMismatch
    case ambiguous,noMatch,unknownReference,relativePoseUntrusted,intervalTooLong
    case insufficientBaseline,parallelDirections,illConditioned,behindCamera,residualTooLarge,translationTooLarge
    case incompleteTranslation,invalidTrajectory,zeroDistance,trajectoryOutlier,closureMismatch
    case invalidSession,invalidJournal,doubleCorrection,originalsImmutable,corruptStore,unsupportedSchema,foreignStore
}
