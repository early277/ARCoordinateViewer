import Foundation
import simd

/// Gravity-removed acceleration (m/s²) and raw gyro (rad/s), both in device axes.
/// No magnetic heading or long-term device-motion attitude enters this model.
struct PCIMUSample:Codable,Equatable {
    var time:Double
    var acceleration:GCPVector
    var rotationRate:GCPVector
    var valid:Bool {
        time.isFinite && time>=0 && acceleration.finite && rotationRate.finite
            && simd_length(acceleration.v)<=100 && simd_length(rotationRate.v)<=35
    }
}

/// Provisional sensor-error bounds, deliberately separate from the legacy
/// version-1 AR-only pulse policy. These are replayed with the original data.
struct PCIMUPolicy:Codable,Equatable {
    var version=1
    var minimumTranslationResidual=0.025
    var minimumRotationResidual=Double.pi/180
    var seedTranslationResidual=0.004
    var seedRotationResidual=Double.pi/1800
    var baselineIntervals=3
    var afterIntervals=3
    var maximumBurstIntervals=6
    var minimumARInterval=1.0/240
    var maximumARInterval=0.05
    var maximumARGapRatio=2.1
    // Six 30Hz burst intervals plus three settling intervals fit this bound.
    var maximumWindowDuration=0.31
    var maximumHistoryDuration=1.0
    var maximumPoseSamples=120
    var maximumIMUSamples=400
    var maximumIMUGap=0.025
    /// Causal zero-order endpoint hold, never a future IMU observation.
    var maximumEndpointLag=0.015
    var baselinePositionTolerance=0.004
    var baselineRotationTolerance=Double.pi/360
    var settlePositionTolerance=0.006
    var settleRotationTolerance=Double.pi/600
    var maximumResidualSpeed=0.12
    var maximumResidualAngularSpeed=0.08
    var accelerationUncertainty=0.25
    var gyroUncertainty=0.005
    var velocityUncertainty=0.015
    /// Camera/IMU origin offset is not calibrated by the acquisition adapter.
    var maximumLeverArm=0.12
    var maximumLeverArmUncertainty=0.02
    var maximumTranslationResidual=0.5
    var maximumRotationResidual=0.35
    var valid:Bool {
        let positive=[minimumTranslationResidual,minimumRotationResidual,seedTranslationResidual,
            seedRotationResidual,minimumARInterval,maximumARInterval,maximumARGapRatio,
            maximumWindowDuration,maximumHistoryDuration,maximumIMUGap,maximumEndpointLag,
            baselinePositionTolerance,baselineRotationTolerance,settlePositionTolerance,
            settleRotationTolerance,maximumResidualSpeed,maximumResidualAngularSpeed,
            accelerationUncertainty,gyroUncertainty,velocityUncertainty,maximumLeverArm,
            maximumLeverArmUncertainty,maximumTranslationResidual,maximumRotationResidual]
        return version==1 && positive.allSatisfy {$0.isFinite && $0>0}
            && (3...6).contains(baselineIntervals) && (2...4).contains(afterIntervals)
            && (1...6).contains(maximumBurstIntervals)
            && minimumARInterval>=1.0/500 && maximumARInterval<=0.1
            && maximumARInterval>=minimumARInterval && maximumARGapRatio>=1
            && maximumWindowDuration<=0.5 && maximumHistoryDuration<=1
            && maximumWindowDuration<maximumHistoryDuration
            && (16...120).contains(maximumPoseSamples) && (40...400).contains(maximumIMUSamples)
            && maximumPoseSamples>=baselineIntervals+maximumBurstIntervals+afterIntervals+2
            && maximumEndpointLag<=0.02 && maximumIMUGap<=0.04
            && seedTranslationResidual<minimumTranslationResidual
            && seedRotationResidual<minimumRotationResidual
            && maximumTranslationResidual<=1 && maximumRotationResidual<0.75
            && minimumTranslationResidual<maximumTranslationResidual
            && minimumRotationResidual<maximumRotationResidual
            && maximumLeverArm<=0.25 && maximumLeverArmUncertainty<=0.04
    }
}

