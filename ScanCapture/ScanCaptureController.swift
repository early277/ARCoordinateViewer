import Foundation
import Combine
import CoreVideo

@MainActor final class ScanCaptureController:ObservableObject {
    let input=GCPInputSession()
    let limits:ScanLimits
    private let archive:ScanArchive
    private let worker=DispatchQueue(label:"ARCoordinateViewer.scan-save",qos:.utility)
    private let encode:(CVPixelBuffer,ScanLimits)throws->Data
    @Published var showCoverage=true
    @Published private(set) var preview:ScanPreviewState?
    @Published private(set) var previewIssue:String?
    private var previewAllowedEpoch:GCPEpoch?
    @Published var modeOpen=false {didSet {if modeOpen != oldValue {changed()}}}
    @Published private(set) var message="未収録・開始するとメッシュと画像を端末内に保存"
    @Published private(set) var savedPackets=0
    @Published private(set) var savedImages=0
    @Published private(set) var savedPoints=0
    @Published private(set) var previewFailures=0
    @Published private(set) var normalWarnings=0
    @Published private(set) var savedFrameTime:Double?
    @Published private(set) var available:[UUID]=[]
    @Published private(set) var preparing=false
    @Published var gcpIntent:GCPCaptureIntent = .automatic
    @Published private(set) var exportStage=""
    @Published private(set) var exportFraction=0.0
    @Published private(set) var exportStarted:Date?
    private var exportControl:ScanExportControl?
    private var exportToken:UUID?
    private var stoppedFit:GCPTranslationFit?
    @Published private(set) var error:String?
    @Published private(set) var revision=0
    @Published private(set) var correctionChanges=0
    @Published private(set) var lastExportURL:URL?
    @Published private(set) var filesRequest:ScanFilesRequest?
    private var cachedPackage:(source:URL,url:URL)?
    private var corrections:ScanCorrectionState?
    private var terminalEvent:ScanEvent?
    private var selectedRecordID:UUID?
    private var lastPacketTime=0.0
    var onChange:(()->Void)?
    private var jobs:[Job]=[]
    private var writing=false
    private var sequence=0
    private var imageCount=0
    private var savedBytes=0
    private var segment=UUID()
    private var segmentStart=0.0
    private var segmentEpoch:GCPEpoch?
    private var tracker=ScanMeshTracker()
    private var lastCapture = -Double.infinity
    private var lastNativeAttempt = -Double.infinity
    private var lastReceivedTime:Double?
    private var lastCounts:[Int]=[]
    private var retried=false
    private var terminal=false
    private var recoveryBlocked=false
    private var sessionID:UUID?
    private var stoppedMessage:String?
    private var waitingForSave=false
    // Each job owns an immutable packet and a private copied image; worker reads only.
    private struct Job:@unchecked Sendable {var packet:ScanPacket;var image:CVPixelBuffer?;var estimate:Int}
    init(root:URL=ScanArchive.suggestedRoot,limits:ScanLimits=ScanLimits(),freeBytes:(()->Int64)?=nil,encode:@escaping(CVPixelBuffer,ScanLimits)throws->Data=ScanImageCodec.jpeg) {
        self.limits=limits;archive=ScanArchive(root:root,limits:limits,freeBytes:freeBytes);self.encode=encode
    }
    var isRecording:Bool {input.isRecording}
    var previewVisible:Bool {modeOpen && input.epoch==previewAllowedEpoch && input.tracking == .normal}
    func reportPreviewRenderFailure(_ token:UUID) {guard preview?.token==token else {return};previewIssue="形状の描画を保留・原本は保存済み"}
    func invalidatePreview() {resetPreview()}
    private func resetPreview() {preview=nil;previewAllowedEpoch=nil;previewIssue=nil}
    private func startPreviewContext() {
        preview=ScanPreviewState(token:UUID(),epoch:input.epoch,segmentID:segment)
        previewAllowedEpoch=input.epoch;previewIssue=nil
    }
    /// Called for every AR frame and session change, also while stopped.
    func synchronizePreviewContext() {
        if preview != nil,(input.epoch != previewAllowedEpoch || input.tracking != .normal) {resetPreview()}
    }
    var isSaving:Bool {writing || !jobs.isEmpty}
    var pendingCount:Int {jobs.count}
    var canFinish:Bool {sessionID != nil && !terminal && !preparing && !isSaving && error==nil && !recoveryBlocked && filesRequest==nil}
    var canStart:Bool {!isRecording && !preparing && !isSaving && error==nil && !recoveryBlocked && !terminal && filesRequest==nil}
    private func changed() {revision &+= 1;onChange?()}
    func discover() {
        guard !preparing else {return};preparing=true
        let archive=self.archive
        worker.async {let result=Result {try archive.discover()};Task {@MainActor in
            self.preparing=false
            switch result {case .success(let ids):self.available=ids;case .failure(let e):self.error=ScanErrorMessage.text(e);self.message="保存記録の確認に失敗"}
            self.changed()
        }}
    }
    /// Loading never starts recording, configures AR, photographs, or discards pending files.
    func restore(_ id:UUID) {
        guard !isRecording,!isSaving,!preparing,filesRequest==nil else {return};selectedRecordID=id;preparing=true;lastExportURL=nil;cachedPackage=nil;resetPreview()
        let archive=self.archive
        worker.async {let result=Result {try archive.recover(id,promoteCompletePending:true)};Task {@MainActor in
            self.preparing=false
            switch result {
            case .success(let recovered):
                guard let last=recovered.last else {self.recoveryBlocked=true;self.error="復旧できる確定記録がありません。途中ファイルは保持しています";self.changed();return}
                self.input.restoreDraft(last.raw);self.stoppedFit=last.proposedFit;self.sessionID=id
                self.corrections=last.corrections ?? ScanCorrection.empty(id);self.correctionChanges=self.corrections?.journal.changes.count ?? 0
                self.segment=last.segmentID;self.segmentStart=last.segmentStart;self.segmentEpoch=last.epoch;self.lastPacketTime=last.time
                self.terminalEvent=last.terminalEvent ?? ([ScanEvent.ended,.cancelled].contains(last.event) ? last.event:nil)
                self.sequence=recovered.packets;self.savedPackets=recovered.packets
                self.previewFailures=recovered.previewFailures;self.normalWarnings=recovered.normalWarnings;self.savedPoints=last.raw.points.count;self.savedBytes=recovered.bytes;self.savedImages=recovered.images;self.imageCount=recovered.images;self.savedFrameTime=last.frame?.time
                self.terminal=self.terminalEvent != nil
                self.recoveryBlocked = !recovered.issues.isEmpty
                self.error=recovered.issues.isEmpty ? nil:recovered.issues.joined(separator:"\n")
                self.stoppedMessage=last.reason.map {String($0.components(separatedBy:" [")[0])+"・停止中（原本を保持）"}
                self.message=self.terminal ? "終了済み記録・原本を保持" : (self.recoveryBlocked ? "保存途中ファイルを保持・確認が必要" : (self.stoppedMessage ?? "復旧済み・再開は新しい区間（自動結合なし）"))
                if last.recoverySource?.retainedIssues.isEmpty==false {self.message+="（確定部分のコピー・元の途中ファイルは保持）"}
            case .failure(let e):self.recoveryBlocked=true;self.error=ScanErrorMessage.text(e);self.message="復旧に失敗・ファイルは保持"
            }
            self.changed()
        }}
    }
    func newRecording() {
        guard !isRecording,!isSaving,!preparing,filesRequest==nil else {return}
        resetPreview();stoppedFit=nil;input.newDraft();sessionID=nil;sequence=0;savedBytes=0;previewFailures=0;normalWarnings=0;savedPackets=0;savedImages=0;savedPoints=0;imageCount=0;savedFrameTime=nil
        terminal=false;terminalEvent=nil;corrections=nil;correctionChanges=0;lastExportURL=nil;cachedPackage=nil;selectedRecordID=nil;lastPacketTime=0;recoveryBlocked=false;retried=false;error=nil;stoppedMessage=nil;waitingForSave=false;message="未収録・保存済みの記録は保持";changed()
    }
    func beginExplicit(now:Double=ProcessInfo.processInfo.systemUptime) {
        guard canStart else {return}
        stoppedFit=nil;input.beginExplicit(now:now);guard input.isRecording,let raw=input.raw else {message="上限のため再開できません";changed();return}
        sessionID=raw.id;selectedRecordID=raw.id;lastExportURL=nil;cachedPackage=nil;if corrections==nil {corrections=ScanCorrection.empty(raw.id)};segment=UUID();segmentStart=now;segmentEpoch=input.epoch;tracker.reset();lastCapture = -.infinity;lastNativeAttempt = -.infinity;lastReceivedTime=nil
        startPreviewContext();lastPacketTime=now;stoppedMessage=nil;waitingForSave=false;message="収録中・原本を順次保存";enqueue(event:.began,time:now);changed()
    }
    func captureGCP(_ intent:GCPCaptureIntent,now:Double=ProcessInfo.processInfo.systemUptime) {guard isRecording else {return};_ = input.request(intent,now:now);changed()}
    /// End/cancel both retain originals. Cancel means stop collection, never delete.
    func stop(_ event:ScanEvent = .paused,reason:String="中断",now:Double=ProcessInfo.processInfo.systemUptime) {
        guard sessionID != nil,!terminal else {return}
        let active=input.isRecording
        let previousEpoch=input.epoch
        if active {stoppedFit=input.latestFit}
        input.pause(now:now)
        // Only our own pause barrier keeps the exact existing world mapping.
        if previewAllowedEpoch==previousEpoch {previewAllowedEpoch=input.epoch}
        guard active || event == .ended || event == .cancelled || jobs.last?.packet.event == .capture || jobs.last?.packet.event == .began else {return}
        terminal=event == .ended || event == .cancelled;if terminal {terminalEvent=event}
        enqueue(event:event,time:max(segmentStart,now),reason:reason)
        stoppedMessage=event == .ended || event == .cancelled ? nil:reason+"・停止中（原本を保持）"
        message=event == .ended ? "終了・保存完了を待っています" : event == .cancelled ? "中止・取得済み原本を保存します" : reason+"・停止して原本を保存します"
        changed()
    }
    func receive(_ frame:GCPFrameSnapshot,now:Double=ProcessInfo.processInfo.systemUptime,capture:()throws->ScanNativePayload) {
        guard isRecording,error==nil else {return}
        guard frame.time.isFinite,now.isFinite,now>=frame.time,now-frame.time<=0.25,lastReceivedTime.map({frame.time>$0}) ?? true else {input.cancelRequest(reason:.staleFrame);return}
        // Backpressure precedes accepting raw observations or copying camera buffers.
        // Accepted jobs stay bounded; a slow save alone does not terminate collection.
        guard jobs.count<limits.maximumPendingFrames,jobs.reduce(0,{$0+$1.estimate})<limits.maximumPendingBytes else {
            // Preserve loss-of-tracking boundaries even while no samples are accepted.
            if frame.tracking != .normal {input.trackingChanged(frame.tracking,now:frame.time)}
            input.cancelRequest(reason:.busy)
            if !waitingForSave {waitingForSave=true;message="保存待ち・新しい入力を保留。保存後に自動復帰";changed()}
            return
        }
        if waitingForSave {waitingForSave=false;message="収録中・原本を順次保存";changed()}
        // Reserve a worst-case packet AND a raw-only stop checkpoint before accepting another frame.
        let queuedBytes=jobs.reduce(0,{$0+$1.estimate})
        let stopReserve=16*1024*1024
        guard savedBytes+queuedBytes<=limits.maximumSessionBytes-limits.maximumPacketBytes-stopReserve else {stop(reason:"保存容量上限",now:now);return}
        lastReceivedTime=frame.time
        input.receive(frame,now:now) {observation in
            guard let state=self.corrections,let raw=self.input.raw else {return GCPVector()}
            return try ScanCorrection.offset(state,raw:raw,segmentID:self.segment,epoch:observation.epoch,time:observation.time)
        }
        if !input.isRecording {enqueue(event:.paused,time:max(segmentStart,now),reason:"観測上限・追跡状態");message="入力停止・原本を保存します";changed();return}
        if segmentEpoch != input.epoch {segment=UUID();segmentStart=frame.time;segmentEpoch=input.epoch;tracker.reset();lastCapture = -.infinity;lastNativeAttempt = -.infinity;startPreviewContext()}
        if preview==nil,input.tracking == .normal {tracker.reset();lastCapture = -.infinity;lastNativeAttempt = -.infinity;startPreviewContext()}
        let counts=input.raw.map {[$0.observations.count,$0.points.count,$0.trajectory.count]} ?? []
        let keyframe=frame.tracking == .normal && input.relativePoseTrusted && frame.time-lastCapture>=limits.interval && frame.time-lastNativeAttempt>=limits.interval
        do {
            if keyframe {
                guard imageCount<limits.maximumImages else {stop(reason:"画像枚数上限",now:now);return}
                lastNativeAttempt=frame.time
                let native=try capture()
                var candidate=tracker
                let changes=try candidate.changes(native.meshes,time:frame.time,start:segmentStart,limits:limits)
                var info=ScanFrameInfo(frame);info.imageInfo=ScanImageCodec.describe(native.image)
                if enqueue(event:.capture,time:frame.time,frame:info,meshes:changes,image:native.image,depthMap:native.depthMap) {tracker=candidate;lastCapture=frame.time;imageCount+=1;message="収録中・原本を順次保存"}
            } else if counts != lastCounts {enqueue(event:.capture,time:frame.time,frame:ScanFrameInfo(frame))}
            changed()
        } catch ScanMeshInputIssue.notReady(let detail) {
            if counts != lastCounts {_=enqueue(event:.capture,time:frame.time,reason:ScanMeshInputIssue.notReady(detail).diagnostic,frame:ScanFrameInfo(frame))}
            if isRecording,error==nil {message="メッシュ準備待ち・画像未収録。ゆっくり周囲へ向けてください";changed()}
        } catch let issue as ScanMeshInputIssue {
            stop(reason:"入力保留: "+issue.diagnostic,now:now)
            stoppedMessage="入力保留: "+issue.message+"・収録停止、原本は保持"
            message=stoppedMessage!;changed()
        } catch {stop(reason:"入力保留: "+ScanErrorMessage.text(error),now:now)}
    }
    @discardableResult private func enqueue(event:ScanEvent,time:Double,reason:String?=nil,frame:ScanFrameInfo?=nil,meshes:[ScanMeshChange]=[],image:CVPixelBuffer?=nil,depthMap:ScanDepthMap?=nil)->Bool {
        guard let raw=input.raw,let id=sessionID else {return false}
        let estimate=(depthMap.map {($0.cameraZBits.count+$0.confidence.count)*2} ?? 0)+(image.map {CVPixelBufferGetDataSize($0)+limits.maximumImageBytes} ?? 0)+meshes.reduce(0,{$0+($1.mesh.map {$0.vertices.count+$0.normals.count+$0.indices.count} ?? 0)})*2+raw.observations.count*8192+raw.trajectory.count*1024+((try? JSONEncoder().encode(corrections).count) ?? 0)+8192
        let controls=event != .capture
        guard (controls && jobs.count<=limits.maximumPendingFrames) || (!controls && jobs.count<limits.maximumPendingFrames && estimate<=limits.maximumPacketBytes && jobs.reduce(0,{$0+$1.estimate})<=limits.maximumPendingBytes-estimate) else {
            input.pause(now:time)
            if !controls {
                _=enqueue(event:.paused,time:max(segmentStart,time),reason:"保存待ち容量の上限")
                message="保存待ち容量の上限・停止して原観測を保存します"
            } else {message="保存キュー上限・未保存の観測をメモリに保持";error="保存キュー上限。収録を停止しました"}
            changed();return false
        }
        sequence+=1
        var packet=ScanPacket(sessionID:id,sequence:sequence,segmentID:segment,segmentStart:segmentStart,epoch:segmentEpoch ?? input.epoch,event:event,reason:reason,time:time,frame:frame,meshes:meshes,raw:raw,hasImage:image != nil)
        packet.depthMap=depthMap;packet.depthIssue=image != nil && depthMap==nil ? "Full same-frame sceneDepth/confidence unavailable; texture visibility unknown":nil
        packet.corrections=corrections;packet.proposedFit=input.latestFit ?? stoppedFit;packet.terminalEvent=terminalEvent
        lastPacketTime=max(lastPacketTime,time)
        jobs.append(Job(packet:packet,image:image,estimate:estimate));lastCounts=[raw.observations.count,raw.points.count,raw.trajectory.count]
        pump();return true
    }
    private func pump() {
        guard !writing,error==nil,let job=jobs.first else {return};writing=true
        let archive=self.archive,encode=self.encode,limits=self.limits,previewSeed=self.preview
        worker.async {
            let result=Result { () throws -> (Int,String?,ScanPreviewState?,String?) in
                let original=try job.image.map {try ScanImageCodec.original($0,limits:limits)}
                var packet=job.packet,jpeg:Data?
                if let image=job.image {do {jpeg=try encode(image,limits)} catch {packet.previewIssue=ScanErrorMessage.text(error)}}
                let bytes=try archive.append(packet,jpeg:jpeg,original:original)
                var display=previewSeed,displayIssue:String?
                do {try display?.accept(packet)} catch {display=nil;displayIssue="保存済み形状の表示を保留・原本は保存済み"}
                return (bytes,packet.previewIssue,display,displayIssue)
            }
            Task {@MainActor in
                self.writing=false
                switch result {
                case .success(let (bytes,previewIssue,display,displayIssue)):
                    if self.preview?.token==previewSeed?.token,self.previewAllowedEpoch==self.input.epoch {
                        if let display {self.preview=display}
                        self.previewIssue=displayIssue
                    }
                    self.savedBytes+=bytes
                    if previewIssue != nil {self.previewFailures+=1}
                    self.normalWarnings+=job.packet.meshes.filter {$0.mesh?.normalStatus != nil}.count
                    self.jobs.removeFirst();self.savedPackets=job.packet.sequence;self.savedPoints=job.packet.raw.points.count
                    if job.packet.hasImage {self.savedImages+=1};if let frame=job.packet.frame {self.savedFrameTime=frame.time}
                    if self.jobs.isEmpty,!self.isRecording {self.message=self.retried ? "保存完了・過去の途中ファイルも保持（再起動時に検査）" : (self.terminal ? "保存完了・終了済み原本を保持" : (self.stoppedMessage.map {$0+"（保存完了）"} ?? "保存完了・停止中（再開は新しい区間）"))}
                    self.pump()
                case .failure(let e):
                    self.error=ScanErrorMessage.text(e);self.input.pause();self.message="保存失敗・収録停止。原本と保存待ちを保持"
                }
                self.changed()
            }
        }
    }
    private var correctionFit:GCPTranslationFit? {isRecording ? input.latestFit:stoppedFit}
    var canApplyCorrection:Bool {!isSaving && !preparing && !recoveryBlocked && filesRequest==nil && error==nil && correctionFit?.rank==3 && correctionFit?.context.epoch==segmentEpoch}
    var canUndoCorrection:Bool {!isSaving && !preparing && !recoveryBlocked && error==nil && filesRequest==nil && ((try? corrections?.journal.active().isEmpty)==false)}
    func applyCorrection(now:Double=ProcessInfo.processInfo.systemUptime) {
        guard canApplyCorrection,let raw=input.raw,let fit=correctionFit,let current=corrections else {return}
        do {
            let next=try ScanCorrection.replacing(current,fit:fit,raw:raw,segmentID:segment,start:segmentStart,epoch:fit.context.epoch)
            corrections=next
            guard enqueue(event:.correction,time:max(lastPacketTime,now),reason:"明示補正適用") else {corrections=current;return}
            lastExportURL=nil;cachedPackage=nil;correctionChanges=next.journal.changes.count;message="補正を保存中・原本は保持（形状は出力時に再計算）";changed()
        } catch {message="補正を保留: "+ScanErrorMessage.text(error);changed()}
    }
    func undoCorrection(now:Double=ProcessInfo.processInfo.systemUptime) {
        guard canUndoCorrection,let raw=input.raw,let current=corrections else {return}
        do {
            let next=try ScanCorrection.cancellingLast(current,raw:raw);corrections=next
            guard enqueue(event:.correction,time:max(lastPacketTime,now),reason:"補正取消") else {corrections=current;return}
            lastExportURL=nil;cachedPackage=nil;correctionChanges=next.journal.changes.count;message="補正取消を保存中・原観測から再計算します";changed()
        } catch {message="取消を保留: "+ScanErrorMessage.text(error);changed()}
    }
    var canRecoverCopy:Bool {!isRecording && !isSaving && !preparing && selectedRecordID != nil && recoveryBlocked}
    func makeRecoveryCopy() {
        guard canRecoverCopy,let id=selectedRecordID else {return};preparing=true
        let archive=self.archive
        worker.async {let result=Result {try archive.recoveryCopy(id)};Task {@MainActor in
            self.preparing=false
            switch result {
            case .success(let newID):self.error=nil;self.restore(newID)
            case .failure(let e):self.message="回復コピーを作れません: "+ScanErrorMessage.text(e);self.changed()
            }
        }}
    }
    var exportBlockReason:String? {
        if isRecording {return "収録を停止してから出力してください"}
        if isSaving {return "原本の保存中です。保存待ちがなくなるまでお待ちください"}
        if preparing {return "処理中です。完了までお待ちください"}
        if recoveryBlocked {return "保存記録の確認が必要です。確定部分の回復コピーを作成してください"}
        if let error {return error}
        if sessionID==nil {return "収録するか、保存記録を開いてください"}
        if filesRequest != nil {return "Filesの保存画面を閉じてください"}
        return nil
    }
    var canExport:Bool {!isRecording && !isSaving && !preparing && !recoveryBlocked && error==nil && sessionID != nil && filesRequest==nil}
    var canCancelExport:Bool {exportControl != nil}
    func cancelExport() {guard let control=exportControl else {return};control.cancel();message="出力を取消中・処理の安全な終了を待っています";changed()}
    private func beginExport() -> ScanExportControl {
        preparing=true;exportStage="準備";exportFraction=0;exportStarted=Date()
        let token=UUID();exportToken=token
        let control=ScanExportControl(progress:{[weak self] stage,fraction in Task {@MainActor in
            guard let self,self.exportToken==token else {return};self.exportStage=stage;self.exportFraction=max(self.exportFraction,fraction)
        }})
        exportControl=control;message="出力を準備しています・元記録は保持";changed();return control
    }
    private func finishExport() {exportToken=nil;exportControl=nil;exportStarted=nil;preparing=false;exportFraction=1}
    func exportShape(saveToFiles:Bool=false) {export(texture:false,saveToFiles:saveToFiles)}
    func exportTexture(saveToFiles:Bool=false) {export(texture:true,saveToFiles:saveToFiles)}
    private func export(texture:Bool,saveToFiles:Bool) {
        guard canExport,let id=sessionID else {message=exportBlockReason ?? "出力を開始できません";changed();return}
        let control=beginExport(),archive=self.archive,identity=ScanPrototypeIdentity()
        lastExportURL=nil;cachedPackage=nil
        worker.async {
            var completedSource:URL?
            let result=Result { () throws -> (URL,URL?,String) in
                let source:URL,description:String
                if texture {
                    let output=try ScanSurfaceExport.make(archive:archive,id:id,control:control);source=output.url
                    description="画像付きメッシュ: \(output.textured)面に貼付・\(output.untextured)面は灰色（未確認）"
                } else {source=try ScanShapeExport.make(archive:archive,id:id,control:control);description="形状のみの出力を作成（画像なし）"}
                completedSource=source
                let zip=try saveToFiles ? ScanPackage.make(source:source,sessionID:id,root:archive.root.deletingLastPathComponent().appendingPathComponent("LiDARScanFilesPackages",isDirectory:true),identity:identity,freeBytes:archive.freeBytes,control:control):nil
                try control.check();return (source,zip,description)
            }
            let retained=completedSource
            Task {@MainActor in
                self.finishExport();self.lastExportURL=retained
                switch result {
                case .success(let value):
                    self.lastExportURL=value.0;self.message=value.2
                    if let zip=value.1 {self.cachedPackage=(value.0,zip)}
                    if control.isCancelled {self.message=ScanExportFailure.cancelled.message}
                    else if let zip=value.1 {self.filesRequest=ScanFilesRequest(url:zip);self.message+="・Filesの保存先を選んでください"}
                case .failure(let e):self.message="出力を停止: "+ScanErrorMessage.text(e)
                }
                self.changed()
            }
        }
    }
    var canPrepareFiles:Bool {canExport && lastExportURL != nil}
    /// Explicit user action only. Worker lifetime includes validation and ZIP publication.
    func prepareFiles() {
        guard canPrepareFiles,let source=lastExportURL,let id=sessionID else {message=exportBlockReason ?? "先に出力を作成してください";changed();return}
        let control=beginExport(),archive=self.archive,cached=cachedPackage,identity=ScanPrototypeIdentity()
        worker.async {let result=Result { () throws -> URL in
            if let cached,cached.source==source {
                let metadata=try ScanPackage.read(cached.url,control:control);guard metadata.sessionID==id,metadata.identity==identity else {throw ScanPackageFailure.corrupt};return cached.url
            }
            return try ScanPackage.make(source:source,sessionID:id,root:archive.root.deletingLastPathComponent().appendingPathComponent("LiDARScanFilesPackages",isDirectory:true),identity:identity,freeBytes:archive.freeBytes,control:control)
        };Task {@MainActor in
            self.finishExport()
            switch result {
            case .success(let url):
                self.cachedPackage=(source,url)
                if control.isCancelled {self.message=ScanExportFailure.cancelled.message}
                else {self.filesRequest=ScanFilesRequest(url:url);self.message="ZIPを検証済み・保存先を選んで確定してください"}
            case .failure(let e):self.cachedPackage=nil;self.message="Files保存の準備を停止・元記録は保持: "+ScanErrorMessage.text(e)
            }
            self.changed()
        }}
    }
    func filesPickerFinished(_ id:UUID,outcome:ScanFilesOutcome) {
        guard filesRequest?.id==id else {return};filesRequest=nil
        switch outcome {
        case .saved:message="Filesへの保存操作が完了しました・元記録と端末内ZIPは保持"
        case .cancelled:message="Files保存をキャンセル・元記録と端末内ZIPは保持"
        case .failed(let detail):message="Files保存を完了できませんでした・元記録と端末内ZIPは保持: "+detail
        }
        changed()
    }
    func filesPickerDismissed() {if let request=filesRequest {filesPickerFinished(request.id,outcome:.cancelled)}}
    func retrySave() {guard !writing,!jobs.isEmpty,!recoveryBlocked else {return};retried=true;error=nil;message="保存を再試行中・収録は停止";pump();changed()}
}
