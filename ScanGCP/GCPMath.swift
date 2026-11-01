import Foundation
import simd

enum GCPMath {
    // Conservative initial acceptance gates, not an accuracy specification.
    static let maxTranslation=2.0, maxResidual=0.05, maxCondition=1000.0
    static let minBaseline=0.15, minAngle=5.0*Double.pi/180, maxCommonInterval=15.0
    static func usable(_ observation:GCPObservation,directionOnly:Bool=false) throws {
        _=try observation.ray()
        guard observation.tracking == .normal else {throw GCPFailure.tracking}
        if let depth=observation.depth,!directionOnly {
            let range=simd_length(try observation.depthPoint()-observation.pose.position.v)
            guard depth.cameraZ>0.1,depth.neighbourhoodSpread.isFinite,depth.neighbourhoodSpread>=0,
                  !depth.boundaryRisk,depth.neighbourhoodSpread<=max(0.015,depth.cameraZ*0.01),
                  (depth.confidence == .high && range<=8 || depth.confidence == .medium && range<=3)
            else {throw GCPFailure.depthQuality}
        }
    }
    static func register(_ observation:GCPObservation,translation:GCPVector=GCPVector()) throws -> GCPPoint {
        try usable(observation)
        guard observation.depth != nil else {throw GCPFailure.depthUnavailable}
        guard translation.finite,simd_length(translation.v)<=maxTranslation else {throw GCPFailure.translationTooLarge}
        return GCPPoint(epoch:observation.epoch,position:GCPVector(try observation.depthPoint()+translation.v),registrationObservationID:observation.id,registrationTranslation:translation)
    }
    /// Independent bearings in one short trusted AR interval. No depth is used,
    /// including when either frame also contains a usable depth measurement.
    static func triangulate(_ first:GCPObservation,_ second:GCPObservation) throws -> GCPTriangulation {
        try usable(first,directionOnly:true);try usable(second,directionOnly:true)
        guard first.epoch==second.epoch else {throw GCPFailure.generationMismatch}
        guard second.time>first.time,second.time-first.time<=maxCommonInterval else {throw GCPFailure.intervalTooLong}
        let a=try first.ray(),b=try second.ray(),baseline=simd_length(a.origin-b.origin)
        guard baseline>=minBaseline else {throw GCPFailure.insufficientBaseline}
        let c=max(-1,min(1,simd_dot(a.direction,b.direction))),den=1-c*c
        guard den>=pow(sin(minAngle),2) else {throw GCPFailure.parallelDirections}
        let condition=2/(1-abs(c))
        guard condition.isFinite,condition<=maxCondition else {throw GCPFailure.illConditioned}
        let w=a.origin-b.origin,d=simd_dot(a.direction,w),e=simd_dot(b.direction,w)
        let t=(c*e-d)/den,u=(e-c*d)/den
        guard t>0.1,u>0.1,t<=30,u<=30 else {throw GCPFailure.behindCamera}
        let left=a.origin+t*a.direction,right=b.origin+u*b.direction,gap=simd_length(left-right)
        guard gap.isFinite,gap<=maxResidual else {throw GCPFailure.residualTooLarge}
        return GCPTriangulation(position:GCPVector((left+right)/2),baseline:baseline,angleRadians:acos(c),closestDistance:gap,firstDistance:t,secondDistance:u,conditionNumber:condition)
    }
    static func register(_ first:GCPObservation,_ second:GCPObservation,translation:GCPVector=GCPVector()) throws -> GCPPoint {
        guard translation.finite,simd_length(translation.v)<=maxTranslation else {throw GCPFailure.translationTooLarge}
        let quality=try triangulate(first,second)
        return GCPPoint(epoch:first.epoch,position:GCPVector(quality.position.v+translation.v),registrationObservationID:first.id,registrationTranslation:translation,secondRegistrationObservationID:second.id,triangulation:quality)
    }
    /// A triangulated physical position supports the same local 1 m policy as
    /// depth; it is never matched to imported coordinates from another basis.
    static func candidates(position:SIMD3<Double>,epoch:GCPEpoch,points:[GCPPoint],policy:GCPMatchPolicy)->[(UUID,Double)] {
        let radius=policy == .scanOneMetre ? 1.0:0.5
        return points.filter {$0.epoch==epoch && $0.position.finite}.map {($0.id,simd_length($0.position.v-position))}
            .filter {$0.1<=radius}.sorted {$0.1==$1.1 ? $0.0.uuidString<$1.0.uuidString:$0.1<$1.1}
    }
    /// Decide before matching. A failed/ambiguous match is never converted into a new point.
    static func shouldReobserve(_ observation:GCPObservation,points:[GCPPoint],depthAccepted:Bool,translation:GCPVector) throws -> Bool {
        guard depthAccepted else {return true}
        try usable(observation)
        guard translation.finite,simd_length(translation.v)<=maxTranslation else {throw GCPFailure.translationTooLarge}
        let measured=try observation.depthPoint()+translation.v,ray=try observation.ray(),origin=ray.origin+translation.v
        for p in points where p.epoch==observation.epoch {
            guard p.position.finite else {throw GCPFailure.invalidObservation}
            let delta=p.position.v-origin,along=simd_dot(delta,ray.direction)
            let near=simd_length(p.position.v-measured)<=1.0
            let aimed=along>0.1 && along<=30 && atan2(simd_length(delta-along*ray.direction),along)<=8*Double.pi/180
            if near || aimed {return true}
        }
        return false
    }
    /// Candidate policy is local to an epoch; a bearing alone has no 1 m depth sphere.
    static func candidates(_ observation:GCPObservation,points:[GCPPoint],assumedTranslation:GCPVector=GCPVector(),directionOnly:Bool=false,policy:GCPMatchPolicy = .conservative) throws -> [(UUID,Double)] {
        try usable(observation,directionOnly:directionOnly)
        guard assumedTranslation.finite,simd_length(assumedTranslation.v)<=maxTranslation else {throw GCPFailure.translationTooLarge}
        let ray=try observation.ray(),origin=ray.origin+assumedTranslation.v
        let sphere=policy == .scanOneMetre && observation.depth != nil && !directionOnly
        var scores:[(UUID,Double)]=[]
        for point in points where point.epoch==observation.epoch {
            guard point.position.finite else {throw GCPFailure.invalidObservation}
            let delta=point.position.v-origin,along=simd_dot(delta,ray.direction)
            guard along>0.1,along<=30 else {continue}
            let transverse=simd_length(delta-along*ray.direction)
            if !sphere && atan2(transverse,along)>8*Double.pi/180 {continue}
            let score:Double
            if observation.depth != nil && !directionOnly {score=simd_length(point.position.v-(try observation.depthPoint())-assumedTranslation.v)}
            else {score=transverse}
            if score <= (sphere ? 1.0:0.60) {scores.append((point.id,score))}
        }
        return scores.sorted {$0.1==$1.1 ? $0.0.uuidString<$1.0.uuidString:$0.1<$1.1}
    }
    /// Failure never creates another GCP. Multiple points inside the new 1 m
    /// depth gate are always ambiguous, even if one is substantially nearer.
    static func match(_ observation:GCPObservation,points:[GCPPoint],assumedTranslation:GCPVector=GCPVector(),directionOnly:Bool=false,policy:GCPMatchPolicy = .conservative) throws -> UUID {
        let scores=try candidates(observation,points:points,assumedTranslation:assumedTranslation,directionOnly:directionOnly,policy:policy)
        let sphere=policy == .scanOneMetre && observation.depth != nil && !directionOnly
        guard let best=scores.first,best.1 <= (sphere ? 1.0:0.50) else {throw GCPFailure.noMatch}
        if scores.count>1 && (sphere || scores[1].1-best.1<0.10) {throw GCPFailure.ambiguous}
        return best.0
    }
    private static func projector(_ d:SIMD3<Double>) -> [Double] {
        var result=Array(repeating:0.0,count:9)
        for row in 0..<3 {for column in 0..<3 {result[row*3+column]=(row==column ? 1.0:0.0)-d[row]*d[column]}}
        return result
    }
    private static func multiply(_ a:[Double],_ v:SIMD3<Double>)->SIMD3<Double> {
        SIMD3((0..<3).reduce(0){$0+a[$1]*v[$1]},(0..<3).reduce(0){$0+a[3+$1]*v[$1]},(0..<3).reduce(0){$0+a[6+$1]*v[$1]})
    }
    /// Jacobi diagonalization of the symmetric 3x3 information matrix.
    private static func eigen(_ input:[Double])->[(Double,SIMD3<Double>)] {
        var a=input,v=[1.0,0,0,0,1,0,0,0,1]
        for _ in 0..<64 {
            let pair=[(0,1),(0,2),(1,2)].max {abs(a[$0.0*3+$0.1])<abs(a[$1.0*3+$1.1])}!
            let p=pair.0,q=pair.1,apq=a[p*3+q]
            if abs(apq)<1e-13 {break}
            let app=a[p*3+p],aqq=a[q*3+q],angle=0.5*atan2(2*apq,aqq-app),c=cos(angle),s=sin(angle)
            for k in 0..<3 where k != p && k != q {
                let kp=a[k*3+p],kq=a[k*3+q]
                a[k*3+p]=c*kp-s*kq;a[p*3+k]=a[k*3+p]
                a[k*3+q]=s*kp+c*kq;a[q*3+k]=a[k*3+q]
            }
            a[p*3+p]=c*c*app-2*s*c*apq+s*s*aqq
            a[q*3+q]=s*s*app+2*s*c*apq+c*c*aqq;a[p*3+q]=0;a[q*3+p]=0
            for k in 0..<3 {let kp=v[k*3+p],kq=v[k*3+q];v[k*3+p]=c*kp-s*kq;v[k*3+q]=s*kp+c*kq}
        }
        return (0..<3).map {(a[$0*3+$0],SIMD3(v[$0],v[3+$0],v[6+$0]))}.sorted {$0.0>$1.0}
    }
    static func fit(raw:GCPRawSession,bindings:[GCPBinding],context:GCPFitContext,includeCancelled:Bool=false) throws -> GCPTranslationFit {
        guard !bindings.isEmpty,Set(bindings.map(\.observationID)).count==bindings.count else {throw GCPFailure.invalidObservation}
        guard includeCancelled || raw.activeBindings(bindings)==bindings else {throw GCPFailure.unknownReference}
        var observations:[GCPObservation]=[],targets:[GCPPoint]=[]
        for binding in bindings {
            guard let o=raw.observations.first(where:{$0.id==binding.observationID}),let p=raw.points.first(where:{$0.id==binding.pointID}) else {throw GCPFailure.unknownReference}
            try usable(o,directionOnly:binding.directionOnly)
            guard o.epoch==context.epoch,p.epoch==context.epoch else {throw GCPFailure.generationMismatch}
            guard p.position.finite else {throw GCPFailure.invalidObservation}
            observations.append(o);targets.append(p)
        }
        let first=observations.map(\.time).min()!,last=observations.map(\.time).max()!
        if observations.count>1 {
            guard context.relativePoseTrusted else {throw GCPFailure.relativePoseUntrusted}
            guard last-first<=maxCommonInterval else {throw GCPFailure.intervalTooLong}
            for i in observations.indices {for j in observations.indices where j>i && observations[i].time==observations[j].time {
                let a=observations[i].pose,b=observations[j].pose
                guard simd_length(a.position.v-b.position.v)<1e-6,abs(simd_dot(a.rotation.vector,b.rotation.vector))>1-1e-8 else {throw GCPFailure.invalidObservation}
            }}
        }
        // Same-point ray pairs need actual parallax. Different known points can
        // constrain translation at one camera position when rotation is fixed.
        let bearingOnly=observations.indices.allSatisfy {observations[$0].depth==nil || bindings[$0].directionOnly}
        if bearingOnly,observations.count>1 {
            var maxCross=0.0
            for i in observations.indices {for j in observations.indices where j>i {
                let a=try observations[i].ray(),b=try observations[j].ray()
                maxCross=max(maxCross,simd_length(simd_cross(a.direction,b.direction)))
            }}
            guard maxCross>=sin(minAngle) else {throw GCPFailure.parallelDirections}
            for pointID in Set(targets.map(\.id)) {
                let group=observations.indices.filter {targets[$0].id==pointID}
                guard group.count>1 else {continue}
                var usablePair=false,maxBaseline=0.0
                for i in group {for j in group where j>i {
                    let a=try observations[i].ray(),b=try observations[j].ray(),baseline=simd_length(a.origin-b.origin)
                    maxBaseline=max(maxBaseline,baseline)
                    let c=simd_dot(a.direction,b.direction),den=1-c*c
                    guard baseline>=minBaseline,den>=pow(sin(minAngle),2) else {continue}
                    usablePair=true
                    let w=a.origin-b.origin,d=simd_dot(a.direction,w),e=simd_dot(b.direction,w),t=(c*e-d)/den,u=(e-c*d)/den
                    guard t>0.1,u>0.1 else {throw GCPFailure.behindCamera}
                    guard simd_length(a.origin+t*a.direction-b.origin-u*b.direction)<=maxResidual else {throw GCPFailure.residualTooLarge}
                }}
                if !usablePair {throw maxBaseline<minBaseline ? GCPFailure.insufficientBaseline:GCPFailure.parallelDirections}
            }
        }
        var a=Array(repeating:0.0,count:9),b=SIMD3<Double>.zero
        for i in observations.indices {
            let o=observations[i],ray=try o.ray()
            let bearingOnly=o.depth==nil || bindings[i].directionOnly
            let p=bearingOnly ? projector(ray.direction):[1.0,0,0,0,1,0,0,0,1]
            let delta=targets[i].position.v-(bearingOnly ? ray.origin:try o.depthPoint())
            for k in 0..<9 {a[k]+=p[k]};b += multiply(p,delta)
        }
        let values=eigen(a),threshold=max(1e-10,values[0].0*1e-8),known=values.filter {$0.0>threshold},rank=known.count
        guard rank>=2 else {throw GCPFailure.illConditioned}
        if rank<3 && observations.count>1 {throw GCPFailure.parallelDirections}
        let condition:Double?=rank==3 ? values[0].0/known.last!.0:nil
        if let condition,condition>maxCondition {throw GCPFailure.illConditioned}
        let translation=known.reduce(SIMD3<Double>.zero) {$0+$1.1*(simd_dot($1.1,b)/$1.0)}
        guard translation.x.isFinite,translation.y.isFinite,translation.z.isFinite,simd_length(translation)<=maxTranslation else {throw GCPFailure.translationTooLarge}
        for i in observations.indices {
            let o=observations[i],ray=try o.ray(),delta=targets[i].position.v-ray.origin-translation
            guard simd_dot(delta,ray.direction)>0.1 else {throw GCPFailure.behindCamera}
            let error=(o.depth==nil || bindings[i].directionOnly) ? simd_length(multiply(projector(ray.direction),delta)):simd_length(try o.depthPoint()+translation-targets[i].position.v)
            guard error<=maxResidual else {throw GCPFailure.residualTooLarge}
        }
        let lastPose=observations.max(by:{$0.time<$1.time})!.pose
        return GCPTranslationFit(context:context,bindings:bindings,translation:GCPVector(translation),rank:rank,information:a,unconstrainedDirections:values.filter {$0.0<=threshold}.map {GCPVector($0.1)},conditionNumber:condition,firstTime:first,lastTime:last,lastPose:lastPose)
    }
    static func adjustment(fit:GCPTranslationFit,samples:[GCPTrajectorySample],start:GCPVector=GCPVector()) throws -> GCPAdjustment {
        guard fit.rank==3,fit.policyVersion==1 else {throw GCPFailure.incompleteTranslation}
        guard samples.count>=2,start.finite,fit.translation.finite,fit.lastPose.valid,
              fit.information.count==9,fit.information.allSatisfy(\.isFinite),fit.unconstrainedDirections.isEmpty,
              let condition=fit.conditionNumber,condition.isFinite,condition>0,condition<=maxCondition,
              simd_length(start.v)<=maxTranslation,simd_length(fit.translation.v)<=maxTranslation else {throw GCPFailure.invalidTrajectory}
        var distances=[0.0],anchor=samples[0]
        for i in samples.indices {
            let s=samples[i]
            guard s.epoch==fit.context.epoch,s.rawPose.valid,s.time.isFinite,s.tracking == .normal else {throw GCPFailure.invalidTrajectory}
            if i>0 {
                guard s.time>samples[i-1].time else {throw GCPFailure.invalidTrajectory}
                let step=simd_length(s.rawPose.position.v-anchor.rawPose.position.v),dt=s.time-anchor.time
                guard step<=3,step/dt<=3 else {throw GCPFailure.trajectoryOutlier}
                if step>=0.02 {distances.append(distances.last!+step);anchor=s}
                else {distances.append(distances.last!)}
            }
        }
        guard distances.last!>=0.15 else {throw GCPFailure.zeroDistance}
        guard fit.firstTime>=samples[0].time,abs(fit.lastTime-samples.last!.time)<=1e-6,
              simd_length(fit.lastPose.position.v-samples.last!.rawPose.position.v)<=1e-6,
              abs(simd_dot(fit.lastPose.rotation.vector,samples.last!.rawPose.rotation.vector))>=1-1e-10 else {throw GCPFailure.invalidTrajectory}
        let offsets=distances.map {GCPVector(start.v+(fit.translation.v-start.v)*($0/distances.last!))}
        return GCPAdjustment(fit:fit,trajectoryIDs:samples.map(\.id),startTranslation:start,offsets:offsets)
    }
    static func averageClosures(_ values:[GCPClosure],from:UUID,to:UUID,epoch:GCPEpoch) throws -> GCPClosure {
        guard from != to,!values.isEmpty else {throw GCPFailure.closureMismatch}
        var aligned:[SIMD3<Double>]=[]
        for value in values {
            guard value.epoch==epoch,value.delta.finite,simd_length(value.delta.v)<=maxTranslation else {throw GCPFailure.closureMismatch}
            if value.from==from && value.to==to {aligned.append(value.delta.v)}
            else if value.from==to && value.to==from {aligned.append(-value.delta.v)}
            else {throw GCPFailure.closureMismatch}
        }
        let mean=aligned.reduce(.zero,+)/Double(aligned.count)
        guard aligned.allSatisfy({simd_length($0-mean)<=maxResidual}) else {throw GCPFailure.residualTooLarge}
        return GCPClosure(epoch:epoch,from:from,to:to,delta:GCPVector(mean))
    }
}

/// Diagnostic values only. Acceptance continues to use GCPMath.triangulate.
struct GCPRayDiagnostics {
    let baseline:Double,angleDegrees:Double
    let gap:Double?,firstDistance:Double?,secondDistance:Double?
    init(_ first:GCPObservation,_ second:GCPObservation)throws {
        let a=try first.ray(),b=try second.ray(),c=max(-1,min(1,simd_dot(a.direction,b.direction))),den=1-c*c
        baseline=simd_distance(a.origin,b.origin);angleDegrees=acos(abs(c))*180/Double.pi
        if den>1e-12 {
            let w=a.origin-b.origin,d=simd_dot(a.direction,w),e=simd_dot(b.direction,w),t=(c*e-d)/den,u=(e-c*d)/den
            gap=simd_distance(a.origin+t*a.direction,b.origin+u*b.direction);firstDistance=t;secondDistance=u
        } else {gap=nil;firstDistance=nil;secondDistance=nil}
    }
    var summary:String {
        var text=String(format:"視点移動 %.0fcm / 交会角 %.1f°（必要: 15cm以上・5°以上）",baseline*100,angleDegrees)
        if let gap {text += String(format:" / 線の離れ %.1fcm（5cm以下）",gap*100)}
        return text
    }
}