/// JSON has no NaN/Infinity numbers. A maximum of two offending samples is
/// encoded textually so an invalid sensor delivery remains diagnosable and can
/// reproduce the rejection without placing nonfinite numbers in the journal.
struct PCIMURejectedSample:Codable,Equatable {
    var components:[String]
    init(_ sample:PCIMUSample) {
        components=[sample.time,sample.acceleration.x,sample.acceleration.y,sample.acceleration.z,
                    sample.rotationRate.x,sample.rotationRate.y,sample.rotationRate.z].map {String($0)}
    }
    var sample:PCIMUSample? {
        guard components.count==7,components.allSatisfy({$0.count<=64}) else {return nil}
        let values=components.compactMap(Double.init)
        guard values.count==7 else {return nil}
        return PCIMUSample(time:values[0],acceleration:GCPVector(values[1],values[2],values[3]),
                           rotationRate:GCPVector(values[4],values[5],values[6]))
    }
}
struct PCIMURejectedInput:Codable,Equatable {
    var imu:[PCIMURejectedSample]=[]
    var cameraFromDevice:PCPosePulseTransform? = nil
    var valid:Bool {
        guard imu.count<=2,imu.allSatisfy({$0.sample != nil}) else {return false}
        if let cameraFromDevice {
            return imu.isEmpty && cameraFromDevice.valid && cameraFromDevice.translation==GCPVector()
        }
        return !imu.isEmpty
    }
}

/// Independent, bounded, original sensor evidence for a short residual window.
/// `cameraFromDevice` contains only the device-to-AR-camera axis rotation.
struct PCIMUPulseEvidence:Codable,Equatable {
    static let assumption="short-window IMU-supported AR pose residual estimate; sensor bias, timing, camera/IMU offset and unmodelled motion can remain; ARKit cause is not proven"
    var policy:PCIMUPolicy
    var cameraFromDevice:PCPosePulseTransform
    var poseSamples:[PCPosePulseSample]
    var imuSamples:[PCIMUSample]
    /// Timestamp availability at each original AR callback, preserving latency.
    var imuAvailableThrough:[Double]
    var outcome:String
    var reason:String
    var beforeTime:Double
    var afterTime:Double
    var confirmedAt:Double
    var predictedAfter:GCPPose?
    var estimatedDelta:PCPosePulseTransform?
    var baselineVelocity:GCPVector?
    var baselineAngularVelocity:GCPVector?
    var rejectedInput:PCIMURejectedInput? = nil
    var assumption=Self.assumption

