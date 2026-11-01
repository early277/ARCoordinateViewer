import Foundation
import simd

/// An explicitly heuristic policy, not an ARKit loop-closure notification.
/// Changes are versioned so a derived correction can be reproduced or cancelled.
struct PCPosePulsePolicy:Codable,Equatable {
    var version=1
    var velocityDeviation=2.5       // m/s from stable neighbouring motion, not absolute speed
    var acceleration=40.0          // m/s²; provisional, supports a 2.5m/s pulse at 30Hz
    var angularVelocityDeviation=2.5 // rad/s; separately gated, not a linear-speed surrogate
    var angularAcceleration=40.0   // rad/s²
    var stableVelocityTolerance=0.5
    var stableAngularVelocityTolerance=0.5
    var beforeIntervals=3
    var afterIntervals=3
    var minimumInterval=1.0/240.0
    var maximumInterval=0.1
    var maximumGapRatio=2.0
    var maximumStepAtCamera=1.0
    var maximumStepAngle=0.75
    // Existing continuity safety bounds while no stable motion model exists.
    // They are not evidence that an ARKit refinement occurred.
    var warmupMaximumSpeed=3.0
    var warmupMaximumAngularSpeed=4.0
    /// Missing in build73 journals: preserve their exact detector/replay policy.
    /// True allows rapid real movement to establish a baseline; it does not
    /// weaken the independent conditions required to accept a correction pulse.
    var motionFallback:Bool? = nil
    static var motionTolerant:Self {
        var value=Self();value.motionFallback=true;return value
    }
    var valid:Bool {
        let values=[velocityDeviation,acceleration,angularVelocityDeviation,angularAcceleration,
                    stableVelocityTolerance,stableAngularVelocityTolerance,minimumInterval,
                    maximumInterval,maximumGapRatio,maximumStepAtCamera,maximumStepAngle,
                    warmupMaximumSpeed,warmupMaximumAngularSpeed]
        return version==1 && values.allSatisfy {$0.isFinite && $0>0}
            && (2...4).contains(beforeIntervals) && (2...4).contains(afterIntervals)
            && maximumInterval>=minimumInterval && maximumGapRatio>=1
            && maximumStepAngle<Double.pi
    }
}

struct PCPosePulseSample:Codable,Equatable {
    var time:Double
    var pose:GCPPose
    var epoch:GCPEpoch
}

/// Left-world rigid transform: new = rotation.act(old) + translation.
/// `translation` includes the rotation pivot. Do not use camera displacement as
/// world translation when `rotation` is nonidentity; directions rotate only.
struct PCPosePulseTransform:Codable,Equatable {
    var translation:GCPVector
    var qx:Double;var qy:Double;var qz:Double;var qw:Double
    static let identity=PCPosePulseTransform(translation:GCPVector(),qx:0,qy:0,qz:0,qw:1)
    var rotation:simd_quatd {simd_normalize(simd_quatd(ix:qx,iy:qy,iz:qz,r:qw))}
    var valid:Bool {
        translation.finite && [qx,qy,qz,qw].allSatisfy(\.isFinite)
            && abs(qx*qx+qy*qy+qz*qz+qw*qw-1)<1e-6
    }
    func point(_ p:SIMD3<Double>)->SIMD3<Double> {rotation.act(p)+translation.v}
    func direction(_ d:SIMD3<Double>)->SIMD3<Double> {rotation.act(d)}
    func pose(_ p:GCPPose)->GCPPose {
        let q=simd_normalize(rotation*p.rotation)
        return GCPPose(position:GCPVector(point(p.position.v)),qx:q.imag.x,qy:q.imag.y,qz:q.imag.z,qw:q.real)
    }
    var inverse:PCPosePulseTransform {
        let q=rotation.inverse
        return PCPosePulseTransform(translation:GCPVector(-q.act(translation.v)),qx:q.imag.x,qy:q.imag.y,qz:q.imag.z,qw:q.real)
    }
    /// Full SE(3) composition; rhs is applied first.
    func composed(with rhs:PCPosePulseTransform)->PCPosePulseTransform {
        let q=simd_normalize(rotation*rhs.rotation)
        return PCPosePulseTransform(translation:GCPVector(point(rhs.translation.v)),qx:q.imag.x,qy:q.imag.y,qz:q.imag.z,qw:q.real)
    }
    /// Declared model: linear world translation and shortest quaternion arc.
    /// This is not evidence of the physical drift curve between constraints.
    func interpolated(_ fraction:Double)throws->PCPosePulseTransform {
        guard valid,fraction.isFinite,(0...1).contains(fraction) else {throw GCPFailure.invalidTrajectory}
        let q=simd_slerp(Self.identity.rotation,rotation,fraction)
        return PCPosePulseTransform(translation:GCPVector(translation.v*fraction),qx:q.imag.x,qy:q.imag.y,qz:q.imag.z,qw:q.real)
    }
}

