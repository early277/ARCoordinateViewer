import Foundation
import simd

/// A reproducible *drift model*, not a claim that ARKit reported a world-chart
/// change. A confirmed jump corrects only the preceding continuous interval.
/// Each interval starts at identity and reaches the estimated old->new delta;
/// after the jump the raw camera/points already contain that update. Previous
/// completed intervals never receive the next interval's drift a second time.
struct PCPoseCorrectionSchedule {
    struct Segment {
        var start:Double
        var end:Double
        var after:Double
        var startOrdinal:Double
        var endOrdinal:Double
        var delta:PCPosePulseTransform
        var burstTransition=false
    }
    var autos:[PCFrame]
    var segments:[Segment]
    var epoch:GCPEpoch

    private func ordinal(_ time:Double)->Double {
        if time<=autos[0].time {return 0}
        if time>=autos.last!.time {return Double(autos.count-1)}
        let i=(0..<autos.count-1).first {autos[$0].time<=time && time<autos[$0+1].time}!
        return Double(i)+(time-autos[i].time)/(autos[i+1].time-autos[i].time)
    }
    /// Automatic-frame ordinal determines the interpolation weights. Extra
    /// manual frames/observations use timestamp interpolation within the same
    /// interval and never add support nodes or change the automatic weights.
    /// The pulse's before/after pair is a boundary, not an interpolation gap.
    func transform(at time:Double)throws->PCPosePulseTransform {
        guard time.isFinite,time>=0 else {throw PCFailure.invalidInput}
        for segment in segments {
            if time>segment.end && time<segment.after {
                guard segment.burstTransition else {throw PCFailure.correctionUnavailable}
                // No capture is admitted while a burst is pending, but the raw
                // trajectory (and earlier backdated samples) must remain usable.
                // Explicit short transition model: remaining old->new field
                // decays to identity as the raw chart itself reaches new pose.
                let fraction=(time-segment.end)/(segment.after-segment.end)
                return try segment.delta.interpolated(1-fraction)
            }
            if time>=segment.start && time<=segment.end {
                let width=segment.endOrdinal-segment.startOrdinal
                // An interval without an automatic capture cannot contribute a
                // frame weight. Retain observations/trajectory using time within
                // that interval; never modify already completed earlier points.
                let progress=width>1e-9 ? (ordinal(time)-segment.startOrdinal)/width:(time-segment.start)/(segment.end-segment.start)
                let fraction=max(0,min(1,progress))
                return try segment.delta.interpolated(fraction)
            }
        }
        // Before the first automatic sample and after the last event the raw
        // coordinates receive identity, never an extrapolated/doubled update.
        return .identity
    }
}

enum PCPoseCorrection {
    static let recipe="pose-pulse-drift-v1; segment-local; auto-ordinal; manual-time-interpolation; shortest-quaternion-arc; raw unchanged; ARKit cause unproven"

