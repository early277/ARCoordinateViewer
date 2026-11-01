import Foundation
import simd

enum GCPCaptureIntent:Hashable {case automatic,register,reobserve}
enum GCPCaptureMode:String,CaseIterable {case automatic,depthPoint,twoRays}
enum GCPInputOutcome:Equatable {
    case held(GCPInputIssue)
    case draftRegistered(UUID)
    case draftReobserved(UUID,rank:Int)
}
/// Main-queue adapter state; idle has no frame/buffer work or storage side effects.
/// All accepted/failed finite observations are drafts until persist(to:) succeeds.
@MainActor final class GCPInputSession {
    private(set) var isRecording=false
    private(set) var isSuspended=false
    func suspendCapture() {guard isRecording else {return};finishCaptureStep();isSuspended=true}
    @discardableResult func resumeCapture(now:Double=ProcessInfo.processInfo.systemUptime)->Bool {
        guard isSuspended,relativePoseTrusted,let last=lastTime,now>=last,now-last<=0.25 else {return false}
        isSuspended=false;return true
    }
    private(set) var raw:GCPRawSession?
    private(set) var epoch=GCPEpoch()
    private(set) var lastOutcome:GCPInputOutcome?
    private(set) var latestFit:GCPTranslationFit?
    private(set) var captureMode=GCPCaptureMode.automatic
    private(set) var pendingFirstObservation:GCPObservation?
    private var firstTranslation=GCPVector()
    private(set) var lastRayDiagnostics:GCPRayDiagnostics?
    private(set) var captureRevision=0
    private var undoOperation:(operation:GCPCaptureOperation,bindings:[GCPBinding],fit:GCPTranslationFit?)?
    var canUndoCapture:Bool {isRecording && !isSuspended && pending==nil && (pendingFirstObservation != nil || undoOperation != nil)}
    func setCaptureMode(_ mode:GCPCaptureMode) {
        guard captureMode != mode else {return}
        cancelFirstRay();pending=nil;undoOperation=nil;captureMode=mode;lastOutcome=nil;lastRayDiagnostics=nil
    }
    /// Ends the current UI action without resetting a still-continuous AR epoch.
    /// Call before a stopped checkpoint; this does not itself permit resumption.
    func finishCaptureStep() {
        cancelFirstRay();pending=nil;undoOperation=nil;lastOutcome=nil
    }
    private func cancelFirstRay() {
        guard let first=pendingFirstObservation else {return}
        let cancellations=(raw?.captureCancellations ?? [])+[GCPCaptureCancellation(operationID:nil,observationIDs:[first.id])]
        raw?.captureCancellations=cancellations
        pendingFirstObservation=nil;captureRevision+=1
    }
    /// One opportunity only: cancelling a first bearing never reveals an older
    /// undo operation. Evidence remains in the append-only cancellation journal.
    @discardableResult func undoCapture()->Bool {
        guard canUndoCapture else {return false}
        if pendingFirstObservation != nil {cancelFirstRay()}
        else if let previous=undoOperation {
            let cancellations=(raw?.captureCancellations ?? [])+[GCPCaptureCancellation(operationID:previous.operation.id,observationIDs:previous.operation.observationIDs)]
            raw?.captureCancellations=cancellations
            recentBindings=previous.bindings;latestFit=previous.fit;captureRevision+=1
        }
        undoOperation=nil;pending=nil;lastOutcome=nil;return true
    }
    private func accepted(_ operation:GCPCaptureOperation,previousBindings:[GCPBinding],previousFit:GCPTranslationFit?) {
        let operations=(raw?.captureOperations ?? [])+[operation]
        raw?.captureOperations=operations
        undoOperation=(operation,previousBindings,previousFit)
    }
    private(set) var tracking=GCPTracking.unavailable
    private(set) var normalSince:Double?
    private var normalFrames=0
    private var unstableEpisode=true
    // Tracking callbacks can announce normal before the first recovered frame arrives.
    // Keep that boundary pending so uncertain samples never enter a trusted fit interval.
    private var needsNormalEpoch=false
    private var notBefore=0.0
    private var lastTime:Double?
    private var lastPose:GCPPose?
    private var viewKey:[Double]?
    private var recentBindings:[GCPBinding]=[]
    private var pending:(id:UUID,intent:GCPCaptureIntent,epoch:GCPEpoch,key:[Double],time:Double)?
    let maximumObservations:Int
    let maximumSamples:Int
    let matchPolicy:GCPMatchPolicy
    init(maximumObservations:Int=512,maximumSamples:Int=4096,matchPolicy:GCPMatchPolicy = .conservative) {
        self.maximumObservations=maximumObservations;self.maximumSamples=maximumSamples;self.matchPolicy=matchPolicy
    }
    var hasPendingRequest:Bool {pending != nil}
    func restoreDraft(_ restored:GCPRawSession) {
        guard !isRecording else {return};raw=restored
        epoch=GCPEpoch();epoch.generation=(restored.trajectory.map { $0.epoch.generation }.max() ?? 0)+1
        barrier(at:ProcessInfo.processInfo.systemUptime);lastOutcome=nil
    }
    func newDraft() {guard !isRecording else {return};raw=nil;epoch=GCPEpoch();lastOutcome=nil;pendingFirstObservation=nil;undoOperation=nil;captureRevision+=1}