struct PCPosePulseEvent:Codable,Equatable,Identifiable {
    enum Components:String,Codable {case translation,rotation,translationAndRotation}
    var id=UUID()
    var policy:PCPosePulsePolicy
    var before:PCPosePulseSample
    var after:PCPosePulseSample
    var confirmedAt:Double
    var predictedAfter:GCPPose
    var worldDelta:PCPosePulseTransform
    var baselineVelocity:GCPVector
    var baselineAngularVelocity:GCPVector
    var velocityDeviation:Double
    var angularVelocityDeviation:Double
    var incomingAcceleration:Double
    var outgoingAcceleration:Double
    var incomingAngularAcceleration:Double
    var outgoingAngularAcceleration:Double
    var components:Components
    /// Bounded original pose samples around this event. Allows independent replay
    /// after reopening; 0.5s trajectory samples alone would lose a 60Hz pulse.
    var supportSamples:[PCPosePulseSample]=[]
    /// Records the epistemic limit in the same object as the estimate.
    var evidence="heuristic one-step pulse; physical motion may produce identical samples; no ARKit cause assertion"
    var imuEvidence:PCIMUPulseEvidence? = nil
    var isReproducible:Bool {
        if let imuEvidence {return imuEvidence.reproduces(self)}
        guard policy.valid,supportSamples.count==policy.beforeIntervals+policy.afterIntervals+2 else {return false}
        var detector=PCPosePulseDetector(policy:policy),replayed:[PCPosePulseEvent]=[]
        for sample in supportSamples {
            switch detector.ingest(time:sample.time,pose:sample.pose,epoch:sample.epoch) {
            case .confirmed(let event):replayed.append(event)
            case .unsafe:return false
            default:break
            }
        }
        guard replayed.count==1,var event=replayed.first else {return false}
        event.id=id
        return event==self
    }
}

enum PCPosePulseUnsafe:String,Equatable {
    case invalidPolicy,invalidPose,nonMonotonicTime,intervalGap,epochChanged
    case unstableBefore,notImpulse,stepTooLarge,unstableAfter,incompletePulse
}
/// Explicit binary classification chosen by the recording policy. The saved
/// pose is original evidence, not a correction transform or a proven cause.
struct PCPoseMotionDecision:Codable,Equatable,Identifiable {
    static let classificationAssumption="classified as physical motion by rule because correction-pulse conditions were not met; ARKit pose refinement may be missed; cause is not proven"
    var id=UUID()
    var epoch:GCPEpoch
    var time:Double
    var pose:GCPPose
    var previousTime:Double? = nil
    var previousPose:GCPPose? = nil
    var reason:String
    var treatment="physicalMotionByRule"
    var policy:PCPosePulsePolicy
    var assumption=Self.classificationAssumption
    var imuEvidence:PCIMUPulseEvidence? = nil
    var valid:Bool {
        guard epoch.generation>=0,epoch.alignmentRevision>=0,
              time.isFinite,time>=0,pose.valid,policy.valid,policy.motionFallback==true,
              treatment=="physicalMotionByRule",assumption==Self.classificationAssumption,
              [PCPosePulseUnsafe.unstableBefore,.unstableAfter,.notImpulse,.stepTooLarge,.intervalGap,.incompletePulse].contains(where:{$0.rawValue==reason}) else {return false}
        if let evidence=imuEvidence {
            guard evidence.outcome=="resolvedAsPhysicalMotion",evidence.isReproducible,abs(evidence.confirmedAt-time)<1e-8,
                  evidence.poseSamples.allSatisfy({$0.epoch==epoch}) else {return false}
        }
        switch (previousTime,previousPose) {
        case (nil,nil):return true
        case (.some(let time),.some(let pose)):return time.isFinite && time>=0 && time<self.time && pose.valid
        default:return false
        }
    }
}

enum PCPosePulseResult:Equatable {
    case warmingUp
    case stable
    case pending(PCPosePulseSample)
    case confirmed(PCPosePulseEvent)
    case unsafe(PCPosePulseUnsafe)
}