    /// Motion classifications are provenance only: no transform, barrier or
    /// correction prohibition is inferred from the user-selected physical rule.
    static func validateMotionDecisions(_ record:PCRecord)throws {
        guard record.checkpoint?.imuInput?.valid ?? true else {throw PCFailure.corrupt}
        let decisions=record.checkpoint?.motionDecisions ?? [],count=record.checkpoint?.motionDecisionCount ?? decisions.count
        guard decisions.count<=256,count>=decisions.count,count>=0,(count==0)==decisions.isEmpty,Set(decisions.map(\.id)).count==decisions.count,
              decisions.allSatisfy({$0.valid && $0.epoch==record.frames.first?.frame.epoch}),
              zip(decisions,decisions.dropFirst()).allSatisfy({$0.time<$1.time}) else {throw PCFailure.corrupt}
    }
    private static func close(_ a:GCPPose,_ b:GCPPose)->Bool {
        simd_distance(a.position.v,b.position.v)<1e-6 && abs(simd_dot(a.rotation.vector,b.rotation.vector))>1-1e-10
    }
    /// Validate the journal itself, independently of any saved derived result.
    /// Missing journals in older recordings are exactly the identity path.
    static func schedule(_ record:PCRecord)throws->PCPoseCorrectionSchedule? {
        try validateMotionDecisions(record)
        let events=record.checkpoint?.poseEvents ?? []
        guard !events.isEmpty else {return nil}
        guard events.count<=128,Set(events.map(\.id)).count==events.count,
              let epoch=record.frames.first?.frame.epoch,
              record.frames.allSatisfy({$0.frame.epoch==epoch && $0.frame.time.isFinite && $0.frame.time>=0}),
              zip(record.frames,record.frames.dropFirst()).allSatisfy({$0.frame.time<$1.frame.time}) else {throw PCFailure.foreignEpoch}
        let autos=record.frames.filter{$0.frame.automatic}.map(\.frame)
        guard !autos.isEmpty else {throw PCFailure.correctionUnavailable}
        func ordinal(_ time:Double)->Double {
            if time<=autos[0].time {return 0}
            if time>=autos.last!.time {return Double(autos.count-1)}
            let i=(0..<autos.count-1).first {autos[$0].time<=time && time<autos[$0+1].time}!
            return Double(i)+(time-autos[i].time)/(autos[i+1].time-autos[i].time)
        }
        var segments:[PCPoseCorrectionSchedule.Segment]=[]
        var start=autos[0].time,previousConfirmation = -Double.infinity
        for event in events {
            let policy=event.policy
            let values=[event.velocityDeviation,event.angularVelocityDeviation,event.incomingAcceleration,event.outgoingAcceleration,
                        event.incomingAngularAcceleration,event.outgoingAngularAcceleration]
            guard event.isReproducible,policy.valid,event.before.epoch==epoch,event.after.epoch==epoch,
                  event.before.time.isFinite,event.before.time>=0,event.after.time.isFinite,event.after.time>event.before.time,
                  event.after.time-event.before.time>=policy.minimumInterval,event.after.time-event.before.time<=(event.imuEvidence == nil ? policy.maximumInterval:0.5),
                  event.before.pose.valid,event.after.pose.valid,event.predictedAfter.valid,event.worldDelta.valid,
                  event.confirmedAt.isFinite,event.confirmedAt>=event.after.time,event.before.time>=previousConfirmation,
                  event.baselineVelocity.finite,event.baselineAngularVelocity.finite,
                  values.allSatisfy({$0.isFinite && $0>=0}),!event.evidence.isEmpty,event.evidence.utf8.count<=1024,
                  close(event.worldDelta.pose(event.predictedAfter),event.after.pose),
                  simd_distance(event.predictedAfter.position.v,event.after.pose.position.v)<=policy.maximumStepAtCamera+1e-9 else {throw PCFailure.corrupt}
            let angle=2*acos(min(1,abs(event.worldDelta.rotation.real)))
            guard angle<=policy.maximumStepAngle+1e-9 else {throw PCFailure.corrupt}
            let linear=event.components != .rotation,angular=event.components != .translation
            guard event.imuEvidence != nil || ((!linear || (event.velocityDeviation>=policy.velocityDeviation-1e-9 && event.incomingAcceleration>=policy.acceleration && event.outgoingAcceleration>=policy.acceleration)) &&
                  (!angular || (event.angularVelocityDeviation>=policy.angularVelocityDeviation-1e-9 && event.incomingAngularAcceleration>=policy.angularAcceleration && event.outgoingAngularAcceleration>=policy.angularAcceleration))) else {throw PCFailure.corrupt}
            // Events before any saved automatic input have no preceding captured
            // interval to redistribute. Their raw evidence remains in the journal.
            if event.before.time>=autos[0].time {
                guard event.before.time>=start else {throw PCFailure.correctionUnavailable}
                let a=ordinal(start),b=ordinal(event.before.time)
                if event.imuEvidence==nil {guard event.before.time>start,b>a else {throw PCFailure.correctionUnavailable}}
                if event.before.time>start {
                    segments.append(.init(start:start,end:event.before.time,after:event.after.time,startOrdinal:a,endOrdinal:b,delta:event.worldDelta,burstTransition:event.imuEvidence != nil))
                }
            } else {
                guard record.frames.allSatisfy({$0.frame.time>=event.after.time}),
                      record.checkpoint?.raw.observations.allSatisfy({$0.time>=event.after.time}) ?? true else {throw PCFailure.correctionUnavailable}
            }
            start=max(autos[0].time,event.after.time);previousConfirmation=event.confirmedAt
        }
        return PCPoseCorrectionSchedule(autos:autos,segments:segments,epoch:epoch)
    }
    static func transform(at time:Double,record:PCRecord)throws->PCPosePulseTransform {
        try schedule(record)?.transform(at:time) ?? .identity
    }

