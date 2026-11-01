import Foundation
import Combine
import ARKit
import UIKit
import simd

extension PCMessage {
    static func input(_ issue:GCPInputIssue)->String {
        switch issue {
        case .busy:return "前の観測を処理中です"
        case .depthRequired:return "信頼できる深度がありません。2視点の視線も選べます"
        case .tracking,.unstable,.sessionChanged:return "追跡が安定するまでゆっくり端末を動かしてください"
        case .capacity:return "GCP記録量の上限です"
        case .staleFrame:return "観測フレームが古いため未登録です。静止してもう一度GCPを押してください"
        case .viewChanged:return "画面の向き・サイズが変わったため未登録です。照準を合わせ直してください"
        case .notRecording:return "収録中のみGCPを記録できます"
        case .core(let e):
            switch e {
            case .ambiguous:return "対象候補が複数あります。別の位置から同じ点を狙ってください"
            case .noMatch:return "既存GCPと一致しません。新規登録には切り替えません"
            case .insufficientBaseline:return "視点移動が不足しています。横に移動して同じ点を狙ってください"
            case .parallelDirections,.illConditioned,.incompleteTranslation:return "交会角が不足しています。遠い点ほど大きく横へ移動する必要があります"
            case .residualTooLarge:return "2本の視線が一致しません。同じ対象点を狙って取り直してください"
            case .behindCamera:return "交点がカメラの後方または測定範囲外です。取り直してください"
            case .intervalTooLong:return "第一視線から15秒を超えました。2視点を取り直してください"
            default:return error(e)
            }
        }
    }
}

private final class PCWriteState: @unchecked Sendable {var blocked=false;var coverage=PCRecordingCoverage();var lastCoverageTime = -Double.infinity} // worker queue only
private final class PCControllerReference {
    weak var value:PCController?
    init(_ value:PCController){self.value=value}
}
private enum PCRecordThumbnailCache {
    static func remove(_ id:UUID,from root:URL)throws {
        let fm=FileManager.default
        guard fm.fileExists(atPath:root.path) else {return}
        let info=try root.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
        guard info.isSymbolicLink != true,info.isDirectory==true else {throw PCFailure.corrupt}
        guard let entries=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsSubdirectoryDescendants]) else {throw PCFailure.corrupt}
        var count=0
        for case let url as URL in entries {
            count+=1;guard count<=10_000 else {throw PCFailure.capacity}
            let name=url.lastPathComponent,prefix=id.uuidString+"-"
            guard name.hasPrefix(prefix),name.hasSuffix(".json") else {continue}
            let hash=name.dropFirst(prefix.count).dropLast(5)
            guard hash.count==64,hash.allSatisfy({"0123456789abcdef".contains($0)}) else {continue}
            let values=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
            guard values.isSymbolicLink != true,values.isRegularFile==true else {continue}
            try fm.removeItem(at:url)
        }
    }
}