/// Pure bounded detector. No AR session, raw-observation mutation or I/O.
/// Caller withholds capture while pending and then resolves it by confirmation
/// or its explicit physical-motion rule. Unsafe means the pulse model failed;
/// tracking/epoch/numeric validity remain separate caller safety checks.
struct PCPosePulseDetector {
    let policy:PCPosePulsePolicy
    private var samples:[PCPosePulseSample]=[]
    private struct Motion {
        var dt:Double;var velocity:SIMD3<Double>;var angularVelocity:SIMD3<Double>
    }
    private struct Candidate {
        var before:PCPosePulseSample;var after:PCPosePulseSample;var predicted:GCPPose
        var delta:PCPosePulseTransform;var baseline:Motion;var shock:Motion
        var linear:Bool;var angular:Bool;var aIn:SIMD3<Double>;var wIn:SIMD3<Double>
        var aOut=SIMD3<Double>.zero;var wOut=SIMD3<Double>.zero;var count=0
    }
    private var candidate:Candidate?
    init(policy:PCPosePulsePolicy=PCPosePulsePolicy()) {self.policy=policy}
    var pendingSample:PCPosePulseSample? {candidate?.after}
    var retainedSampleCount:Int {samples.count}
    /// Explicit session/stop boundary. An unconfirmed event is never promoted.
    mutating func reset() {samples.removeAll(keepingCapacity:true);candidate=nil}
    mutating func finish()->PCPosePulseResult {
        let result:PCPosePulseResult=candidate==nil ? .stable:.unsafe(.incompletePulse)
        reset();return result
    }
    private static func vector(_ rotation:simd_quatd)->SIMD3<Double> {
        var q=simd_normalize(rotation)
        if q.real<0 {q=simd_quatd(vector:-q.vector)}
        let n=simd_length(q.imag)
        return n<1e-12 ? .zero:q.imag*(2*atan2(n,q.real)/n)
    }
    private static func rotation(_ vector:SIMD3<Double>)->simd_quatd {
        let n=simd_length(vector)
        return n<1e-12 ? simd_quatd(ix:0,iy:0,iz:0,r:1):simd_quatd(angle:n,axis:vector/n)
    }
    private static func motion(_ a:PCPosePulseSample,_ b:PCPosePulseSample)->Motion {
        let dt=b.time-a.time
        return Motion(dt:dt,velocity:(b.pose.position.v-a.pose.position.v)/dt,
                      angularVelocity:vector(b.pose.rotation*a.pose.rotation.inverse)/dt)
    }
    private static func mean(_ motions:[Motion])->Motion {
        let n=Double(motions.count)
        return Motion(dt:motions.reduce(0){$0+$1.dt}/n,
                      velocity:motions.reduce(.zero){$0+$1.velocity}/n,
                      angularVelocity:motions.reduce(.zero){$0+$1.angularVelocity}/n)
    }
    private mutating func unsafe(_ reason:PCPosePulseUnsafe,_ latest:PCPosePulseSample?=nil)->PCPosePulseResult {
        reset();if let latest {samples=[latest]};return .unsafe(reason)
    }
    private func stable(_ motions:[Motion],against base:Motion)->Bool {
        motions.allSatisfy {
            simd_length($0.velocity-base.velocity)<=policy.stableVelocityTolerance
                && simd_length($0.angularVelocity-base.angularVelocity)<=policy.stableAngularVelocityTolerance
        }
    }
    mutating func ingest(time:Double,pose:GCPPose,epoch:GCPEpoch)->PCPosePulseResult {
        guard policy.valid else {return unsafe(.invalidPolicy)}
        guard time.isFinite,time>=0,pose.valid,epoch.generation>=0,epoch.alignmentRevision>=0 else {return unsafe(.invalidPose)}
        let sample=PCPosePulseSample(time:time,pose:pose,epoch:epoch)
        guard let previous=samples.last else {samples=[sample];return .warmingUp}
        guard previous.epoch==epoch else {return unsafe(.epochChanged,sample)}
        let dt=time-previous.time
        guard dt>0 else {return unsafe(.nonMonotonicTime,sample)}
        guard dt>=policy.minimumInterval,dt<=policy.maximumInterval else {return unsafe(.intervalGap,sample)}
        let past=zip(samples,samples.dropFirst()).map(Self.motion)
        if !past.isEmpty {
            let intervals=past.suffix(policy.beforeIntervals).map(\.dt).sorted()
            let median=intervals[intervals.count/2]
            guard dt<=median*policy.maximumGapRatio else {return unsafe(.intervalGap,sample)}
        }
        let current=Self.motion(previous,sample)
        samples.append(sample)
        if var pending=candidate {
            let baseline=Motion(dt:pending.baseline.dt,
                                velocity:pending.delta.rotation.act(pending.baseline.velocity),
                                angularVelocity:pending.delta.rotation.act(pending.baseline.angularVelocity))
            guard stable([current],against:baseline) else {return unsafe(.unstableAfter,sample)}
            if pending.count==0 {
                let span=(current.dt+pending.shock.dt)/2
                pending.aOut=(current.velocity-pending.shock.velocity)/span
                pending.wOut=(current.angularVelocity-pending.shock.angularVelocity)/span
                func paired(_ a:SIMD3<Double>,_ b:SIMD3<Double>,_ threshold:Double)->Bool {
                    let na=simd_length(a),nb=simd_length(b)
                    return na>=threshold && nb>=threshold && simd_dot(a,b)<(-0.5*na*nb)
                }
                guard (!pending.linear || paired(pending.aIn,pending.aOut,policy.acceleration)),
                      (!pending.angular || paired(pending.wIn,pending.wOut,policy.angularAcceleration)) else {return unsafe(.notImpulse,sample)}
            }
            pending.count+=1
            if pending.count<policy.afterIntervals {candidate=pending;return .pending(pending.after)}
            let result=PCPosePulseEvent(policy:policy,before:pending.before,after:pending.after,confirmedAt:time,
                predictedAfter:pending.predicted,worldDelta:pending.delta,
                baselineVelocity:GCPVector(pending.baseline.velocity),baselineAngularVelocity:GCPVector(pending.baseline.angularVelocity),
                velocityDeviation:simd_length(pending.shock.velocity-pending.baseline.velocity),
                angularVelocityDeviation:simd_length(pending.shock.angularVelocity-pending.baseline.angularVelocity),
                incomingAcceleration:simd_length(pending.aIn),outgoingAcceleration:simd_length(pending.aOut),
                incomingAngularAcceleration:simd_length(pending.wIn),outgoingAngularAcceleration:simd_length(pending.wOut),
                components:pending.linear ? (pending.angular ? .translationAndRotation:.translation):.rotation,
                supportSamples:samples)
            candidate=nil;samples=Array(samples.suffix(policy.beforeIntervals+1));return .confirmed(result)
        }
        guard past.count>=policy.beforeIntervals else {
            // An unmodelled large jump during warm-up must not silently pass.
            if policy.motionFallback != true {
                guard simd_length(current.velocity)<=policy.warmupMaximumSpeed+1e-9,
                      simd_length(current.angularVelocity)<=policy.warmupMaximumAngularSpeed+1e-9 else {return unsafe(.unstableBefore,sample)}
            }
            return .warmingUp
        }
        let neighbours=Array(past.suffix(policy.beforeIntervals)),base=Self.mean(neighbours)
        let dv=current.velocity-base.velocity,dw=current.angularVelocity-base.angularVelocity
        let linear=simd_length(dv)>=policy.velocityDeviation-1e-9
        let angular=simd_length(dw)>=policy.angularVelocityDeviation-1e-9
        guard linear || angular else {samples=Array(samples.suffix(policy.beforeIntervals+1));return .stable}
        guard stable(neighbours,against:base) else {return unsafe(.unstableBefore,sample)}
        let span=(current.dt+base.dt)/2,aIn=dv/span,wIn=dw/span
        guard (!linear || simd_length(aIn)>=policy.acceleration),(!angular || simd_length(wIn)>=policy.angularAcceleration) else {return unsafe(.notImpulse,sample)}
        let predictedPosition=previous.pose.position.v+base.velocity*dt
        let predictedRotation=Self.rotation(base.angularVelocity*dt)*previous.pose.rotation
        let predicted=GCPPose(position:GCPVector(predictedPosition),qx:predictedRotation.imag.x,qy:predictedRotation.imag.y,qz:predictedRotation.imag.z,qw:predictedRotation.real)
        let deltaQ=simd_normalize(pose.rotation*predictedRotation.inverse)
        let displacement=pose.position.v-predictedPosition
        guard simd_length(displacement)<=policy.maximumStepAtCamera,simd_length(Self.vector(deltaQ))<=policy.maximumStepAngle else {return unsafe(.stepTooLarge,sample)}
        let delta=PCPosePulseTransform(translation:GCPVector(pose.position.v-deltaQ.act(predictedPosition)),
                                      qx:deltaQ.imag.x,qy:deltaQ.imag.y,qz:deltaQ.imag.z,qw:deltaQ.real)
        candidate=Candidate(before:previous,after:sample,predicted:predicted,delta:delta,baseline:base,shock:current,
                            linear:linear,angular:angular,aIn:aIn,wIn:wIn)
        return .pending(sample)
    }
}