    /// Build only small derived metadata. Stored XYZ/RGB, original camera
    /// matrices, evidence and historical fits remain untouched on disk. Every
    /// caller can feed this result back without applying the field twice.
    static func prepare(_ record:PCRecord)throws->PCRecord {
        guard !record.posePrepared else {return record}
        var result=record
        guard let schedule=try schedule(record) else {result.posePrepared=true;return result}
        guard var checkpoint=record.checkpoint else {throw PCFailure.correctionUnavailable}
        let original=checkpoint.raw
        guard Set(original.observations.map(\.id)).count==original.observations.count,
              Set(original.points.map(\.id)).count==original.points.count else {throw PCFailure.corrupt}
        for observation in original.observations {
            _=try observation.ray();try observation.captureEvidence?.validate(observation)
        }
        for point in original.points {
            guard let first=original.observations.first(where:{$0.id==point.registrationObservationID}),first.epoch==point.epoch else {throw PCFailure.corrupt}
            let expected:GCPPoint
            if let secondID=point.secondRegistrationObservationID {
                guard let second=original.observations.first(where:{$0.id==secondID}),second.id != first.id else {throw PCFailure.corrupt}
                expected=try GCPMath.register(first,second,translation:point.registrationTranslation)
            } else {expected=try GCPMath.register(first,translation:point.registrationTranslation)}
            guard point.position.finite,simd_distance(point.position.v,expected.position.v)<1e-9,point.triangulation==expected.triangulation else {throw PCFailure.corrupt}
        }
        // Validate saved fits against ORIGINAL observations before replacing
        // anything. A corrupt old fit must not be silently healed by recompute.
        for saved in checkpoint.fits {
            guard try GCPMath.fit(raw:original,bindings:saved.bindings,context:saved.context,includeCancelled:true)==saved else {throw PCFailure.corrupt}
        }
        for i in result.frames.indices {
            let transform=try schedule.transform(at:result.frames[i].frame.time)
            result.poseTransforms[result.frames[i].id]=transform
            result.frames[i].frame.pose=transform.pose(result.frames[i].frame.pose)
            // The raw source matrix is still retained in `record` and on disk;
            // it is not calibration evidence for this explicitly derived pose.
            result.frames[i].frame.sourceCameraTransform=nil
        }
        for i in checkpoint.raw.observations.indices {
            let observation=checkpoint.raw.observations[i]
            guard observation.epoch==schedule.epoch else {throw PCFailure.foreignEpoch}
            checkpoint.raw.observations[i].pose=try schedule.transform(at:observation.time).pose(observation.pose)
            checkpoint.raw.observations[i].captureEvidence=nil
        }
        let byID=Dictionary(uniqueKeysWithValues:checkpoint.raw.observations.map{($0.id,$0)})
        for i in checkpoint.raw.points.indices {
            let point=checkpoint.raw.points[i]
            guard point.epoch==schedule.epoch,let first=byID[point.registrationObservationID] else {throw PCFailure.foreignEpoch}
            var regenerated:GCPPoint
            if let secondID=point.secondRegistrationObservationID {
                guard let second=byID[secondID] else {throw PCFailure.corrupt}
                // Both camera origins AND bearing directions were transformed at
                // their own exposure. Re-test full triangulation quality; never
                // translate an already intersected midpoint across this field.
                regenerated=try GCPMath.register(first,second)
            } else {regenerated=try GCPMath.register(first)}
            regenerated.id=point.id
            checkpoint.raw.points[i]=regenerated
        }
        for i in checkpoint.raw.trajectory.indices {
            let sample=checkpoint.raw.trajectory[i]
            guard sample.rawPose.valid,sample.time.isFinite,sample.time>=0 else {throw PCFailure.corrupt}
            if let matrix=sample.cameraTransform {
                guard close(try GCPCaptureEvidence.pose(matrix),sample.rawPose) else {throw PCFailure.corrupt}
            }
            // Initial warm-up samples from earlier generations were never part
            // of the captured continuous component. Keep their raw metadata.
            guard sample.epoch==schedule.epoch else {continue}
            checkpoint.raw.trajectory[i].rawPose=try schedule.transform(at:sample.time).pose(sample.rawPose)
            checkpoint.raw.trajectory[i].cameraTransform=nil
        }
        checkpoint.fits=try checkpoint.fits.map {saved in
            try GCPMath.fit(raw:checkpoint.raw,bindings:saved.bindings,context:saved.context,includeCancelled:true)
        }
        result.checkpoint=checkpoint;result.posePrepared=true
        return result
    }
}