@MainActor final class PCController:ObservableObject {
    enum Phase {case idle,starting,recording,saving,review,processing,ready,exporting,failed}
    @Published private(set) var phase=Phase.idle
    @Published var message="開始すると色付き点群を記録します"
    // Stopped previews show only actionable notices, not routine explanations.
    @Published var previewNotice:String?
    @Published private(set) var savedCount=0
    @Published private(set) var waiting=0
    private(set) var preview:[PCVertex]=[] // Bounded recording sample, published by previewRevision.
    private(set) var recordingPreview=PCDetailPreview()
    @Published private(set) var gcpFeedback=""
    private var displayedOutcome:GCPInputOutcome?
    private var displayedFirstID:UUID?
    private var displayedDiagnostics:String?
    @Published private(set) var detailPreview:PCDetailPreview?
    @Published private(set) var previewRevision=0
    @Published private(set) var detailLoading=false
    @Published private(set) var gcps:[GCPPoint]=[]
    @Published private(set) var progress=0.0
    @Published private(set) var corrected=false
    @Published private(set) var historical=false
    @Published private(set) var overlayInWorld=true
    @Published private(set) var modelViewRequested=false
    @Published private(set) var resumeBlockedReason:String?
    private var continuationID:UUID?
    private var cameraSessionID:UUID?
    @Published private(set) var records:[UUID]=[]
    @Published private(set) var savedRecords:[PCSavedRecord]=[]
    @Published private(set) var recordsLoading=false
    @Published private(set) var recordsError:String?
    @Published private(set) var deletingRecordID:UUID?
    @Published private(set) var deletionMessage:String?
    private static var peers:[UUID:PCControllerReference]=[:]
    private static var deletingRoots=Set<String>()
    private let peerID=UUID()
    private var catalogueGeneration=0
    @Published private(set) var thumbnails:[UUID:PCThumbnail]=[:]
    @Published private(set) var thumbnailErrors:[UUID:String]=[:]
    private var thumbnailRequests=Set<UUID>()
    @Published private(set) var record:PCRecord?
    @Published private(set) var coordinateSolution:PCControlSolution?
    @Published private(set) var controlNeedsReload=false
    private var coordinateMarkers:[SIMD3<Float>?]=[] // Built on the worker, never per AR frame.
    @Published private(set) var gcpMode=GCPCaptureMode.depthPoint
    @Published private(set) var gcpRevision=0
    let input=GCPInputSession(maximumObservations:128,maximumSamples:PCLimits.maximumTrajectorySamples,matchPolicy:.scanOneMetre)
    let store:PCStore
    private let thumbnailCacheRoot:URL
    private let writeState=PCWriteState()
    private let worker=DispatchQueue(label:"point-cloud-store",qos:.utility)
    private var id:UUID?
    private var acceptedEpoch:GCPEpoch?
    private var lastAuto:PCFrame?
    private var lastAcceptedTime = -Double.infinity
    private var nextAttempt=0.0
    private var previewPose:GCPPose?
    private var previewTime:Double?
    private var fits:[GCPTranslationFit]=[]
    private var poseDetector=PCPosePulseDetector(policy:.motionTolerant)
    private var imuDetector=PCIMUPoseDetector()
    private var imuInput:PCIMUInputSummary?
    private var usingIMU=false
    private var poseEvents:[PCPosePulseEvent]=[]
    private var motionDecisions:[PCPoseMotionDecision]=[]
    @Published private(set) var motionDecisionCount=0
    private var motionFallbackActive=false
    private var motionEpisodeRecorded=false
    private var motionWarningUntil=0.0
    private var lastMotionCheckpoint = -Double.infinity
    private let motionWarning="急な動きを実動作として扱い、補正せず記録を続けます"
    private var canCaptureTrackingFrame:Bool {
        input.relativePoseTrusted || (acceptedEpoch != nil && input.epoch==acceptedEpoch && input.tracking == .normal)
    }
    @Published private(set) var posePulsePending=false
    private func setPosePulsePending(_ value:Bool) {if posePulsePending != value {posePulsePending=value}}
    private var reference=GCPVector()
    private var stopCheckpoint:PCCheckpoint?
    private var terminalError:String?
    private var failedPayloads:[PCRawFrame]=[]
    private var acceptedBytes:Int64=0
    private var acceptedFrames=0
    private var checkpointWriting=false
    private var checkpointDirty=false
    private var sceneActive=true
    private var acceptedPointBudget=0
    private var control:PCWorkControl?
    private var backgroundTask=UIBackgroundTaskIdentifier.invalid
    var captureVisibleGCP:(()->GCPFrameSnapshot?)?
    var captureLast:(()->PCRawFrame?)?
    var startCamera:(()->Void)?
    var stopCamera:(()->Void)?
    var cameraOffset:SIMD3<Float> {
        guard corrected,let record,let last=record.frames.last,
              let value=record.selection?.offsets[last.id] else {return .zero}
        return SIMD3<Float>(value.v)
    }
    var displayedCount:Int {detailPreview?.count ?? preview.count}
    var coordinateDescription:String {
        if let solution=coordinateSolution,let state=record?.control {
            if solution.frameCorrection?.localOnly==true {return "同一点の相対補正済み・ローカルAR座標（公共座標には未整合）"}
            return (solution.frameCorrection?.yawResolved==false ? "並進のみ・方位未確定／":"座標対応を適用・")+state.proposal.reference.label+(solution.transform.height==nil ? "／鉛直は未整合":"")+"（倍率1・精度保証なし）"
        }
        return corrected ? (record?.checkpoint?.poseEvents?.isEmpty==false ? "ローカル座標・推定急変を配分後GCP補正（精度未検証）":"ローカル座標・平行移動補正済み（公共座標には未整合）"):"ローカル座標・未補正（GCPなしでPLY出力可／公共座標には未整合）"
    }
    var markerPositions:[SIMD3<Float>?] {
        if coordinateSolution != nil || corrected {return coordinateMarkers}
        return gcps.map {PCGCPDisplay.position($0,corrected:corrected)}
    }
    var pendingGCPRay:GCPObservation? {input.pendingFirstObservation}
    var canUndoGCP:Bool {phase == .recording && input.canUndoCapture}
    func gcpNumber(_ id:UUID)->Int? {
        let all=(historical ? record?.checkpoint?.raw:(input.raw ?? record?.checkpoint?.raw))?.points ?? []
        return all.firstIndex(where:{$0.id==id}).map{$0+1}
    }
    var gcpNumbers:[Int] {gcps.map {gcpNumber($0.id) ?? 0}}
    var showingModel:Bool {historical || !overlayInWorld || modelViewRequested || coordinateSolution != nil}
    var canReturnToAR:Bool {!controlNeedsReload && !historical && overlayInWorld && resumeBlockedReason==nil && coordinateSolution==nil && !(corrected && record?.checkpoint?.poseEvents?.isEmpty==false)}
    var canResume:Bool {
        [.review,.ready].contains(phase) && !controlNeedsReload && !historical && overlayInWorld && resumeBlockedReason==nil && sceneActive &&
        acceptedEpoch != nil && input.epoch==acceptedEpoch && input.relativePoseTrusted && input.isSuspended &&
        previewTime.map{ProcessInfo.processInfo.systemUptime-$0<=0.25}==true && failedPayloads.isEmpty && stopCheckpoint==nil && terminalError==nil
    }
    func setModelView(_ modelView:Bool) {
        guard [.review,.ready].contains(phase),!controlNeedsReload else {return}
        guard modelView || canReturnToAR else {return}
        modelViewRequested=modelView
    }
    func resume() {
        guard canResume,let id,let record,let raw=input.raw else {return}
        let token=UUID(),checkpoint=PCCheckpoint(raw:raw,fits:fits,stopped:false,reason:"同一セッションで追記開始",continuationID:token,poseEvents:poseEvents.isEmpty ? nil:poseEvents,motionDecisions:motionDecisions.isEmpty ? nil:motionDecisions,motionDecisionCount:motionDecisionCount==0 ? nil:motionDecisionCount,imuInput:imuInput)
        let expected=record.frames.map(\.id),epoch=input.epoch,store=store
        previewNotice=nil;phase = .starting;message="停止時の保存を保持し、追記を準備中"
        worker.async {
            let result=Result {()->(PCRecord,Bool,Int64) in
                do {
                    let used=try store.storageBytes(id)
                    guard used<store.maximumBytes-64*1024*1024 else {throw PCFailure.recordLimit}
                    return (try store.resume(checkpoint,id:id,expectedFrames:expected),true,try store.storageBytes(id))
                }
                catch {
                    // Inspect uncertain completion. If our continuation committed,
                    // close it explicitly; never repeat acquisition or restore an old transform.
                    guard let current=try? store.load(id),current.checkpoint?.continuationID==token else {throw error}
                    var stopped=checkpoint;stopped.stopped=true;stopped.reason="追記準備の保存が中断されました。受理済み入力を保持しています"
                    try store.checkpoint(stopped,id:id);return (try store.load(id),false,try store.storageBytes(id))
                }
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let (value,complete,used)):
                    self.acceptedBytes=max(self.acceptedBytes,used)
                    self.continuationID=token;self.record=value;self.corrected=false;self.coordinateSolution=nil;self.coordinateMarkers=[]
                    self.modelViewRequested=false;self.detailPreview=nil;self.previewRevision+=1
                    guard complete else {
                        self.resumeBlockedReason="追記準備が中断されました。保存内容を確認し、今回は再開できません"
                        self.loadStoppedPreview(value);return
                    }
                    self.poseDetector.reset();self.imuDetector.reset();self.setPosePulsePending(false)
                    self.phase = .recording
                    guard self.sceneActive,self.resumeBlockedReason==nil,self.overlayInWorld,self.input.epoch==epoch,self.input.resumeCapture() else {
                        self.resumeBlockedReason="追記準備中に追跡の連続性を確認できなくなりました"
                        self.stop(reason:self.resumeBlockedReason!,closingFrame:false);return
                    }
                    self.message="同じ点群へ追記中。以前の補正・座標対応は保持し、停止後に再計算してください"
                case .failure(let error):
                    self.phase = .review;self.resumeBlockedReason="追記開始の保存が未完了。原記録は保持されています"
                    self.message=self.resumeBlockedReason!+": \(PCMessage.error(error))"
                    self.previewNotice=self.message
                }
            }
        }
    }
    var canExport:Bool {phase == .ready && !controlNeedsReload && savedCount>0}
    var canClose:Bool {![Phase.starting,.recording,.saving,.processing,.exporting].contains(phase) && failedPayloads.isEmpty && stopCheckpoint==nil}
    init(root:URL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PointCloudRecords",isDirectory:true),storeOverride:PCStore?=nil,thumbnailCacheRoot:URL?=nil) {
        store=storeOverride ?? PCStore(root:root)
        self.thumbnailCacheRoot=thumbnailCacheRoot ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("PointCloudThumbnails",isDirectory:true)
        // Opening screens must not accumulate UUIDs and empty weak boxes when
        // no record is deleted. Keep every still-live peer for deletion safety.
        Self.peers=Self.peers.filter{$0.value.value != nil}
        Self.peers[peerID]=PCControllerReference(self)
    }
    private var storageKey:String {store.root.resolvingSymlinksInPath().standardizedFileURL.path}
    private func storagePeers()->[PCController] {
        Self.peers=Self.peers.filter{$0.value.value != nil}
        return Self.peers.values.compactMap(\.value).filter{$0.storageKey==storageKey}
    }
    func deletionBlockedReason(_ target:UUID)->String? {
        if Self.deletingRoots.contains(storageKey) {return "点群の削除処理中です"}
        if recordsLoading {return "保存記録を確認中です"}
        guard savedRecords.contains(where:{$0.id==target}) else {return "一覧を更新してから削除してください"}
        for peer in storagePeers() {
            if [.starting,.recording,.saving,.processing,.exporting].contains(peer.phase) || peer.waiting>0 || peer.checkpointWriting || peer.checkpointDirty || !peer.failedPayloads.isEmpty || peer.stopCheckpoint != nil {
                return "収録・保存・処理が終わり、点群を閉じてから削除してください"
            }
            if peer.id==target || peer.record?.id==target {return "この点群を閉じてから削除してください"}
        }
        return nil
    }
    /// A per-record confirmation in the gallery is required before calling.
    /// Reserve synchronously so another controller cannot open the target while
    /// the worker marks and purges it. Weak peers never retain large previews.
    func deleteRecord(_ target:UUID) {
        guard deletionBlockedReason(target)==nil else {deletionMessage=deletionBlockedReason(target);return}
        Self.deletingRoots.insert(storageKey);deletingRecordID=target
        deletionMessage="選んだ点群を削除中";catalogueGeneration+=1;recordsLoading=false
        thumbnails[target]=nil;thumbnailErrors[target]=nil
        let store=store,key=storageKey,cache=thumbnailCacheRoot
        worker.async {
            let result=Result {()->Bool in
                try store.deleteRecord(target)
                do {try PCRecordThumbnailCache.remove(target,from:cache);return true}
                catch {return false}
            }
            DispatchQueue.main.async {
                Self.deletingRoots.remove(key);self.deletingRecordID=nil
                switch result {
                case .success(let clean):self.deletionMessage=clean ? "点群を削除しました":"点群を削除しました。一部サムネイルのキャッシュは消去未完了です"
                case .failure(let error):self.deletionMessage="削除は完了していません。\(error.localizedDescription)。一覧を確認してください"
                }
                for peer in self.storagePeers() {
                    peer.catalogueGeneration+=1;peer.recordsLoading=false
                    peer.savedRecords.removeAll{$0.id==target};peer.records.removeAll{$0==target}
                    peer.thumbnails[target]=nil;peer.thumbnailErrors[target]=nil
                    peer.discover()
                }
            }
        }
    }
    func discover() {
        guard !recordsLoading,deletingRecordID==nil else {return};recordsLoading=true
        catalogueGeneration+=1;let generation=catalogueGeneration
        let store=store;worker.async {let result=Result{try store.summaries()};DispatchQueue.main.async {
            guard generation==self.catalogueGeneration else {return}
            self.recordsLoading=false
            switch result {
            case .success(let v):
                self.savedRecords=v;self.records=v.map(\.id);self.recordsError=nil
                let keys=Dictionary(uniqueKeysWithValues:v.compactMap{item in item.thumbnailKey.map{(item.id,$0)}})
                for id in Array(self.thumbnails.keys) where self.thumbnails[id]?.key != keys[id] {self.thumbnails[id]=nil;self.thumbnailErrors[id]=nil}
            case .failure(let e):self.recordsError="記録一覧: \(PCMessage.error(e))";self.message=self.recordsError!
            }
        }}
    }
    func loadThumbnail(_ summary:PCSavedRecord) {
        guard !Self.deletingRoots.contains(storageKey) else {return}
        guard let key=summary.thumbnailKey,thumbnails[summary.id]?.key != key,thumbnailRequests.count<4,!thumbnailRequests.contains(summary.id) else {return}
        thumbnails[summary.id]=nil;thumbnailErrors[summary.id]=nil
        thumbnailRequests.insert(summary.id)
        let store=store,cache=thumbnailCacheRoot
        worker.async {let result=Result{try store.thumbnail(summary,cache:cache)};DispatchQueue.main.async {
            self.thumbnailRequests.remove(summary.id)
            guard let current=self.savedRecords.first(where:{$0.id==summary.id}) else {return}
            guard current.thumbnailKey==summary.thumbnailKey else {self.loadThumbnail(current);return}
            switch result {
            case .success(let value):
                if self.thumbnails.count>=24,let first=self.thumbnails.keys.first {self.thumbnails[first]=nil}
                self.thumbnails[summary.id]=value;self.thumbnailErrors[summary.id]=nil
            case .failure:self.thumbnailErrors[summary.id]="サムネイル未生成・開くと内容を確認"
            }
        }}
    }
    func begin() {
        guard phase == .idle,sceneActive else {return}
        guard !Self.deletingRoots.contains(storageKey) else {message="点群の削除完了後に開始してください";return}
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {message="この端末では深度付き点群取得を利用できません";return}
        historical=false;overlayInWorld=true
        phase = .starting;message="記録を準備中"
        let store=store;worker.async {let result=Result{try store.create()};DispatchQueue.main.async {
            switch result {
            case .success(let id):
                self.id=id;self.poseDetector.reset();self.imuDetector.reset();self.imuInput=nil;self.usingIMU=false;self.poseEvents=[];self.motionDecisions=[];self.motionDecisionCount=0;self.motionFallbackActive=false;self.motionWarningUntil=0;self.lastMotionCheckpoint = -Double.infinity;self.setPosePulsePending(false);self.input.newDraft();self.input.setCaptureMode(self.gcpMode);self.input.beginExplicit();self.phase = .recording
                if self.sceneActive {self.message="追跡と深度を確認中。GCPは任意です。画面タップで手動追加";self.startCamera?()}
                else {self.stop(reason:"開始準備中にアプリが中断されました",closingFrame:false)}
            case .failure(let e):self.phase = .idle;self.message="開始できません: \(PCMessage.error(e))"
            }
        }}
    }
    /// Always update tracking before any queue/capture decision. Backpressure never
    /// prevents pose delivery, unlike the retired mesh recording path.
    func receive(_ snapshot:GCPFrameSnapshot,imu:[PCIMUSample]?=nil,cameraFromDevice:simd_quatd?=nil,imuStatus:String?=nil,capture:()->PCRawFrame?) {
        let arrival=ProcessInfo.processInfo.systemUptime
        // Duplicate/out-of-order/stale callbacks do not create a step or move
        // the last trusted preview pose backwards. Raw input remains untouched.
        guard snapshot.time.isFinite,snapshot.time<=arrival,arrival-snapshot.time<=0.25,
              previewTime.map({snapshot.time>$0}) ?? true else {return}
        let previousPose=previewPose,previousTime=previewTime
        let currentPose=try? GCPCaptureEvidence.pose(snapshot.matrix)
        var discontinuity=currentPose==nil
        if let previous=previewPose,let time=previewTime,let currentPose {
            let dt=snapshot.time-time,distance=simd_distance(previous.position.v,currentPose.position.v)
            let angle=2*acos(min(1,abs(simd_dot(previous.rotation.vector,currentPose.rotation.vector))))
            discontinuity=dt<=0 || dt>1 || distance>1 || distance/max(dt,0.001)>3 || angle>1 || angle/max(dt,0.001)>4
        }
        previewPose=currentPose;previewTime=snapshot.time
        guard phase == .recording else {
            if !historical,input.isRecording {
                input.receive(snapshot,referenceTranslation:{_ in self.reference})
                if snapshot.tracking != .normal || discontinuity || acceptedEpoch.map({input.epoch != $0})==true || !input.isRecording {
                    resumeBlockedReason="追跡または座標系が変化したため、この記録には追記できません"
                    overlayInWorld=false;message="追跡が失われました。保存モデル表示に切り替えました（再開不可）";stopCamera?()
                }
            }
            return
        }
        let oldRevision=input.captureRevision
        var posePulseChecked=false
        if snapshot.tracking == .normal,let currentPose {
            let result:PCPosePulseResult
            if let imu {
                if !usingIMU {poseDetector.reset();imuDetector.reset();usingIMU=true}
                var summary=imuInput ?? PCIMUInputSummary()
                summary.arFrames+=1;summary.maximumSamples=max(summary.maximumSamples,min(400,imu.count))
                if !imu.isEmpty {summary.framesWithSamples+=1}
                if cameraFromDevice != nil {summary.framesWithMapping+=1}
                summary.sensorStatus=imuStatus.map{String($0.prefix(96))}
                summary.newestSampleAge=imu.last.flatMap {let age=snapshot.time-$0.time;return age>=0 && age<=60 ? age:nil}
                imuInput=summary
                // Invalid mapping and missing samples never masquerade as a
                // zero-motion IMU. The new detector resolves them as physical
                // motion with no delta, retaining the explicit input limitation.
                result=imuDetector.ingest(time:snapshot.time,pose:currentPose,epoch:input.epoch,imu:cameraFromDevice == nil ? []:imu,cameraFromDevice:cameraFromDevice ?? simd_quatd(ix:0,iy:0,iz:0,r:1))
            } else {
                if usingIMU {imuDetector.reset();poseDetector.reset();usingIMU=false}
                result=poseDetector.ingest(time:snapshot.time,pose:currentPose,epoch:input.epoch)
            }
            switch result {
            case .warmingUp:
                setPosePulsePending(false);posePulseChecked=true
                if discontinuity {treatAsPhysicalMotion(reason:.unstableBefore,time:snapshot.time,pose:currentPose,previousTime:previousTime,previousPose:previousPose)}
            case .stable:
                setPosePulsePending(false);posePulseChecked=true;motionFallbackActive=false
            case .pending:
                if !posePulsePending {input.posePulseBoundary(at:snapshot.time);gcpFeedback="姿勢の急変候補を確認中。GCPは一時保留"}
                setPosePulsePending(true);posePulseChecked=true
            case .confirmed(let event):
                guard poseEvents.count<128 else {resumeBlockedReason="姿勢急変の記録上限のため再開できません";stop(reason:"姿勢急変の記録上限です。原入力を保持しました",closingFrame:false);return}
                poseEvents.append(event);setPosePulsePending(false);posePulseChecked=true;motionFallbackActive=false;reference=GCPVector()
                input.posePulseBoundary(at:snapshot.time);gcpFeedback="補正扱いの急変を記録。停止後に配分します（推定による判定）"
                saveGCPCheckpoint()
            case .unsafe(let reason):
                // A sparse but otherwise ordinary frame is already the default
                // physical-motion branch. A sampling gap alone is not a new
                // rapid-motion episode and must not keep resetting GCP trust.
                if reason == .intervalGap,!posePulsePending,!discontinuity {setPosePulsePending(false);posePulseChecked=true;break}
                switch reason {
                case .unstableBefore,.unstableAfter,.notImpulse,.stepTooLarge,.intervalGap,.incompletePulse:
                    // User-selected binary rule: failure of the correction
                    // model is treated as physical motion, not an unresolved
                    // interval and not evidence of an ARKit chart change.
                    treatAsPhysicalMotion(reason:reason,time:snapshot.time,pose:currentPose,previousTime:previousTime,previousPose:previousPose)
                    setPosePulsePending(false);posePulseChecked=true
                case .invalidPolicy,.invalidPose,.epochChanged,.nonMonotonicTime:
                    setPosePulsePending(false);resumeBlockedReason="有効な姿勢または同一の追跡座標系を確認できないため再開できません"
                    overlayInWorld=false;stop(reason:"追跡座標系を確認できません。原入力を保持して終了しました",closingFrame:false);stopCamera?();return
                }
            }
        } else {poseDetector.reset();imuDetector.reset();setPosePulsePending(false)}
        let pulseEpoch=input.epoch
        input.receive(snapshot,posePulseChecked:posePulseChecked,referenceTranslation:{_ in self.reference})
        if acceptedEpoch==nil,pulseEpoch != input.epoch {poseDetector.reset();imuDetector.reset();setPosePulsePending(false)}
        if let acceptedEpoch,(snapshot.tracking != .normal || input.epoch != acceptedEpoch || !input.isRecording) {
            let capacity=input.lastOutcome == .held(.capacity)
            resumeBlockedReason=capacity ? "GCP・追跡履歴の記録上限に達したため再開できません":"追跡の連続性を失ったため再開できません"
            overlayInWorld=false;stop(reason:capacity ? "GCP・追跡履歴の記録上限です。点群を保持して終了しました":"追跡の連続性を失ったため安全に終了しました",closingFrame:false);stopCamera?();return
        }
        consumeGCPResult(previousRevision:oldRevision)
        if snapshot.time<motionWarningUntil,gcpFeedback.isEmpty {gcpFeedback=motionWarning}
        if snapshot.time>=motionWarningUntil,gcpFeedback==motionWarning {
            gcpFeedback="";if message==motionWarning {message="\(savedCount) 点保存済み・空白は未取得です"}
        }
        let now=ProcessInfo.processInfo.systemUptime
        guard phase == .recording,!posePulsePending,canCaptureTrackingFrame,now>=snapshot.time,now-snapshot.time<=0.25,
              snapshot.depth != nil,waiting<1,snapshot.time>=nextAttempt else {return}
        let pose=try? GCPCaptureEvidence.pose(snapshot.matrix)
        let due=lastAuto.map {previous in
            guard let pose else {return false}
            let angle=2*acos(min(1,abs(simd_dot(pose.rotation.vector,previous.pose.rotation.vector))))
            return snapshot.time-previous.time>=0.5 && (simd_distance(pose.position.v,previous.pose.position.v)>=0.30 || angle>=Double.pi/18 || snapshot.time-previous.time>=2)
        } ?? true
        guard due else {return};nextAttempt=snapshot.time+0.5
        guard let raw=capture() else {return}
        enqueue(raw)
    }
    private func treatAsPhysicalMotion(reason:PCPosePulseUnsafe,time:Double,pose:GCPPose,previousTime:Double?=nil,previousPose:GCPPose?=nil) {
        setPosePulsePending(false)
        let newEpisode = !motionFallbackActive
        if newEpisode {motionFallbackActive=true;motionEpisodeRecorded=false}
        // Cancel only the in-progress GCP action. Retain the previous reference
        // translation because this branch assumes the AR basis did not change.
        if newEpisode {
            input.posePulseBoundary(at:time);gcpRevision+=1
            motionWarningUntil=time+3
            if gcpFeedback != motionWarning {gcpFeedback=motionWarning}
            if message != motionWarning {message=motionWarning}
        }
        // A physical episode may begin before the first saved frame. Record it
        // once the component is accepted, without repeatedly resetting GCP trust.
        guard !motionEpisodeRecorded,let acceptedEpoch,acceptedEpoch==input.epoch else {return}
        let evidence=usingIMU ? imuDetector.lastEvidence:nil
        let decision=PCPoseMotionDecision(epoch:acceptedEpoch,time:time,pose:pose,previousTime:previousTime,previousPose:previousPose,reason:reason.rawValue,policy:.motionTolerant,imuEvidence:evidence)
        guard decision.valid else {return}
        motionEpisodeRecorded=true
        motionDecisionCount=min(Int.max-1,motionDecisionCount)+1
        // Sample at most once/second, retain the total count, and never stop
        // acquisition because the diagnostic sample has filled up.
        if motionDecisions.count<(usingIMU ? 32:256),time-(motionDecisions.last?.time ?? -.infinity)>=1 {motionDecisions.append(decision)}
        if reason != .incompletePulse,time-lastMotionCheckpoint>=1 {lastMotionCheckpoint=time;saveGCPCheckpoint()}
    }
    func captureManual() {
        guard phase == .recording,!posePulsePending,waiting<1,canCaptureTrackingFrame,lastAuto != nil, var raw=captureLast?(),raw.frame.time-lastAcceptedTime>=0.25 else {return}
        raw.frame.automatic=false;enqueue(raw)
    }
    private func consumeGCPResult(previousRevision:Int) {
        if input.captureRevision != previousRevision {
            if let fit=input.latestFit,fit.rank==3 {
                if fits.last != fit {fits.append(fit)};reference=fit.translation
            }
            gcps=input.raw?.activePoints ?? [];gcpRevision+=1;saveGCPCheckpoint()
        }
        let firstID=input.pendingFirstObservation?.id
        guard displayedOutcome != input.lastOutcome || displayedFirstID != firstID || displayedDiagnostics != input.lastRayDiagnostics?.summary else {return}
        displayedDiagnostics=input.lastRayDiagnostics?.summary
        displayedOutcome=input.lastOutcome;displayedFirstID=firstID
        var text=""
        if firstID != nil,input.lastOutcome==nil {text="第一視線を記録。横へ移動し、同じ点を十字線に合わせてGCP（回転だけは不可）"}
        if let outcome=input.lastOutcome {
            switch outcome {
            case .draftRegistered(let id):text="GCP \(gcpNumber(id) ?? 0) を登録。1m以内の同一点は再観測します"
            case .draftReobserved(_,let rank):text=rank==3 ? "再観測を記録。停止後に補正できます":"方向を記録。別の位置から同じGCPを狙ってください"
            case .held(let issue):
                text="GCP待機: \(PCMessage.input(issue))"
                if gcpMode == .twoRays {
                    if let quality=input.lastRayDiagnostics {text += "\n"+quality.summary}
                    text += firstID == nil ? "。2視点を最初から取り直してください":"。第一視線は保持しています（戻すで取消）"
                }
            }
        }
        if gcpFeedback != text {gcpFeedback=text}
        if !text.isEmpty,message != text {message=text}
    }
    func recordGCP() {
        guard phase == .recording else {return}
        guard !posePulsePending else {gcpFeedback="姿勢の急変候補を確認中。GCPは未登録です";return}
        let oldRevision=input.captureRevision
        if let captureVisibleGCP {
            if let frame=captureVisibleGCP() {input.captureDisplayed(frame,referenceTranslation:{_ in self.reference})}
            else {input.displayUnavailable()}
        } else if input.request(.automatic) {message="中央の対象を観測中"}
        consumeGCPResult(previousRevision:oldRevision);gcpRevision+=1
    }
    func setGCPMode(_ mode:GCPCaptureMode) {
        guard [.idle,.recording].contains(phase),mode != .automatic,mode != gcpMode else {return}
        gcpMode=mode;input.setCaptureMode(mode);gcpRevision+=1;gcpFeedback="";displayedOutcome=nil;displayedFirstID=nil
        message=mode == .twoRays ? "2視点：同じ点を狙い、横に移動してもう一度。回転だけでは測れません":"深度の点：十字線の有効深度を記録します"
        if phase == .recording {saveGCPCheckpoint()}
    }
    func undoGCP() {
        let cancellingFirstRay=input.pendingFirstObservation != nil
        guard canUndoGCP,input.undoCapture() else {return}
        gcps=input.raw?.activePoints ?? [];gcpRevision+=1;gcpFeedback="";displayedOutcome=nil;displayedFirstID=nil
        do {
            if !cancellingFirstRay,let raw=input.raw {reference=try PCCorrection.liveReference(raw:raw,fits:fits,after:poseEvents.last?.confirmedAt)}
            message="直前のGCP操作を取り消しました。別の点を記録できます"
            saveGCPCheckpoint()
        } catch {stop(reason:"GCP取消後の補正を確認できません。原入力を保持して終了します",closingFrame:false)}
    }
    nonisolated private static func preparePreview(_ entry:PCFrameEntry,_ points:[PCVertex],state:PCWriteState)throws->(PCFrameEntry,Int,[PCVertex],PCDetailPreview?) {
        state.coverage.append(points)
        let due=entry.frame.time-state.lastCoverageTime>=1
        if due {state.lastCoverageTime=entry.frame.time}
        return (entry,points.count,due ? state.coverage.points:[],due ? try state.coverage.packed():nil)
    }
    private func enqueue(_ raw:PCRawFrame) {
        guard let id,waiting<2,raw.frame.time>lastAcceptedTime else {return}
        let bytes=Int64(raw.image.count+raw.depth.count+raw.confidence.count+raw.frame.depthWidth*raw.frame.depthHeight*15/4+65536)
        let pointBudget=((raw.frame.depthWidth-1)/2)*((raw.frame.depthHeight-1)/2)
        let limitReason:String?
        if acceptedFrames>=PCLimits.maximumFrames-2 {limitReason="この記録のフレーム数上限です"}
        else if acceptedPointBudget+pointBudget>PCLimits.maximumPoints-50_000 {limitReason="この記録の2,000万点の上限です"}
        else if acceptedBytes+bytes>=store.maximumBytes-64*1024*1024 {limitReason="この記録の5GiBの容量上限です"}
        else {limitReason=nil}
        if let limitReason {stop(reason:limitReason+"。保存済みデータを保持して終了しました",closingFrame:false);return}
        acceptedBytes+=bytes;acceptedFrames+=1;acceptedPointBudget+=pointBudget
        acceptedEpoch=raw.frame.epoch;lastAcceptedTime=raw.frame.time
        if raw.frame.automatic {lastAuto=raw.frame}
        waiting+=1
        let store=store,state=writeState
        worker.async {
            let result=Result {()->(PCFrameEntry,Int,[PCVertex],PCDetailPreview?) in
                guard !state.blocked else {throw PCFailure.interrupted}
                do {let (entry,points)=try store.append(raw,to:id);return try Self.preparePreview(entry,points,state:state)} catch {if (error as? PCFailure) != .empty {state.blocked=true};throw error}
            }
            DispatchQueue.main.async {
                self.waiting-=1
                switch result {
                case .success(let (_,count,sample,chunks)):
                    // Release the high-confidence/edge-filtered points that were
                    // conservatively reserved but never became saved vertices.
                    self.acceptedPointBudget=max(0,self.acceptedPointBudget-max(0,pointBudget-count))
                    if let chunks {self.preview=sample;self.recordingPreview=chunks}
                    self.savedCount+=count;self.previewRevision+=1
                    if self.phase == .recording,self.gcpFeedback.isEmpty {self.message="\(self.savedCount) 点保存済み・空白は未取得です"}
                case .failure(let e):
                    if (e as? PCFailure) == .empty {self.message="有効な深度がありません（未保存）"}
                    else {self.failedPayloads.append(raw);self.terminalError="入力保存に失敗: \(PCMessage.error(e))";if self.phase == .recording {self.stop(reason:self.terminalError!,closingFrame:false)}}
                }
                self.finishStopIfReady()
            }
        }
    }
    private func saveGCPCheckpoint() {
        guard let id,let raw=input.raw,phase == .recording else {return}
        if checkpointWriting {checkpointDirty=true;return}
        // Conservative reservation includes JSON/base64 overhead and leaves
        // 64 MiB for unfinished inputs and the final complete GCP snapshot.
        let reserve=Int64(raw.trajectory.count*1024+raw.observations.count*16384+fits.count*32768+poseEvents.count*262144+motionDecisions.count*262144+65536)
        guard acceptedBytes+reserve<store.maximumBytes-64*1024*1024 else {stop(reason:"記録容量の上限に達したため終了しました",closingFrame:false);return}
        acceptedBytes+=reserve;checkpointWriting=true;checkpointDirty=false
        let checkpoint=PCCheckpoint(raw:raw,fits:fits,stopped:false,reason:"収録中",continuationID:continuationID,poseEvents:poseEvents.isEmpty ? nil:poseEvents,motionDecisions:motionDecisions.isEmpty ? nil:motionDecisions,motionDecisionCount:motionDecisionCount==0 ? nil:motionDecisionCount,imuInput:imuInput),store=store
        worker.async {
            let result=Result{try store.checkpoint(checkpoint,id:id)}
            DispatchQueue.main.async {
                self.checkpointWriting=false
                if case .failure(let error)=result {self.terminalError="GCP保存に失敗: \(PCMessage.error(error))";self.stop(reason:self.terminalError!,closingFrame:false)}
                else if self.checkpointDirty {self.saveGCPCheckpoint()}
            }
        }
    }
    func stop(reason:String="停止しました",closingFrame:Bool=true) {
        guard phase == .recording else {return}
        if closingFrame,!posePulsePending,waiting<2,input.relativePoseTrusted,let raw=captureLast?(),raw.frame.time>lastAcceptedTime {enqueue(raw)}
        // The closing frame may itself reach a budget and finish stopping.
        guard phase == .recording else {return}
        if usingIMU {_ = imuDetector.finish()}
        if posePulsePending,let time=previewTime,let pose=previewPose {
            treatAsPhysicalMotion(reason:.incompletePulse,time:time,pose:pose)
        }
        guard phase == .recording else {return}
        setPosePulsePending(false);motionFallbackActive=false;_ = poseDetector.finish();imuDetector.reset()
        input.suspendCapture();gcpRevision+=1;gcpFeedback="";displayedOutcome=nil;displayedFirstID=nil
        let raw=input.raw ?? GCPRawSession()
        stopCheckpoint=PCCheckpoint(raw:raw,fits:fits,stopped:true,reason:reason,continuationID:continuationID,poseEvents:poseEvents.isEmpty ? nil:poseEvents,motionDecisions:motionDecisions.isEmpty ? nil:motionDecisions,motionDecisionCount:motionDecisionCount==0 ? nil:motionDecisionCount,imuInput:imuInput)
        phase = .saving;message=reason+"。受理済み入力を保存中"
        finishStopIfReady()
    }
    private func finishStopIfReady() {
        guard phase == .saving,waiting==0,let checkpoint=stopCheckpoint,let id else {return}
        guard failedPayloads.isEmpty else {phase = .failed;message=terminalError ?? "保存失敗。原入力を保持しています";return}
        // Keep checkpoint in memory until fsync + reload succeeds. No close on failure.
        phase = .processing;let store=store,control=PCWorkControl(seconds:900);self.control=control
        worker.async {let result=Result {try control.check();try store.checkpoint(checkpoint,id:id);return try store.load(id,work:control)}
            DispatchQueue.main.async {self.control=nil;switch result {
            case .success(let record):self.record=record;self.stopCheckpoint=nil;self.phase = .review;self.message=checkpoint.reason+"。アプリ内に保存済み（PLY出力は任意）";self.endBackgroundTask();self.loadStoppedPreview(record)
            case .failure(let e):self.phase = .failed;self.message="保存の最終確認を完了できません: \(PCMessage.error(e))。原入力を保持しています。再試行できます"
            }}
        }
    }
    func retrySave() {
        guard phase == .failed else {return}
        // Inspect uncertain results first, then complete only matching pending bytes.
        // Neither a new frame identity nor replacement of existing bytes is used.
        phase = .saving
        if let payload=failedPayloads.first,let id {
            waiting+=1;let store=store
            worker.async {let result=Result {()->(PCFrameEntry,Int,[PCVertex],PCDetailPreview?) in
                let record=try store.load(id)
                let state=self.writeState
                if let existing=record.frames.first(where:{$0.id==payload.frame.id}) {return try Self.preparePreview(existing,store.points(existing,id:id),state:state)}
                let (entry,points)=try store.append(payload,to:id);return try Self.preparePreview(entry,points,state:state)
            };DispatchQueue.main.async {
                self.waiting-=1
                switch result {
                case .success(let (_,count,sample,chunks)):
                    let reserved=((payload.frame.depthWidth-1)/2)*((payload.frame.depthHeight-1)/2)
                    self.acceptedPointBudget=max(0,self.acceptedPointBudget-max(0,reserved-count))
                    self.failedPayloads.removeFirst();if let chunks {self.preview=sample;self.recordingPreview=chunks}
                    self.savedCount+=count;self.previewRevision+=1
                case .failure(let e):self.phase = .failed;self.message="保存再試行: \(PCMessage.error(e))"
                };if !self.failedPayloads.isEmpty,self.phase == .saving {self.phase = .failed;self.retrySave()} else {self.finishStopIfReady()}
            }}
        } else {finishStopIfReady()}
    }
    /// Display I/O failure never invalidates the saved record or disables raw PLY.
    private func loadStoppedPreview(_ record:PCRecord) {
        previewNotice=nil
        let store=store,control=PCWorkControl(seconds:900);self.control=control;detailLoading=true;phase = .processing;progress=0;message="保存済み全点を読み込み中"
        worker.async {let result=Result {try PCPreviewPacking.load(store:store,record:record,offsets:[:],control:control,progress:{p in DispatchQueue.main.async{self.progress=p}})}
            DispatchQueue.main.async {
                self.control=nil;self.detailLoading=false;self.phase = .review
                switch result {
                case .success(let detail):self.detailPreview=detail;self.previewRevision+=1;self.message=detail.isPartial ? "アプリ内に全点保存済み。200万点ずつ切り替えて表示します。PLYは全点です":"アプリ内に保存済み・全 \(detail.count) 点を表示。PLY出力は任意です"
                case .failure(let e):self.message="全点表示は未完了: \(PCMessage.error(e))。原入力は保持。生データPLYは出力できます";self.previewNotice=self.message
                }
            }
        }
    }
    var previewPageDescription:String? {
        guard let detail=detailPreview,detail.isPartial else {return nil}
        return "表示 \(detail.count)／保存 \(detail.totalCount ?? savedCount) 点・\(detail.page+1)/\(detail.pageCount)（分割表示・PLYは全点）"
    }
    func changePreviewPage(_ delta:Int) {
        guard [.review,.ready].contains(phase),!controlNeedsReload,let record,let detail=detailPreview else {return}
        let page=detail.page+delta;guard page>=0,page<detail.pageCount else {return}
        let previousPhase=phase,store=store,solution=coordinateSolution,displayCorrected=corrected,control=PCWorkControl(seconds:900)
        self.control=control;phase = .processing;detailLoading=true;progress=0
        worker.async {
            let result=Result {try PCPreviewPacking.load(store:store,record:record,offsets:solution != nil ? PCControlMath.selectedOffsets(record,solution:solution):(displayCorrected ? PCCorrection.checkedSelection(record):[:]),transform:solution?.transform,poseCorrected:solution != nil || displayCorrected,page:page,control:control,progress:{p in DispatchQueue.main.async{self.progress=p}})}
            DispatchQueue.main.async {
                self.control=nil;self.detailLoading=false;self.phase=previousPhase
                switch result {
                case .success(let value):self.detailPreview=value;self.previewRevision+=1;self.previewNotice=nil
                case .failure(let error):self.previewNotice="表示範囲を変更できません: \(PCMessage.error(error))。保存点は保持しています"
                }
            }
        }
    }
    func retryPreview() {
        guard !controlNeedsReload else{return}
        guard phase == .review,let record else {return}
        // Return to raw display before reloading; persisted correction stays intact.
        corrected=false;coordinateSolution=nil;coordinateMarkers=[];detailPreview=nil;previewRevision+=1;loadStoppedPreview(record)
    }
    func choose(correct:Bool) {
        guard !controlNeedsReload else{return}
        guard phase == .review || phase == .ready,let id else {return}
        previewNotice=nil
        let existing=detailPreview,wasCorrected=corrected,hadCoordinates=coordinateSolution != nil
        phase = .processing;message=correct ? "原観測から補正計算中":"保存済み生データを表示（GCP不要）";let store=store,control=PCWorkControl(seconds:900);self.control=control
        worker.async {let result=Result {()->(PCRecord,PCDetailPreview?,[SIMD3<Float>?]) in
            var record=try store.load(id,work:control);try control.check()
            let offsets=correct ? try PCCorrection.offsets(record:record):[:]
            // Raw export must remain available even if detailed rendering failed.
            let detail:PCDetailPreview?
            if wasCorrected==correct,!hadCoordinates {detail=existing}
            else {detail=try PCPreviewPacking.load(store:store,record:record,offsets:offsets,poseCorrected:correct,control:control)}
            try control.check()
            // Explicitly choosing local raw/drift output cancels the coordinate
            // application through another event; all correspondence history stays.
            if let previous=record.control,previous.applied {
                let cleared=PCControlState(proposal:previous.proposal,solution:nil,applied:false,continuationID:record.checkpoint?.continuationID)
                try store.saveControl(cleared,id:id);record.control=cleared
            }
            let selection=PCSelection(corrected:correct,offsets:offsets,continuationID:record.checkpoint?.continuationID);try store.select(selection,id:id);record.selection=selection
            let markers=correct ? PCCorrection.markers(record):[]
            return (record,detail,markers)
        };DispatchQueue.main.async {self.control=nil;switch result {
        case .success(let (record,detail,markers)):self.record=record;self.coordinateMarkers=markers;self.corrected=correct;self.coordinateSolution=nil;if correct,record.checkpoint?.poseEvents?.isEmpty==false {self.modelViewRequested=true};self.detailPreview=detail;self.previewRevision+=1;self.phase = .ready
            self.message=correct ? ((record.checkpoint?.poseEvents?.isEmpty==false) ? "推定急変を配分済み・有効なGCPで再計算（推定・精度未検証）":"平行移動補正済み（回転は固定・精度未検証）"):"未補正の生データはアプリ内保存済み。閉じても後で閲覧できます（PLYは任意）"
            if detail==nil,self.savedCount>0 {self.previewNotice="全点表示は未完了です。原入力は保持し、PLYは保存点を出力します"}
        case .failure(let e):
            // A failed second journal write may follow a successful cancellation
            // event. Never keep displaying an applied transform from stale UI state.
            if hadCoordinates {self.coordinateSolution=nil;self.detailPreview=nil;self.previewRevision+=1;self.corrected=false;self.modelViewRequested=true}
            self.phase = .review
            let explanation: String
            if (e as? PCFailure) == .correctionUnavailable,self.record?.checkpoint?.poseEvents?.isEmpty != false,self.record?.checkpoint?.fits.isEmpty != false {
                explanation="補正用の姿勢変化またはGCP再観測が採用されていません"
            } else {explanation=PCMessage.error(e)}
            self.message="補正できません: \(explanation)。原データはアプリ内に保存済みです"
            self.previewNotice=self.message
        }}}
    }
    var canCancel:Bool {control != nil}
    func cancelWork(){control?.cancel()}
    func backToChoice(){guard phase == .ready,!controlNeedsReload else {return};phase = .review}
    func open(_ selected:UUID) {
        guard !Self.deletingRoots.contains(storageKey) else {message="点群の削除完了後に開いてください";return}
        guard phase == .idle else {return};previewNotice=nil;phase = .processing;message="保存済み全点を読み込み中";historical=true;overlayInWorld=false;detailLoading=true
        let store=store,control=PCWorkControl(seconds:900);self.control=control
        worker.async {let result=Result {()->(PCRecord,PCDetailPreview,PCControlSolution?,[SIMD3<Float>?]) in
            var record=try store.load(selected,work:control)
            let solution=try? PCControlMath.active(record)
            let offsets=try PCControlMath.selectedOffsets(record,solution:solution)
            if record.control?.applied==true,solution==nil {record.warnings.append("座標対応は要再計算。ローカル座標で表示しています")}
            let detail=try PCPreviewPacking.load(store:store,record:record,offsets:offsets,transform:solution?.transform,poseCorrected:solution != nil || record.selection?.corrected==true,control:control,progress:{p in DispatchQueue.main.async{self.progress=p}})
            let markers=solution.map{PCControlMath.markers(record:record,solution:$0)} ?? (record.selection?.corrected==true ? PCCorrection.markers(record):[])
            if markers.contains(where:{$0==nil}) {record.warnings.append("一部GCPは内部補正区間外のため位置を表示できません")}
            return(record,detail,solution,markers)
        };DispatchQueue.main.async {self.control=nil;self.detailLoading=false;switch result {
        case .success(let (record,detail,solution,markers)):
            self.controlNeedsReload=false;self.id=selected;self.record=record;self.coordinateSolution=solution;self.coordinateMarkers=markers;self.detailPreview=detail;self.previewRevision+=1;self.savedCount=record.frames.reduce(0){$0+$1.pointCount};self.gcps=record.checkpoint?.raw.activePoints ?? [];self.corrected=record.selection?.corrected ?? false;self.phase = .ready // Browsing defaults to raw without writing a new selection/event.
            self.message="保存時座標の全点モデル表示（現実位置には未整合）。"+record.warnings.joined(separator:" / ")
        case .failure(let e):self.phase = .idle;self.message="記録を開けません: \(PCMessage.error(e))"
        }}}
    }
    func reloadControlAfterFailure() {
        guard phase == .ready,controlNeedsReload,let id else{return}
        phase = .idle;open(id)
    }
    func evaluateControl(_ proposal:PCControlProposal,completion:@escaping(Result<PCControlSolution,Error>)->Void) {
        guard phase == .ready,!controlNeedsReload,let id else {return}
        phase = .processing;message=proposal.isLocalClosure ? "同一点の相対補正を計算中":"GCPと座標点の対応を計算中";let store=store,control=PCWorkControl(seconds:900);self.control=control
        worker.async {let result=Result {try control.check();let fit=try PCControlMath.fit(record:store.load(id,work:control),proposal:proposal,work:control);try control.check();return fit}
            DispatchQueue.main.async {self.control=nil;self.phase = .ready;completion(result)}
        }
    }
    func saveControl(_ proposal:PCControlProposal,solution:PCControlSolution?,apply:Bool,qualityOverride:Bool=false,completion:@escaping(Bool)->Void={_ in}) {
        guard phase == .ready,!controlNeedsReload,let id else {return}
        previewNotice=nil
        phase = .processing;message=apply ? "対応表・変換・残差を保存中":"対応表を保存しローカル表示へ戻しています"
        let store=store,control=PCWorkControl(seconds:900);self.control=control
        worker.async {let result=Result {()->(PCRecord,PCDetailPreview,PCControlSolution?,[SIMD3<Float>?]) in
            var record=try store.load(id,work:control);try control.check()
            if apply {guard let solution,try PCControlMath.fit(record:record,proposal:proposal,work:control)==solution,solution.canApply(qualityOverride:qualityOverride) else {throw PCControlFailure.invalid}}
            var state=PCControlState(proposal:proposal,solution:solution,applied:apply,continuationID:record.checkpoint?.continuationID)
            state.qualityOverride = apply && qualityOverride ? true:nil
            let active=apply ? solution:nil
            let offsets=try PCControlMath.selectedOffsets(record,solution:active)
            let detail=try PCPreviewPacking.load(store:store,record:record,offsets:offsets,transform:active?.transform,poseCorrected:active != nil || record.selection?.corrected==true,control:control)
            let markers=active.map{PCControlMath.markers(record:record,solution:$0)} ?? (record.selection?.corrected==true ? PCCorrection.markers(record):[])
            if markers.contains(where:{$0==nil}) {record.warnings.append("一部GCPは内部補正区間外のため位置を表示できません")}
            try control.check();try store.saveControl(state,id:id);record.control=state
            return(record,detail,active,markers)
        };DispatchQueue.main.async {self.control=nil;self.phase = .ready;switch result {
        case .success(let (record,detail,active,markers)):
            self.record=record;self.coordinateSolution=active;self.coordinateMarkers=markers;self.detailPreview=detail;self.previewRevision+=1
            self.modelViewRequested=true
            self.message=apply ? (active?.frameCorrection?.localOnly==true ? "同一点の相対補正を適用しました。ローカルの保存モデル表示です":"座標対応を適用しました。保存モデル表示（現実位置とのAR照合ではありません）"):"対応表を保存しました。原点群・内部補正・過去の対応は保持しています"
            completion(true)
        case .failure(let error):
            // A .writing journal may already be durable. Do not keep rendering
            // an older transform as if the new intent were known to have failed.
            self.controlNeedsReload=true;self.coordinateSolution=nil;self.detailPreview=nil;self.coordinateMarkers=[]
            self.previewRevision+=1;self.modelViewRequested=true
            self.message="対応の保存結果を再読込してください: \(error.localizedDescription)。原記録は保持しています"
            self.previewNotice=self.message
            completion(false)
        }}}
    }
    func export(to folder:URL,knownCoordinates:Bool=false) {
        guard canExport,!controlNeedsReload,let id else {return};previewNotice=nil;phase = .exporting;progress=0;message="PLYを生成中";let store=store,corrected=corrected,control=PCWorkControl(seconds:900);self.control=control
        let scoped=folder.startAccessingSecurityScopedResource()
        worker.async {
            defer {if scoped {folder.stopAccessingSecurityScopedResource()}}
            let result=Result {()->URL in
                let output:URL
                if knownCoordinates {output=try PCControlPLY.export(store:store,id:id,folder:store.directory(id).appendingPathComponent("Exports"),control:control,progress:{p in DispatchQueue.main.async{self.progress=p*0.8}})}
                else {output=try PCPly.export(store:store,id:id,folder:store.directory(id).appendingPathComponent("Exports"),corrected:corrected,control:control,progress:{p in DispatchQueue.main.async {self.progress=p*0.8}})}
                try control.check();DispatchQueue.main.async {self.message="選択フォルダへ保存中（保存先の応答待ち）"}
                let target=folder.appendingPathComponent(output.lastPathComponent)
                var coordinationError:NSError?,copyError:Error?;var delivered=false
                let coordinator=NSFileCoordinator();control.onCancel {coordinator.cancel()}
                coordinator.coordinate(writingItemAt:target,options:[],error:&coordinationError) {url in
                    do {try control.check();guard !FileManager.default.fileExists(atPath:url.path) else {throw PCFailure.corrupt};try PCPly.deliver(output,to:url,control:control);delivered=true}catch{copyError=error}
                }
                if let e=coordinationError {throw e};if let e=copyError {throw e}
                try control.check();guard delivered else {throw PCFailure.interrupted}
                return target
            }
            DispatchQueue.main.async {self.control=nil;self.phase = .ready;switch result {case .success(let url):self.progress=1;self.message="PLY保存完了: "+url.lastPathComponent;case .failure(let e):self.message="PLY保存未完了: \(PCMessage.error(e))。原記録と生成済みファイルは保持しています"};self.previewNotice=self.message}
        }
    }
    func cameraSessionChanged(_ token:UUID,now:Double=ProcessInfo.processInfo.systemUptime) {
        guard cameraSessionID != token else {return};cameraSessionID=token
        input.sessionReset(token,now:now)
        guard acceptedEpoch != nil else {return}
        resumeBlockedReason="ARセッションが変わったため、この記録には追記できません"
        overlayInWorld=false
        if phase == .recording {stop(reason:resumeBlockedReason!,closingFrame:false)}
        stopCamera?()
    }
    func cameraTrackingChanged(_ state:GCPTracking) {
        guard !historical,input.isRecording else {return}
        input.trackingChanged(state)
        guard state != .normal,acceptedEpoch != nil else {return}
        resumeBlockedReason="追跡状態が変化したため、この記録への再開はできません"
        overlayInWorld=false
        if phase == .recording {stop(reason:resumeBlockedReason!,closingFrame:false)}
        stopCamera?()
    }
    func becameActive(){sceneActive=true} // User must explicitly request a safe continuation.
    func interrupted() {
        sceneActive=false;resumeBlockedReason="アプリまたはARセッションが中断されたため再開できません"
        if phase == .recording || phase == .saving || stopCheckpoint != nil {
            if backgroundTask == .invalid {backgroundTask=UIApplication.shared.beginBackgroundTask(withName:"Point cloud save") {Task{@MainActor in self.message="バックグラウンド時間終了。未完了記録は次回読み取りで確認します";self.endBackgroundTask()}}}
            stop(reason:"アプリ中断により終了しました",closingFrame:false)
        }
        overlayInWorld=false;stopCamera?()
    }
    private func endBackgroundTask(){if backgroundTask != .invalid {UIApplication.shared.endBackgroundTask(backgroundTask);backgroundTask = .invalid}}
}