    private func replay()->(PCIMUPulseEvidence,PCPosePulseEvent?)? {
        guard policy.valid,cameraFromDevice.valid,cameraFromDevice.translation==GCPVector(),
              assumption==Self.assumption,
              poseSamples.count>=policy.baselineIntervals+2,
              poseSamples.count<=policy.maximumPoseSamples,
              imuAvailableThrough.count==poseSamples.count,
              imuAvailableThrough.allSatisfy({$0.isFinite && $0>=0}),
              zip(imuAvailableThrough,imuAvailableThrough.dropFirst()).allSatisfy({$0<=$1}),
              !imuSamples.isEmpty,imuSamples.count<=policy.maximumIMUSamples,
              imuSamples.count+(rejectedInput?.imu.count ?? 0)<=policy.maximumIMUSamples,
              let first=poseSamples.first,let last=poseSamples.last,
              last.time-first.time<=policy.maximumHistoryDuration+1e-9,
              imuSamples.allSatisfy(\.valid),
              zip(imuSamples,imuSamples.dropFirst()).allSatisfy({$0.time<$1.time}),
              imuSamples.last!.time<=last.time,
              [beforeTime,afterTime,confirmedAt].allSatisfy({$0.isFinite && $0>=0}),
              beforeTime<afterTime,afterTime<=confirmedAt,
              confirmedAt==last.time,
              afterTime-beforeTime<=policy.maximumWindowDuration+1e-9,
              predictedAfter?.valid==true,estimatedDelta?.valid==true,
              baselineVelocity?.finite==true,baselineAngularVelocity?.finite==true,
              outcome=="confirmed" || outcome=="resolvedAsPhysicalMotion" else {return nil}
        if let rejectedInput {
            guard outcome=="resolvedAsPhysicalMotion",rejectedInput.valid,
                  reason=="invalidIMUSamples" || reason=="cameraDeviceAxesChanged" else {return nil}
        }
        var detector=PCIMUPoseDetector(policy:policy),event:PCPosePulseEvent?
        for (index,pair) in zip(poseSamples,imuAvailableThrough).enumerated() {
            let (sample,available)=pair
            guard available<=sample.time else {return nil}
            var causal=imuSamples.filter {$0.time<=available}
            // Preserve original component bits: normalizing a saved unit
            // quaternion again can perturb the prediction by a final ULP.
            var camera=simd_quatd(ix:cameraFromDevice.qx,iy:cameraFromDevice.qy,
                                  iz:cameraFromDevice.qz,r:cameraFromDevice.qw)
            if index==poseSamples.count-1,let rejectedInput {
                causal=rejectedInput.imu.compactMap(\.sample)
                if let changed=rejectedInput.cameraFromDevice {
                    camera=simd_quatd(ix:changed.qx,iy:changed.qy,iz:changed.qz,r:changed.qw)
                }
            }
            let result=detector.ingest(time:sample.time,pose:sample.pose,epoch:sample.epoch,
                                       imu:causal,cameraFromDevice:camera)
            if case .confirmed(let value)=result {
                guard event==nil else {return nil};event=value
            }
        }
        if detector.lastEvidence==nil && reason=="incompleteWindow" {_=detector.finish()}
        guard let result=detector.lastEvidence,result==self else {return nil}
        return(result,event)
    }
    var isReproducible:Bool {replay() != nil}
    func reproduces(_ original:PCPosePulseEvent)->Bool {
        guard outcome=="confirmed",let (_,value)=replay(),var event=value else {return false}
        event.id=original.id
        return event==original
    }
}

/// Bounded physical prediction and residual settling. A tentative window starts
/// before the final threshold, so a gradual 1...6-frame update cannot become
/// the next velocity baseline. Capture must be withheld while it is pending.
struct PCIMUPoseDetector {
    let policy:PCIMUPolicy
    private(set) var lastEvidence:PCIMUPulseEvidence?
    private var samples:[PCPosePulseSample]=[]
    private var imuSamples:[PCIMUSample]=[]
    private var availability:[Double:Double]=[:]
    private var inputFailure:PCIMURejectedInput?
    private var mounting:simd_quatd?
    private struct Integral {
        var displacement=SIMD3<Double>.zero
        var velocity=SIMD3<Double>.zero
        var rotation:simd_quatd
        var rotationTravel=0.0
        var lag=0.0
    }
    private struct Baseline {
        var velocity:SIMD3<Double>
        var angularVelocity:SIMD3<Double>
        var positionError:Double
    }
    private struct Candidate {
        var before:PCPosePulseSample
        var after:PCPosePulseSample
        var predicted:GCPPose
        var delta:PCPosePulseTransform
        var baseline:Baseline
        var support:[PCPosePulseSample]
        var availableThrough:[Double]
        var intervals=1
        var burstIntervals=1
        var settled=0
        var peakTranslation=0.0
        var peakRotation=0.0
        var translationUncertainty=0.0
        var rotationUncertainty=0.0
    }
    private var candidate:Candidate?
    init(policy:PCIMUPolicy=PCIMUPolicy()) {self.policy=policy}
    var pendingSample:PCPosePulseSample? {candidate?.after}
    var retainedSampleCount:Int {samples.count}
    var retainedIMUSampleCount:Int {imuSamples.count}