    private func barrier(at time:Double) {
        cancelFirstRay();undoOperation=nil
        epoch.generation &+= 1;notBefore=max(notBefore,time);normalSince=nil;normalFrames=0
        lastTime=nil;lastPose=nil;pending=nil;recentBindings=[];latestFit=nil;unstableEpisode=true
    }
    func beginExplicit(now:Double=ProcessInfo.processInfo.systemUptime) {
        guard !isRecording,now.isFinite,now>=0 else {return}
        if raw==nil {raw=GCPRawSession()}
        guard (raw?.observations.count ?? 0)<maximumObservations,(raw?.trajectory.count ?? 0)<maximumSamples else {lastOutcome = .held(.capacity);return}
        isRecording=true;isSuspended=false;barrier(at:now);lastOutcome=nil
    }
    func pause(_ reason:GCPInputIssue = .sessionChanged,now:Double=ProcessInfo.processInfo.systemUptime) {
        guard isRecording else {return};isRecording=false;isSuspended=false;barrier(at:now);lastOutcome = .held(reason)
    }
    func sessionReset(_ token:UUID,now:Double=ProcessInfo.processInfo.systemUptime) {
        guard token != epoch.arSessionID else {return};epoch.arSessionID=token;tracking = .unavailable
        barrier(at:now);if isRecording {lastOutcome = .held(.sessionChanged)}
    }
    func alignmentChanged(_ revision:Int,now:Double=ProcessInfo.processInfo.systemUptime) {
        guard revision>=0,revision != epoch.alignmentRevision else {return};epoch.alignmentRevision=revision
        barrier(at:now);if isRecording {lastOutcome = .held(.sessionChanged)}
    }
    func trackingChanged(_ state:GCPTracking,now:Double=ProcessInfo.processInfo.systemUptime) {
        tracking=state
        guard state != .normal else {return}
        needsNormalEpoch=true
        if !unstableEpisode {barrier(at:now)}
        else {cancelFirstRay();undoOperation=nil;normalSince=nil;normalFrames=0;pending=nil;recentBindings=[];latestFit=nil}
        if isRecording {lastOutcome = .held(.tracking)}
    }
    var relativePoseTrusted:Bool {
        guard isRecording,tracking == .normal,normalFrames>=3,let first=normalSince,let last=lastTime else {return false}
        return last-first>=0.5
    }
    @discardableResult func request(_ intent:GCPCaptureIntent,now:Double=ProcessInfo.processInfo.systemUptime)->Bool {
        guard isRecording,!isSuspended else {lastOutcome = .held(.notRecording);return false}
        guard pending==nil else {lastOutcome = .held(.busy);return false}
        guard relativePoseTrusted,let key=viewKey,let last=lastTime,now>=last,now-last<=0.25 else {lastOutcome = .held(.unstable);return false}
        pending=(UUID(),intent,epoch,key,now);return true
    }
    /// A suspected pose step must never reuse a first bearing or an undo target.
    func posePulseBoundary(at time:Double) {
        finishCaptureStep();recentBindings=[];latestFit=nil
        notBefore=max(notBefore,time);normalSince=nil;normalFrames=0
    }
    func cancelRequest(reason:GCPInputIssue?=nil) {if pending != nil,let reason {lastOutcome = .held(reason)};pending=nil}
    func receive(_ frame:GCPFrameSnapshot,now:Double=ProcessInfo.processInfo.systemUptime,posePulseChecked:Bool=false,referenceTranslation:(GCPObservation)throws->GCPVector = {_ in GCPVector()}) {
        guard isRecording else {return}
        guard frame.time.isFinite,now.isFinite,now>=frame.time,now-frame.time<=0.25,frame.time>=notBefore,
              lastTime.map({frame.time>$0}) ?? true else {if pending != nil {lastOutcome = .held(.staleFrame);pending=nil};return}
        let pose:GCPPose
        do {pose=try GCPCaptureEvidence.pose(frame.matrix)}
        catch {barrier(at:frame.time);lastOutcome = .held(.core(.calibration));return}
        if let previous=lastPose,let time=lastTime {
            let distance=simd_length(pose.position.v-previous.position.v)
            let angle=2*acos(min(1,abs(simd_dot(pose.rotation.vector,previous.rotation.vector))))
            if !posePulseChecked && (frame.time-time>1 || distance>1 || distance/(frame.time-time)>3 || angle>1 || angle/(frame.time-time)>4) {
                barrier(at:frame.time);lastOutcome = .held(.sessionChanged)
            }
        }
        if let old=viewKey,old != frame.viewKey,pending != nil {pending=nil;lastOutcome = .held(.viewChanged)}
        viewKey=frame.viewKey
        if let first=pendingFirstObservation,frame.time-first.time>GCPMath.maxCommonInterval {
            cancelFirstRay();undoOperation=nil;pending=nil;lastOutcome = .held(.core(.intervalTooLong))
        }
        if frame.tracking == .normal,needsNormalEpoch {barrier(at:frame.time);needsNormalEpoch=false}
        trackingChanged(frame.tracking,now:frame.time)
        lastTime=frame.time;lastPose=pose
        if frame.tracking == .normal {
            if normalSince==nil {normalSince=frame.time}
            normalFrames+=1
            if relativePoseTrusted {unstableEpisode=false}
        }
        guard !isSuspended else {return}
        func appendSample() -> Bool {
            guard (raw?.trajectory.count ?? 0)<maximumSamples else {pause(.capacity,now:frame.time);return false}
            raw?.trajectory.append(GCPTrajectorySample(epoch:epoch,time:frame.time,rawPose:pose,tracking:frame.tracking,frameID:frame.frameID,cameraTransform:frame.matrix));return true
        }
        if raw?.trajectory.last?.epoch != epoch || frame.time-(raw?.trajectory.last?.time ?? -.infinity)>=0.5 {guard appendSample() else {return}}
        guard let request=pending else {return};pending=nil
        guard request.epoch==epoch,request.key==frame.viewKey else {lastOutcome = .held(.sessionChanged);return}
        guard relativePoseTrusted,frame.tracking == .normal else {lastOutcome = .held(.tracking);return}
        guard now-request.time<=0.35,frame.time>=request.time-0.05 else {lastOutcome = .held(.staleFrame);return}
        observe(frame,intent:request.intent,now:now,referenceTranslation:referenceTranslation)
    }
    /// The visible camera image and this snapshot have the same timestamp, pose,
    /// crop and depth. Newer tracking frames may already have been received.
    /// Never insert an older sample into the append-only trajectory journal.
    func displayUnavailable() {lastRayDiagnostics=nil;lastOutcome = .held(.staleFrame)}
    func captureDisplayed(_ frame:GCPFrameSnapshot,now:Double=ProcessInfo.processInfo.systemUptime,referenceTranslation:(GCPObservation)throws->GCPVector = {_ in GCPVector()}) {
        guard isRecording,!isSuspended else {lastOutcome = .held(.notRecording);return}
        guard pending==nil else {lastOutcome = .held(.busy);return}
        guard relativePoseTrusted,frame.tracking == .normal else {lastOutcome = .held(.tracking);return}
        guard frame.viewKey==viewKey else {lastOutcome = .held(.viewChanged);return}
        guard now.isFinite,frame.time.isFinite,now>=frame.time,now-frame.time<=0.25,
              frame.time>=notBefore,frame.time>=(normalSince ?? .infinity),
              let lastTime,frame.time<=lastTime,now-lastTime<=0.25,
              raw?.observations.last.map({frame.time>$0.time}) ?? true else {displayUnavailable();return}
        observe(frame,intent:.automatic,now:now,referenceTranslation:referenceTranslation)
    }
    private func observe(_ frame:GCPFrameSnapshot,intent requestedIntent:GCPCaptureIntent,now:Double,referenceTranslation:(GCPObservation)throws->GCPVector) {
        lastRayDiagnostics=nil
        guard (raw?.observations.count ?? 0)<maximumObservations else {pause(.capacity,now:frame.time);return}
        var observedIndex:Int?
        defer {
            if let index=observedIndex,raw?.observations[index].associationEvidence != nil {
                let outcome:String
                switch lastOutcome {
                case .draftRegistered(let id):outcome="registered";raw?.observations[index].associationEvidence?.matchedPointID=id
                case .draftReobserved(let id,let rank):outcome="reobserved-rank-\(rank)";raw?.observations[index].associationEvidence?.matchedPointID=id
                case .held(let issue):outcome="held: \(issue)"
                case nil:outcome=pendingFirstObservation?.id==raw?.observations[index].id ? "awaiting-second-ray":"held: no-result"
                }
                raw?.observations[index].associationEvidence?.outcome=outcome
            }
        }
        do {
            let reading=try GCPFrameInput.observation(frame,epoch:epoch,now:now),o=reading.observation
            if frame.time>(raw?.trajectory.last?.time ?? -.infinity) {
                guard (raw?.trajectory.count ?? 0)<maximumSamples else {pause(.capacity,now:frame.time);return}
                raw?.trajectory.append(GCPTrajectorySample(epoch:epoch,time:frame.time,rawPose:o.pose,tracking:frame.tracking,frameID:frame.frameID,cameraTransform:frame.matrix))
            }
            raw?.observations.append(o);captureRevision+=1;observedIndex=(raw?.observations.count ?? 1)-1
            raw?.observations[observedIndex!].associationEvidence=GCPAssociationEvidence(policy:matchPolicy,directionOnly:captureMode == .twoRays || !reading.depthAccepted,candidates:[],outcome:"pending")
            let previousBindings=recentBindings,previousFit=latestFit
            let translation=try referenceTranslation(o)
            if captureMode == .twoRays {
                guard let first=pendingFirstObservation else {
                    pendingFirstObservation=o;firstTranslation=translation;undoOperation=nil;lastOutcome=nil;return
                }
                lastRayDiagnostics=try GCPRayDiagnostics(first,o)
                let quality=try GCPMath.triangulate(first,o)
                guard let current=raw else {throw GCPFailure.invalidSession}
                let candidates=GCPMath.candidates(position:quality.position.v+firstTranslation.v,epoch:epoch,points:current.activePoints,policy:matchPolicy)
                raw?.observations[observedIndex!].associationEvidence?.candidates=candidates.map(\.0)
                guard candidates.count<=1 else {throw GCPFailure.ambiguous}
                if let target=candidates.first,requestedIntent != .register {
                    let bindings=[GCPBinding(observationID:first.id,pointID:target.0,directionOnly:true),GCPBinding(observationID:o.id,pointID:target.0,directionOnly:true)]
                    // This pair is a complete local translation constraint. Do not
                    // average in older pairs with a potentially different drift.
                    let fit=try GCPMath.fit(raw:current,bindings:bindings,context:GCPFitContext(epoch:epoch,relativePoseTrusted:relativePoseTrusted))
                    recentBindings=bindings;latestFit=fit;lastOutcome = .draftReobserved(target.0,rank:fit.rank)
                    accepted(GCPCaptureOperation(observationIDs:[first.id,o.id],pointID:target.0,registered:false),previousBindings:previousBindings,previousFit:previousFit)
                } else {
                    guard requestedIntent != .reobserve else {throw GCPFailure.noMatch}
                    // Explicit register must not create a duplicate within the gate.
                    guard candidates.isEmpty else {throw GCPFailure.ambiguous}
                    let point=try GCPMath.register(first,o,translation:firstTranslation);raw?.points.append(point)
                    recentBindings=[];latestFit=nil;lastOutcome = .draftRegistered(point.id)
                    accepted(GCPCaptureOperation(observationIDs:[first.id,o.id],pointID:point.id,registered:true),previousBindings:previousBindings,previousFit:previousFit)
                }
                pendingFirstObservation=nil;return
            }
            // Point mode explicitly refuses missing/unreliable depth instead of
            // silently switching to a bearing-only observation.
            if captureMode == .depthPoint && !reading.depthAccepted {throw GCPInputIssue.depthRequired}
            let intent=try requestedIntent == .automatic ? (GCPMath.shouldReobserve(o,points:raw?.activePoints ?? [],depthAccepted:reading.depthAccepted,translation:translation) ? .reobserve:.register):requestedIntent
            switch intent {
            case .automatic:throw GCPFailure.invalidObservation
            case .register:
                guard reading.depthAccepted else {lastOutcome = .held(.depthRequired);return}
                let point=try GCPMath.register(o,translation:translation);raw?.points.append(point);recentBindings=[];latestFit=nil
                lastOutcome = .draftRegistered(point.id)
                accepted(GCPCaptureOperation(observationIDs:[o.id],pointID:point.id,registered:true),previousBindings:previousBindings,previousFit:previousFit)
            case .reobserve:
                guard let current=raw else {return}
                let candidates=try GCPMath.candidates(o,points:current.activePoints,assumedTranslation:translation,directionOnly:!reading.depthAccepted,policy:matchPolicy)
                raw?.observations[observedIndex!].associationEvidence?.candidates=candidates.map(\.0)
                let point=try GCPMath.match(o,points:current.activePoints,assumedTranslation:translation,directionOnly:!reading.depthAccepted,policy:matchPolicy)
                let binding=GCPBinding(observationID:o.id,pointID:point,directionOnly:!reading.depthAccepted)
                var proposed=recentBindings.filter {b in current.observations.contains(where:{$0.id==b.observationID && $0.epoch==epoch && o.time-$0.time<=15 && $0.time>=(normalSince ?? o.time)})}
                proposed.append(binding)
                let fit=try GCPMath.fit(raw:current,bindings:proposed,context:GCPFitContext(epoch:epoch,relativePoseTrusted:relativePoseTrusted))
                recentBindings=proposed
                latestFit=fit;lastOutcome = .draftReobserved(point,rank:fit.rank)
                accepted(GCPCaptureOperation(observationIDs:[o.id],pointID:point,registered:false),previousBindings:previousBindings,previousFit:previousFit)
            }
        } catch let issue as GCPInputIssue {rejectCapture(issue)}
        catch let failure as GCPFailure {rejectCapture(.core(failure))}
        catch {rejectCapture(.core(.invalidObservation))}
    }
    private func rejectCapture(_ issue:GCPInputIssue) {
        // Insufficient parallax permits another view of the visibly retained
        // first bearing. A contradictory/ambiguous target must start a new pair.
        if pendingFirstObservation != nil {
            let keep:Bool
            switch issue {
            case .core(.insufficientBaseline),.core(.parallelDirections),.core(.illConditioned):keep=true
            default:keep=false
            }
            if !keep {cancelFirstRay();undoOperation=nil}
        }
        lastOutcome = .held(issue)
    }
    /// Explicit persistence; failure leaves the full draft and outcome in memory.
    func persist(to store:GCPStore) throws {if let raw {try store.saveRaw(raw)}}
}