    private mutating func clear() {
        samples.removeAll(keepingCapacity:true);imuSamples.removeAll(keepingCapacity:true)
        availability.removeAll(keepingCapacity:true)
        candidate=nil;mounting=nil;inputFailure=nil
    }
    mutating func reset() {clear();lastEvidence=nil}
    mutating func finish()->PCPosePulseResult {
        lastEvidence=nil
        if let pending=candidate,let latest=pending.support.last {
            let support=evidence(pending,latest:latest,outcome:"resolvedAsPhysicalMotion",reason:"incompleteWindow")
            if (support.imuSamples.first?.time ?? .infinity)<=(pending.availableThrough.first ?? 0) {
                lastEvidence=support
            }
            clear();return .unsafe(.incompletePulse)
        }
        clear();return .stable
    }
    private static func vector(_ rotation:simd_quatd)->SIMD3<Double> {
        var q=simd_normalize(rotation)
        if q.real<0 {q=simd_quatd(vector:-q.vector)}
        let n=simd_length(q.imag)
        return n<1e-12 ? .zero:q.imag*(2*atan2(n,q.real)/n)
    }
    private static func rotation(_ value:SIMD3<Double>)->simd_quatd {
        let angle=simd_length(value)
        return angle<1e-12 ? simd_quatd(ix:0,iy:0,iz:0,r:1):simd_quatd(angle:angle,axis:value/angle)
    }
    private static func pose(_ position:SIMD3<Double>,_ q:simd_quatd)->GCPPose {
        let q=simd_normalize(q)
        return GCPPose(position:GCPVector(position),qx:q.imag.x,qy:q.imag.y,qz:q.imag.z,qw:q.real)
    }
    private static func transform(_ observed:GCPPose,_ predicted:GCPPose)->PCPosePulseTransform {
        let q=simd_normalize(observed.rotation*predicted.rotation.inverse)
        return PCPosePulseTransform(translation:GCPVector(observed.position.v-q.act(predicted.position.v)),
                                    qx:q.imag.x,qy:q.imag.y,qz:q.imag.z,qw:q.real)
    }
    private mutating func retain(at time:Double) {
        let cutoff=time-policy.maximumHistoryDuration
        samples.removeAll {$0.time<cutoff}
        if samples.count>policy.maximumPoseSamples {samples.removeFirst(samples.count-policy.maximumPoseSamples)}
        imuSamples.removeAll {$0.time<cutoff}
        if imuSamples.count>policy.maximumIMUSamples {imuSamples.removeFirst(imuSamples.count-policy.maximumIMUSamples)}
        let times=Set(samples.map(\.time));availability=availability.filter {times.contains($0.key)}
    }
    private mutating func receive(_ incoming:[PCIMUSample],at time:Double)->Bool {
        guard incoming.count<=400 else {return false}
        var merged=imuSamples
        let existing=Dictionary(uniqueKeysWithValues:merged.map {($0.time,$0)})
        let previousLast=merged.last?.time
        var incomingLast:PCIMUSample?
        // Future callbacks never become physical support for an earlier AR pose.
        for sample in incoming {
            guard sample.time.isFinite else {
                inputFailure=PCIMURejectedInput(imu:[PCIMURejectedSample(sample)]);return false
            }
            if sample.time>time || sample.time<time-policy.maximumHistoryDuration {continue}
            guard sample.valid else {
                inputFailure=PCIMURejectedInput(imu:[PCIMURejectedSample(sample)]);return false
            }
            if let incomingLast,sample.time<incomingLast.time {
                inputFailure=PCIMURejectedInput(imu:[PCIMURejectedSample(incomingLast),PCIMURejectedSample(sample)])
                return false
            }
            incomingLast=sample
            if let prior=existing[sample.time] {
                guard prior==sample else {
                    inputFailure=PCIMURejectedInput(imu:[PCIMURejectedSample(sample)]);return false
                }
            } else {
                if let previousLast,sample.time<=previousLast {
                    inputFailure=PCIMURejectedInput(imu:[PCIMURejectedSample(sample)]);return false
                }
                if let last=merged.last,last.time==sample.time {
                    guard last==sample else {
                        inputFailure=PCIMURejectedInput(imu:[PCIMURejectedSample(last),PCIMURejectedSample(sample)])
                        return false
                    }
                } else {merged.append(sample)}
            }
        }
        merged.sort {$0.time<$1.time}
        imuSamples=merged
        retain(at:time)
        return true
    }
    private func value(at time:Double)->(PCIMUSample,Double)? {
        guard let i=imuSamples.lastIndex(where:{$0.time<=time}) else {return nil}
        let a=imuSamples[i]
        if a.time==time {return(a,0)}
        guard i+1<imuSamples.count else {
            let lag=time-a.time
            guard lag<=policy.maximumEndpointLag+1e-9 else {return nil}
            var held=a;held.time=time;return(held,lag)
        }
        let b=imuSamples[i+1],span=b.time-a.time
        guard span<=policy.maximumIMUGap+1e-9 else {return nil}
        let f=(time-a.time)/span
        return(PCIMUSample(time:time,acceleration:GCPVector(a.acceleration.v+(b.acceleration.v-a.acceleration.v)*f),
                          rotationRate:GCPVector(a.rotationRate.v+(b.rotationRate.v-a.rotationRate.v)*f)),0)
    }
    private func integrate(from start:PCPosePulseSample,to end:Double,cameraFromDevice:simd_quatd)->Integral? {
        guard end>=start.time,let (initial,initialLag)=value(at:start.time),
              let (final,finalLag)=value(at:end) else {return nil}
        let middle=imuSamples.filter {$0.time>start.time && $0.time<end}
        let knots=[initial]+middle+[final]
        var q=start.pose.rotation*cameraFromDevice
        var result=Integral(rotation:start.pose.rotation,lag:max(initialLag,finalLag))
        for (a,b) in zip(knots,knots.dropFirst()) {
            let dt=b.time-a.time
            if dt==0 {continue}
            guard dt>0,dt<=policy.maximumIMUGap+1e-9 else {return nil}
            let gyro=(a.rotationRate.v+b.rotationRate.v)*0.5
            // Body-axis angular rate right-multiplies world-from-device.
            let next=simd_normalize(q*Self.rotation(gyro*dt))
            let aa=q.act(a.acceleration.v),ab=next.act(b.acceleration.v)
            let accelerationDisplacement=(aa*2+ab)*(dt*dt/6)
            result.displacement+=result.velocity*dt+accelerationDisplacement
            result.velocity+=(aa+ab)*(dt/2)
            result.rotationTravel+=simd_length(gyro)*dt
            q=next
        }
        result.rotation=simd_normalize(q*cameraFromDevice.inverse)
        return result
    }
    private func baseline(_ support:[PCPosePulseSample],cameraFromDevice:simd_quatd)->Baseline? {
        guard let first=support.first,let last=support.last,
              let total=integrate(from:first,to:last.time,cameraFromDevice:cameraFromDevice),
              let (lastIMU,_)=value(at:last.time) else {return nil}
        let span=last.time-first.time
        guard span>0 else {return nil}
        let initial=(last.pose.position.v-first.pose.position.v-total.displacement)/span
        var maximumError=0.0
        for sample in support.dropFirst() {
            guard let motion=integrate(from:first,to:sample.time,cameraFromDevice:cameraFromDevice) else {return nil}
            let dt=sample.time-first.time
            let error=simd_length(sample.pose.position.v-first.pose.position.v-initial*dt-motion.displacement)
            let angle=simd_length(Self.vector(sample.pose.rotation*motion.rotation.inverse))
            guard error<=policy.baselinePositionTolerance+0.5*policy.accelerationUncertainty*dt*dt,
                  angle<=policy.baselineRotationTolerance+policy.gyroUncertainty*dt else {return nil}
            maximumError=max(maximumError,error)
        }
        let worldDevice=last.pose.rotation*cameraFromDevice
        return Baseline(velocity:initial+total.velocity,angularVelocity:worldDevice.act(lastIMU.rotationRate.v),
                        positionError:maximumError)
    }
    private func prediction(_ start:PCPosePulseSample,baseline:Baseline,at time:Double,
                            cameraFromDevice:simd_quatd)->(GCPPose,Double,Double,Double)? {
        guard let motion=integrate(from:start,to:time,cameraFromDevice:cameraFromDevice) else {return nil}
        let dt=time-start.time
        let lever=2*policy.maximumLeverArm*sin(min(Double.pi,motion.rotationTravel)/2)
        let lagError=motion.lag*(simd_length(motion.velocity)+policy.accelerationUncertainty*dt)
        let positionUncertainty=2*baseline.positionError+policy.velocityUncertainty*dt+0.5*policy.accelerationUncertainty*dt*dt+lagError+lever
        let angularUncertainty=policy.gyroUncertainty*(dt+motion.lag)
        return(Self.pose(start.pose.position.v+baseline.velocity*dt+motion.displacement,motion.rotation),
               positionUncertainty,angularUncertainty,lever)
    }
    private func evidence(_ pending:Candidate,latest:PCPosePulseSample,outcome:String,reason:String,
                          rejectedInput:PCIMURejectedInput?=nil)->PCIMUPulseEvidence {
        let firstTime=min(pending.support.first!.time,pending.availableThrough.first ?? 0)
        let i=imuSamples.lastIndex(where:{$0.time<=firstTime}) ?? 0
        let support=Array(imuSamples.suffix(from:i).filter {$0.time<=latest.time})
        let q=mounting ?? simd_quatd(ix:0,iy:0,iz:0,r:1)
        return PCIMUPulseEvidence(policy:policy,
            cameraFromDevice:PCPosePulseTransform(translation:GCPVector(),qx:q.imag.x,qy:q.imag.y,qz:q.imag.z,qw:q.real),
            poseSamples:pending.support,imuSamples:support,imuAvailableThrough:pending.availableThrough,
            outcome:outcome,reason:reason,
            beforeTime:pending.before.time,afterTime:pending.after.time,confirmedAt:latest.time,
            predictedAfter:pending.predicted,estimatedDelta:pending.delta,
            baselineVelocity:GCPVector(pending.baseline.velocity),baselineAngularVelocity:GCPVector(pending.baseline.angularVelocity),
            rejectedInput:rejectedInput)
    }
    private mutating func fail(_ reason:PCPosePulseUnsafe,detail:String,latest:PCPosePulseSample?=nil,
                               includeCandidate:Bool=true,rejectedInput:PCIMURejectedInput?=nil)->PCPosePulseResult {
        if includeCandidate, var pending=candidate,let latest {
            if pending.support.last?.time != latest.time {
                pending.support.append(latest);pending.availableThrough.append(imuSamples.last?.time ?? 0)
            }
            // A long tracking interruption is a boundary, not a short sensor
            // window. Never publish an oversized, unreplayable diagnostic.
            if pending.support.count<=policy.maximumPoseSamples,
               latest.time-pending.support.first!.time<=policy.maximumHistoryDuration+1e-9 {
                let support=evidence(pending,latest:latest,outcome:"resolvedAsPhysicalMotion",reason:detail,rejectedInput:rejectedInput)
                if (support.imuSamples.first?.time ?? .infinity)<=(pending.availableThrough.first ?? 0),
                   support.imuSamples.count+(rejectedInput?.imu.count ?? 0)<=policy.maximumIMUSamples {
                    lastEvidence=support
                }
            }
        }
        candidate=nil
        samples=latest.map {[$0]} ?? []
        if let latest {availability=[latest.time:imuSamples.last?.time ?? 0]} else {availability=[:]}
        if let latest {retain(at:latest.time)}
        return .unsafe(reason)
    }
    mutating func ingest(time:Double,pose:GCPPose,epoch:GCPEpoch,imu:[PCIMUSample],
                         cameraFromDevice:simd_quatd)->PCPosePulseResult {
        lastEvidence=nil
        inputFailure=nil
        guard policy.valid else {reset();return .unsafe(.invalidPolicy)}
        guard time.isFinite,time>=0,pose.valid,epoch.generation>=0,epoch.alignmentRevision>=0,
              cameraFromDevice.vector.x.isFinite,cameraFromDevice.vector.y.isFinite,
              cameraFromDevice.vector.z.isFinite,cameraFromDevice.vector.w.isFinite,
              abs(simd_length_squared(cameraFromDevice.vector)-1)<1e-6 else {
            clear();return .unsafe(.invalidPose)
        }
        let sample=PCPosePulseSample(time:time,pose:pose,epoch:epoch)
        if let previous=samples.last {
            guard previous.epoch==epoch else {clear();samples=[sample];return .unsafe(.epochChanged)}
            guard time>previous.time else {clear();samples=[sample];return .unsafe(.nonMonotonicTime)}
            let dt=time-previous.time
            guard dt>=policy.minimumARInterval-1e-9,dt<=policy.maximumARInterval+1e-9 else {
                return fail(.intervalGap,detail:"ARIntervalGap",latest:sample)
            }
            let intervals=zip(samples,samples.dropFirst()).map {$1.time-$0.time}.suffix(policy.baselineIntervals).sorted()
            if !intervals.isEmpty,dt>intervals[intervals.count/2]*policy.maximumARGapRatio+1e-9 {
                return fail(.intervalGap,detail:"ARIntervalGap",latest:sample)
            }
        }
        if let mounting,simd_length(Self.vector(cameraFromDevice*mounting.inverse))>1e-4 {
            let q=cameraFromDevice
            let changed=PCPosePulseTransform(translation:GCPVector(),qx:q.imag.x,qy:q.imag.y,qz:q.imag.z,qw:q.real)
            let result=fail(.notImpulse,detail:"cameraDeviceAxesChanged",latest:sample,
                rejectedInput:PCIMURejectedInput(cameraFromDevice:changed))
            self.mounting=nil
            return result
        }
        // Float ARCamera transform/viewMatrix products have sub-microradian
        // round-off. Freeze the first mounting; never integrate that jitter.
        if mounting==nil {mounting=cameraFromDevice}
        let cameraFromDevice=mounting!
        guard receive(imu,at:time) else {
            return fail(.notImpulse,detail:"invalidIMUSamples",latest:sample,
                        includeCandidate:inputFailure != nil,rejectedInput:inputFailure)
        }
        let delivered=imuSamples.last?.time ?? 0
        guard let previous=samples.last else {
            samples=[sample];availability=[time:delivered];return .warmingUp
        }
        samples.append(sample);availability[time]=delivered;retain(at:time)
        if var pending=candidate {
            pending.support.append(sample);pending.availableThrough.append(delivered);candidate=pending
            guard time-pending.before.time<=policy.maximumWindowDuration+1e-9 else {
                return fail(.notImpulse,detail:"windowTooLong",latest:sample)
            }
            guard let (predicted,uncertainty,angularUncertainty,lever)=prediction(pending.before,
                baseline:pending.baseline,at:time,cameraFromDevice:cameraFromDevice) else {
                return fail(.notImpulse,detail:"missingStaleOrGappedIMU",latest:sample)
            }
            guard lever<=policy.maximumLeverArmUncertainty else {
                return fail(.notImpulse,detail:"rotationLeverArmUncertainty",latest:sample)
            }
            let delta=Self.transform(pose,predicted)
            let translation=simd_length(pose.position.v-predicted.position.v)
            let angle=simd_length(Self.vector(delta.rotation))
            // A chart rotation's displacement at the moving camera can shrink
            // while its rigid transform remains constant. Test return at the
            // fixed pre-window camera location, never at that moving point.
            let fixedDisplacement=simd_length(delta.point(pending.before.pose.position.v)-pending.before.pose.position.v)
            guard translation<=policy.maximumTranslationResidual,angle<=policy.maximumRotationResidual else {
                return fail(.stepTooLarge,detail:"residualTooLarge",latest:sample)
            }
            if (pending.peakTranslation>=policy.minimumTranslationResidual && fixedDisplacement<pending.peakTranslation*0.5)
                || (pending.peakRotation>=policy.minimumRotationResidual && angle<pending.peakRotation*0.5) {
                return fail(.notImpulse,detail:"returningResidual",latest:sample)
            }
            let expected=pending.delta.pose(predicted)
            let displacement=simd_length(pose.position.v-expected.position.v)
            let rotation=simd_length(Self.vector(pose.rotation*expected.rotation.inverse))
            let dt=time-previous.time
            let moving=displacement>policy.settlePositionTolerance || rotation>policy.settleRotationTolerance
                || displacement/dt>policy.maximumResidualSpeed || rotation/dt>policy.maximumResidualAngularSpeed
            pending.intervals+=1
            if moving {
                pending.after=sample;pending.predicted=predicted;pending.delta=delta;pending.settled=0
                pending.burstIntervals=pending.intervals
                pending.translationUncertainty=uncertainty;pending.rotationUncertainty=angularUncertainty
            } else {pending.settled+=1}
            pending.peakTranslation=max(pending.peakTranslation,fixedDisplacement)
            pending.peakRotation=max(pending.peakRotation,angle)
            candidate=pending
            guard pending.burstIntervals<=policy.maximumBurstIntervals else {
                return fail(.notImpulse,detail:"residualDidNotSettle",latest:sample)
            }
            guard pending.settled>=policy.afterIntervals else {return .pending(pending.after)}
            let endpointTranslation=simd_length(pending.after.pose.position.v-pending.predicted.position.v)
            let endpointAngle=simd_length(Self.vector(pending.delta.rotation))
            let linear=endpointTranslation>=policy.minimumTranslationResidual+pending.translationUncertainty
            let angular=endpointAngle>=policy.minimumRotationResidual+pending.rotationUncertainty
            guard linear || angular else {return fail(.notImpulse,detail:"residualWithinUncertainty",latest:sample)}
            let support=evidence(pending,latest:sample,outcome:"confirmed",reason:"stableIMUResidual")
            guard (support.imuSamples.first?.time ?? .infinity)<=(pending.availableThrough.first ?? 0) else {
                return fail(.notImpulse,detail:"insufficientRetainedEvidence",latest:sample,includeCandidate:false)
            }
            let span=pending.after.time-pending.before.time
            let dv=endpointTranslation/span,dw=endpointAngle/span
            let result=PCPosePulseEvent(policy:.motionTolerant,before:pending.before,after:pending.after,confirmedAt:time,
                predictedAfter:pending.predicted,worldDelta:pending.delta,
                baselineVelocity:GCPVector(pending.baseline.velocity),baselineAngularVelocity:GCPVector(pending.baseline.angularVelocity),
                velocityDeviation:dv,angularVelocityDeviation:dw,
                incomingAcceleration:dv/span,outgoingAcceleration:dv/span,
                incomingAngularAcceleration:dw/span,outgoingAngularAcceleration:dw/span,
                components:linear ? (angular ? .translationAndRotation:.translation):.rotation,
                supportSamples:pending.support,evidence:PCIMUPulseEvidence.assumption,imuEvidence:support)
            lastEvidence=support;candidate=nil;samples=[sample];availability=[time:delivered]
            return .confirmed(result)
        }
        guard samples.count>=policy.baselineIntervals+2 else {return .warmingUp}
        let support=Array(samples.dropLast().suffix(policy.baselineIntervals+1))
        guard let base=baseline(support,cameraFromDevice:cameraFromDevice),
              let (predicted,uncertainty,angularUncertainty,lever)=prediction(previous,baseline:base,at:time,cameraFromDevice:cameraFromDevice) else {
            return fail(.notImpulse,detail:"unavailablePhysicalBaseline",latest:sample)
        }
        let delta=Self.transform(pose,predicted)
        let translation=simd_length(pose.position.v-predicted.position.v)
        let angle=simd_length(Self.vector(delta.rotation))
        guard translation>policy.seedTranslationResidual || angle>policy.seedRotationResidual else {return .stable}
        // The anchor is exactly the last frame before pending, never backdated.
        candidate=Candidate(before:previous,after:sample,predicted:predicted,delta:delta,baseline:base,
            support:support+[sample],availableThrough:(support+[sample]).map {availability[$0.time] ?? 0},
            peakTranslation:simd_length(delta.point(previous.pose.position.v)-previous.pose.position.v),peakRotation:angle,
            translationUncertainty:uncertainty,rotationUncertainty:angularUncertainty)
        guard lever<=policy.maximumLeverArmUncertainty else {
            return fail(.notImpulse,detail:"rotationLeverArmUncertainty",latest:sample)
        }
        guard translation<=policy.maximumTranslationResidual,angle<=policy.maximumRotationResidual else {
            return fail(.stepTooLarge,detail:"residualTooLarge",latest:sample)
        }
        return .pending(sample)
    }
}
