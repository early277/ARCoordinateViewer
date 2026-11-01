import Foundation
import Combine
import simd

struct TreeCaptureReference {
    var root: simd_float4x4
    var origin: GeoCoordinate?
    var datum: Double?
    var alignmentRevision: Int
    var epoch: Int
}

enum TreeCoordinateBridge {
    static func point(_ world: SIMD3<Float>, reference: TreeCaptureReference, frame: TreeSurveyFrame) throws -> TreePoint {
        let local=DiagramTransform.localPoint(world,root:reference.root)
        var east=Double(local.x), north = -Double(local.z), up=Double(local.y)
        switch (frame.origin,reference.origin) {
        case (.none,.none): break
        case (.some(let fixed),.some(let current)):
            if fixed.latitude != current.latitude || fixed.longitude != current.longitude {
                let geo=try DXFDrawingExport.coordinate(east:east,north:north,origin:current)
                let offset=CoordinateConverter.enuMeters(from:geo,origin:GeoCoordinate(latitude:fixed.latitude,longitude:fixed.longitude))
                east=offset.east;north=offset.north
            }
        default: throw TreeSurveyFailure("調査の座標基準と立ち位置が一致しません。基準を戻してください")
        }
        switch (frame.verticalDatum,reference.datum) {
        case (.none,.none): break
        case (.some(let fixed),.some(let current)): up += current-fixed
        default: throw TreeSurveyFailure("調査の高さ基準が変わりました。基準を戻してください")
        }
        let point=TreePoint(east:east,north:north,up:up)
        guard point.finite else { throw TreeSurveyFailure("座標を決定できません") }
        return point
    }
    static func display(_ point: TreePoint, frame: TreeSurveyFrame, origin: GeoCoordinate?, datum: Double?) throws -> SIMD3<Float> {
        var east=point.east,north=point.north,up=point.up
        switch (frame.origin,origin) {
        case (.none,.none): break
        case (.some(let fixed),.some(let current)):
            if fixed.latitude != current.latitude || fixed.longitude != current.longitude {
                let geo=try DXFDrawingExport.coordinate(east:east,north:north,origin:GeoCoordinate(latitude:fixed.latitude,longitude:fixed.longitude))
                let offset=CoordinateConverter.enuMeters(from:geo,origin:current)
                east=offset.east;north=offset.north
            }
        default: throw TreeSurveyFailure("保存座標の基準を立ち位置に合わせてください")
        }
        switch (frame.verticalDatum,datum) {
        case (.none,.none): break
        case (.some(let fixed),.some(let current)): up += fixed-current
        default: throw TreeSurveyFailure("保存した高さ基準に戻してください")
        }
        guard east.isFinite,north.isFinite,up.isFinite else { throw TreeSurveyFailure("表示座標が不正です") }
        return SIMD3(Float(east),Float(up),-Float(north))
    }
}

@MainActor
final class TreeSurveyController: ObservableObject {
    enum Mode: Equatable {case surface,left,right,bottom,top,ready}
    @Published private(set) var records:[TreeRecord]=[]
    @Published private(set) var deletedRecords:[TreeRecord]=[]
    @Published private(set) var changeHistoryHealthy=true
    @Published private(set) var changeFailed=false
    @Published private(set) var captureWarning:String?
    @Published private(set) var savedNotice:String?
    @Published private(set) var displayWarning:String?
    func reportDisplayUnavailable(_ count:Int) {
        let value=count>0 ? "保存した\(count)本は座標基準が異なるためAR表示できません。一覧で確認できます":nil
        if displayWarning != value {displayWarning=value}
    }
    private(set) var lastRecordChange:TreeRecordChange?
    private var pendingRecordChange:TreeRecordChange?
    @Published private(set) var frame:TreeSurveyFrame?
    @Published private(set) var active=false
    @Published private(set) var loading=true
    @Published private(set) var saving=false
    @Published private(set) var failedSaveHolding=false
    @Published private(set) var message="樹木の記録を確認中"
    @Published private(set) var warnings:[String]=[]
    @Published private(set) var unreadableIDs:[UUID]=[]
    @Published private(set) var candidate:TreeRecord?
    @Published var reviewPresented=false
    @Published var recordsPresented=false
    @Published private(set) var numberInput="1"
    @Published private(set) var color=TreeColor.red
    @Published private(set) var speciesInput=""
    @Published private(set) var recentSpecies:[String]=[]
    @Published private(set) var capturePending=false
    private(set) var captureRequestID=0
    private(set) var displayRevision=0
    private(set) var recordsRevision=0
    private(set) var mode=Mode.surface
    private var reference:TreeCaptureReference?
    private var pendingRay:ObservationRay?
    private var surface:TreePoint?
    private var surfaceSight:TreeSightRay?
    private var surfaceSource:TreePointSource?
    private var left:TreeSightRay?
    private var markerIDs=(0..<5).map {_ in UUID()}
    private struct CaptureSnapshot {
        var mode:Mode;var reference:TreeCaptureReference?;var pending:ObservationRay?
        var surface:TreePoint?;var sight:TreeSightRay?;var source:TreePointSource?;var left:TreeSightRay?;var candidate:TreeRecord?
    }
    private var history:[CaptureSnapshot]=[]
    private var editingExisting=false
    private var previousDefaults:(TreeColor,String,String)?
    private var previousCapture:CaptureSnapshot?
    private var draftTask:Task<Void,Never>?
    private let store:TreeSurveyStore
    private let worker=DispatchQueue(label:"TreeSurvey.durable",qos:.userInitiated)
    var onChange:(()->Void)?
    init(store:TreeSurveyStore) {self.store=store;reload()}
    var needsSurfaceDistance:Bool {mode == .surface}
    var canCapture:Bool {active && !loading && !saving && !capturePending && !reviewPresented && !recordsPresented && mode != .ready}
    var rays:[ObservationRay] {pendingRay.map {[$0]} ?? []}
    /// Historical edge sights stay directions, separate from measured point markers.
    var directionSights:[TreeDirectionSight] {
        guard active,!editingExisting else {return []}
        if let candidate,let observation=candidate.geometry.cylinder {
            return [TreeDirectionSight(side:.left,ray:observation.left,target:observation.surface),TreeDirectionSight(side:.right,ray:observation.right,target:observation.surface)]
        }
        guard let left,let surface else {return []}
        return [TreeDirectionSight(side:.left,ray:left,target:surface)]
    }
    var markers:[TreeCaptureMarker] {
        guard active else {return []}
        var points:[(Int,TreePoint)]=[]
        if let record=candidate {
            points=record.geometry.surface.enumerated().map {($0.offset,$0.element)}
            if record.geometry.cylinder != nil {
                if let height=record.geometry.height {points += [(3,height.base),(4,height.top)]}
                else if let bottom=record.geometry.cylinder?.bottom,let point=try? TreeCylinderMath.axisPoint(bottom,circle:record.geometry.circle,method:record.geometry.cylinder?.heightMethod) {points.append((3,point))}
            }
        } else if let surface {points=[(0,surface)]}
        return points.map {TreeCaptureMarker(id:markerIDs[$0.0],number:$0.0+1,point:$0.1)}
    }
    var canOpenRecords:Bool {!loading && !saving && !capturePending && !reviewPresented && !failedSaveHolding}
    func openRecords() {guard canOpenRecords else {return};recordsPresented=true}
    var canReviewCircle:Bool {candidate != nil && mode == .ready && !saving && !editingExisting}
    var canUndo:Bool {!saving && !failedSaveHolding && !editingExisting && !history.isEmpty && !capturePending}
    var measuringHeight:Bool {mode == .bottom || mode == .top}
    var canMeasureHeight:Bool {candidate?.geometry.cylinder != nil && !saving && !editingExisting && !failedSaveHolding}
    var reviewingExisting:Bool {editingExisting}
    var captureHint:String {
        switch mode {
        case .surface:return pendingRay == nil ? "樹皮の表面に合わせる" : "横へ移動し、同じ印に合わせる"
        case .left:return "左端に合わせる"
        case .right:return "右端に合わせる"
        case .bottom:return "下端に合わせる"
        case .top:return "梢に合わせる"
        case .ready:return candidate?.geometry.height == nil ? "直径を確認":"直径・樹高を確認"
        }
    }
    var confirmTitle:String {
        switch mode {
        case .surface:return pendingRay == nil ? "表面を確定" : "同じ表面を再確定"
        case .left:return "左端の方向を確定"
        case .right:return "右端の方向を確定"
        case .bottom:return "下端の方向を確定"
        case .top:return "上端の方向を確定"
        case .ready:return "測定完了"
        }
    }
    func requestCenterCapture() {guard canCapture else {return};capturePending=true;captureRequestID &+= 1;changed()}
    func finishCenterCapture(_ id:Int) {guard id==captureRequestID else {return};capturePending=false;changed()}
    func reportCaptureUnavailable(_ reason:String) {guard active,!saving else {return};message=reason;captureWarning=reason;changed()}
    private func changed() {displayRevision &+= 1;onChange?()}
    func reload() {
        guard !saving else {return};loading=true
        let store=self.store
        worker.async { [weak self] in
            let result=Result {try store.load()}
            DispatchQueue.main.async {
                guard let self else {return};self.loading=false
                switch result {
                case .success(let snapshot):
                    self.frame=snapshot.frame;self.records=snapshot.records;self.deletedRecords=snapshot.deletedRecords
                    self.recentSpecies=snapshot.recentSpecies
                    self.changeHistoryHealthy=snapshot.changeHistoryHealthy;self.lastRecordChange=snapshot.lastChange
                    self.recordsRevision &+= 1
                    self.warnings=snapshot.warnings;self.unreadableIDs=snapshot.unreadableIDs
                    if let last=(snapshot.records+snapshot.deletedRecords).max(by:{$0.creationOrder<$1.creationOrder}) {self.color=last.color;self.numberInput=last.number<Int.max ? String(last.number+1):String(last.number)}
                    if let draft=snapshot.draft,let record=draft.record {
                        self.candidate=record;self.color=draft.color;self.numberInput=draft.numberInput;self.mode = .ready
                        self.speciesInput=record.species ?? ""
                        self.active=true;self.reviewPresented=true;self.message="保護した入力を復旧しました。途中の視線は再利用しません"
                    } else {self.message="保存済み \(self.records.count)本"}
                    if !snapshot.unreadableIDs.isEmpty {self.message="\(snapshot.unreadableIDs.count)件を読み込めません。元ファイルを保護しています"}
                case .failure(let error):self.message="読み込み失敗：\(error.localizedDescription)";self.unreadableIDs=[UUID()]
                }
                self.changed()
            }
        }
    }
    func start(origin:GeoCoordinate?,datum:Double?) {
        guard !loading,!saving,unreadableIDs.isEmpty else {return}
        if candidate != nil {active=true;reviewPresented=true;return}
        let proposed=TreeSurveyFrame(origin:origin.map {TreeGeoOrigin(latitude:$0.latitude,longitude:$0.longitude)},verticalDatum:datum)
        saving=true;message="調査基準を保存中";let store=self.store
        worker.async { [weak self] in
            let result=Result {try store.prepare(proposed)}
            DispatchQueue.main.async {
                guard let self else {return};self.saving=false
                switch result {
                case .success(let frame):self.frame=frame;self.active=true;self.resetCapture();self.message=self.captureHint
                case .failure(let error):self.message="基準の保存失敗：\(error.localizedDescription)"
                }
                self.changed()
            }
        }
    }
    private func resetCapture() {
        captureWarning=nil;reference=nil;pendingRay=nil;surface=nil;surfaceSight=nil;surfaceSource=nil;left=nil;history=[];mode = .surface;capturePending=false;markerIDs=(0..<5).map {_ in UUID()}
    }
    private func snapshot()->CaptureSnapshot {CaptureSnapshot(mode:mode,reference:reference,pending:pendingRay,surface:surface,sight:surfaceSight,source:surfaceSource,left:left,candidate:candidate)}
    private func restore(_ value:CaptureSnapshot) {mode=value.mode;reference=value.reference;pendingRay=value.pending;surface=value.surface;surfaceSight=value.sight;surfaceSource=value.source;left=value.left;candidate=value.candidate;reviewPresented=value.mode == .ready;captureWarning=nil}
    func end() {guard !saving else {return};if candidate != nil {reviewPresented=true;return};active=false;resetCapture();message="保存済み \(records.count)本";changed()}
    func retake() {guard !saving,!failedSaveHolding,candidate==nil else {return};resetCapture();message=captureHint;changed()}
    func reviewCircle() {guard canReviewCircle else {return};reviewPresented=true;changed()}
    func undo() {
        guard canUndo,let previous=history.last else {return}
        if candidate != nil {
            saving=true;let store=self.store,color=self.color,number=numberInput,species=speciesInput
            worker.async { [weak self] in
                let result=Result {
                    if var record=previous.candidate {record.species=TreeSpecies.name(species);try store.saveDraft(TreeDraft(record:record,numberInput:number,color:color))}
                    else {try store.discardDraft(color:color,number:number)}
                }
                DispatchQueue.main.async {
                    guard let self else {return};self.saving=false
                    switch result {
                    case .success:self.history.removeLast();self.restore(previous);self.message=self.captureHint
                    case .failure(let error):self.message="入力を保持しています・戻す操作を再試行：\(error.localizedDescription)"
                    }
                    self.changed()
                }
            }
        } else {history.removeLast();restore(previous);message=captureHint;changed()}
    }
    func invalidateObservations(_ reason:String) {
        guard active,!saving,!reviewPresented else {return}
        if candidate != nil {
            history=[];reference=nil;pendingRay=nil
            if measuringHeight {candidate?.geometry.height=nil;candidate?.geometry.cylinder?.bottom=nil;candidate?.geometry.cylinder?.top=nil;mode = .bottom;protectDraft()}
        } else {resetCapture()}
        message=reason+"・途中の方向は取り直してください。確定候補は保持します";captureWarning=message;changed()
    }
    private func sight(_ ray:ObservationRay,reference:TreeCaptureReference,frame:TreeSurveyFrame) throws -> TreeSightRay {
        let origin=try TreeCoordinateBridge.point(ray.origin,reference:reference,frame:frame)
        let endpoint=try TreeCoordinateBridge.point(ray.origin+ray.direction,reference:reference,frame:frame)
        let direction=simd_normalize(endpoint.vector-origin.vector)
        let result=TreeSightRay(origin:origin,direction:TreePoint(east:direction.x,north:direction.y,up:direction.z))
        guard result.unit != nil else {throw TreeSurveyFailure("カメラの方向を確認できません")};return result
    }
    func accept(ray:ObservationRay,depth:SIMD3<Float>?,current:TreeCaptureReference) {
        guard active,!loading,!saving,!reviewPresented,!recordsPresented,mode != .ready,let frame else {return}
        if let old=reference,old.epoch != current.epoch || old.alignmentRevision != current.alignmentRevision {invalidateObservations("位置合わせ・追跡が変わりました");return}
        if reference==nil {reference=current};guard let fixed=reference else {return}
        let before=snapshot()
        do {
            captureWarning=nil
            let view=try sight(ray,reference:fixed,frame:frame)
            switch mode {
            case .surface:
                let world:SIMD3<Float>,source:TreePointSource
                if let first=pendingRay {world=try TreeSurveyMath.triangulate(first,ray,trunk:true);source = .twoRays}
                else if let depth {world=depth;source = .lidar}
                else {pendingRay=ray;surfaceSight=view;history.append(before);message="この表面の信頼できる深度が取れません。横へ移動して同じ樹皮の印を再確定";captureWarning=message;changed();return}
                surface=try TreeCoordinateBridge.point(world,reference:fixed,frame:frame)
                surfaceSight=surfaceSight ?? view;surfaceSource=source;pendingRay=nil;mode = .left
            case .left:left=view;mode = .right
            case .right:
                guard let surface,let surfaceSight,let surfaceSource,let left else {throw TreeSurveyFailure("表面から取り直してください")}
                let observation=TreeCylinderObservation(surface:surface,surfaceRay:surfaceSight,source:surfaceSource,left:left,right:view,heightMethod:.elevationDistance)
                let circle=try TreeCylinderMath.circle(observation)
                candidate=TreeRecord(color:color,number:Int(numberInput) ?? 0,geometry:TreeGeometry(frameID:frame.id,circle:circle,surface:[surface],sources:[surfaceSource],height:nil,cylinder:observation),species:TreeSpecies.name(speciesInput))
                mode = .ready;reviewPresented=true;protectDraft()
            case .bottom:
                guard let circle=candidate?.geometry.circle else {return}
                _=try TreeCylinderMath.axisPoint(view,circle:circle,method:candidate?.geometry.cylinder?.heightMethod)
                candidate?.geometry.cylinder?.bottom=view;candidate?.geometry.cylinder?.top=nil;candidate?.geometry.height=nil
                mode = .top;protectDraft()
            case .top:
                guard var observation=candidate?.geometry.cylinder,let circle=candidate?.geometry.circle else {return}
                observation.top=view
                let height=try TreeCylinderMath.height(observation,circle:circle)
                candidate?.geometry.cylinder=observation;candidate?.geometry.height=height;mode = .ready;reviewPresented=true;protectDraft()
            case .ready:return
            }
            history.append(before);message=captureHint;changed()
        } catch let rejection as DrawingRejection {
            message=rejection.message+"・同じ表面を再確定（回転だけでは測れません）";captureWarning=message;changed()
        } catch {message=error.localizedDescription;captureWarning=message;changed()}
    }
    func beginHeight() {
        guard canMeasureHeight else {return};let before=snapshot();candidate?.geometry.height=nil;candidate?.geometry.cylinder?.bottom=nil;candidate?.geometry.cylinder?.top=nil
        candidate?.geometry.cylinder?.heightMethod = .elevationDistance
        reviewPresented=false;mode = .bottom;reference=nil;history=[before];pendingRay=nil;message=captureHint;protectDraft();changed()
    }
    func abandonHeight() {
        guard canMeasureHeight else {return};candidate?.geometry.height=nil;candidate?.geometry.cylinder?.bottom=nil;candidate?.geometry.cylinder?.top=nil
        pendingRay=nil;mode = .ready;reviewPresented=true;message="樹高は未測定のまま保存できます";protectDraft();changed()
    }
    var stageTitle:String {
        switch mode {
        case .surface:return pendingRay == nil ? "表面":"表面・横移動"
        case .left:return "左端"
        case .right:return "右端"
        case .bottom:return "下端"
        case .top:return "上端"
        case .ready:return "測定値を確認"
        }
    }
    var canChangeRecords:Bool {!loading && !saving && candidate==nil && unreadableIDs.isEmpty && changeHistoryHealthy && !changeFailed}
    var canUndoRecordDeletion:Bool {canChangeRecords && lastRecordChange?.kind == .delete && !(Set(lastRecordChange?.recordIDs ?? []).intersection(Set(deletedRecords.map(\.id)))).isEmpty}
    func changeRecords(_ ids:Set<UUID>,kind:TreeRecordChangeKind) {
        guard canChangeRecords,let frame else {return}
        let available=kind == .delete ? records:deletedRecords
        let scoped=available.filter {ids.contains($0.id) && $0.geometry.frameID==frame.id}.map(\.id).sorted {$0.uuidString<$1.uuidString}
        guard !scoped.isEmpty,scoped.count==ids.count else {message="対象を現在の調査で選び直してください";return}
        applyRecordChange(TreeRecordChange(frameID:frame.id,kind:kind,recordIDs:scoped))
    }
    func undoRecordDeletion() {
        guard canUndoRecordDeletion,let last=lastRecordChange else {return}
        changeRecords(Set(last.recordIDs).intersection(Set(deletedRecords.map(\.id))),kind:.restore)
    }
    func retryRecordChange() {guard !saving,let pendingRecordChange else {return};applyRecordChange(pendingRecordChange)}
    private func applyRecordChange(_ operation:TreeRecordChange) {
        saving=true;pendingRecordChange=operation;message="履歴を保存中・完了を待ってください"
        let store=self.store
        worker.async { [weak self] in
            let result=Result {try store.saveChange(operation)}
            // A first mirror may be durable even if the second write fails. Reconcile
            // the whole operation instead of showing an optimistic or partial batch.
            let recovered:TreeSurveySnapshot?
            if case .failure=result {recovered=try? store.load()} else {recovered=nil}
            DispatchQueue.main.async {
                guard let self else {return};self.saving=false
                let snapshot:TreeSurveySnapshot?
                switch result {
                case .success(let value):
                    snapshot=value;self.pendingRecordChange=nil;self.changeFailed=false;self.savedNotice=nil
                    self.message=operation.kind == .delete ? "\(operation.recordIDs.count)本をゴミ箱へ移動しました。復元できます":"\(operation.recordIDs.count)本を復元しました"
                case .failure(let error):
                    snapshot=recovered;self.changeFailed=true
                    self.message="履歴の保存完了を確認できません。樹木の記録は保持しています。再試行してください：\(error.localizedDescription)"
                }
                if let snapshot {
                    self.records=snapshot.records;self.deletedRecords=snapshot.deletedRecords
                    self.warnings=snapshot.warnings;self.unreadableIDs=snapshot.unreadableIDs
                    self.changeHistoryHealthy=snapshot.changeHistoryHealthy;self.lastRecordChange=snapshot.lastChange;self.recordsRevision &+= 1
                }
                self.changed()
            }
        }
    }
    func setNumber(_ value: String) { numberInput=String(value.prefix(20));scheduleDraftProtection() }
    func setColor(_ value: TreeColor) { color=value;scheduleDraftProtection();changed() }
    func setSpecies(_ value:String) {guard !saving else {return};speciesInput=value;scheduleDraftProtection();changed()}
    private func draft() -> TreeDraft? {
        guard var record=candidate else {return nil}
        record.color=color
        record.species=TreeSpecies.name(speciesInput)
        if let number=Int(numberInput),number>=0 {record.number=number}
        return TreeDraft(record:record,numberInput:numberInput,color:color)
    }
    private func scheduleDraftProtection() {
        draftTask?.cancel()
        draftTask=Task { [weak self] in
            try? await Task.sleep(nanoseconds:350_000_000)
            guard !Task.isCancelled,let self else {return};self.protectDraft()
        }
    }
    private func protectDraft() {
        guard let draft=draft(),!saving,!editingExisting else {return}
        let store=self.store
        worker.async { [weak self] in
            do {try store.saveDraft(draft)}
            catch {DispatchQueue.main.async {self?.message="下書きの保護失敗・入力は保持しています：\(error.localizedDescription)"}}
        }
    }
    func save() {
        guard !saving,!loading,!capturePending,mode == .ready else {return}
        guard !saving,let number=Int(numberInput),number>=0,var record=candidate else {
            message="番号を数字で入力してください";return
        }
        draftTask?.cancel();record.color=color;record.number=number;record.species=TreeSpecies.name(speciesInput)
        let input=TreeDraft(record:record,numberInput:numberInput,color:color)
        saving=true;message="保存中・完了を待ってください"
        let store=self.store, editing=editingExisting, proposed=record
        worker.async { [weak self] in
            let result=Result { () throws -> (record:TreeRecord,snapshot:TreeSurveySnapshot) in
                if !editing {try store.saveDraft(input)}
                let saved=try store.save(proposed)
                if !editing {try? store.discardDraft(color:saved.color,number:String(saved.number))}
                // Publish the same durable snapshot used by the records list and
                // restart restoration, rather than an optimistic in-memory append.
                let snapshot=try store.load()
                guard snapshot.records.contains(where:{$0==saved}) else {
                    throw TreeSurveyFailure("保存した樹木を一覧から確認できません。入力を保持して再試行してください")
                }
                return (saved,snapshot)
            }
            DispatchQueue.main.async {
                guard let self else {return};self.saving=false
                switch result {
                case .success(let result):
                    let saved=result.record
                    self.recentSpecies=result.snapshot.recentSpecies
                    self.savedNotice=saved.color.title+String(saved.number)+" を保存"+(saved.geometry.height == nil ? "・樹高は未測定":"")
                    self.failedSaveHolding=false
                    self.records=result.snapshot.records;self.deletedRecords=result.snapshot.deletedRecords
                    self.warnings=result.snapshot.warnings;self.unreadableIDs=result.snapshot.unreadableIDs
                    self.changeHistoryHealthy=result.snapshot.changeHistoryHealthy;self.lastRecordChange=result.snapshot.lastChange
                    self.recordsRevision &+= 1
                    self.candidate=nil;self.reviewPresented=false;self.editingExisting=false
                    if editing,let defaults=self.previousDefaults {self.color=defaults.0;self.numberInput=defaults.1;self.speciesInput=defaults.2}
                    else if !editing {self.numberInput=saved.number<Int.max ? String(saved.number+1) : String(saved.number);self.speciesInput=""}
                    self.previousDefaults=nil
                    if editing,let previous=self.previousCapture {self.restore(previous)} else {self.resetCapture()}
                    self.previousCapture=nil;self.message="記録済み \(saved.number)・保存済み\(self.records.count)本";self.changed()
                case .failure(let error): self.failedSaveHolding=true;self.message="保存失敗・入力を保持しています。再試行してください：\(error.localizedDescription)"
                }
            }
        }
    }
    func edit(_ record: TreeRecord) {
        guard !saving,candidate==nil else {return}
        previousDefaults=(color,numberInput,speciesInput)
        previousCapture=snapshot()
        candidate=record;color=record.color;numberInput=String(record.number);speciesInput=record.species ?? ""
        editingExisting=true;mode = .ready;reviewPresented=true;message="色・番号・樹種を編集。確定座標は変わりません"
    }
    func cancelReview() {
        guard !saving,!failedSaveHolding else {return}
        if editingExisting {
            if let defaults=previousDefaults {color=defaults.0;numberInput=defaults.1;speciesInput=defaults.2}
            previousDefaults=nil;candidate=nil;editingExisting=false;reviewPresented=false
            if let previous=previousCapture {restore(previous)} else {resetCapture()}
            previousCapture=nil;changed();return
        }
        let store=self.store,color=self.color,number=numberInput
        saving=true
        worker.async { [weak self] in
            let result=Result {try store.discardDraft(color:color,number:number)}
            DispatchQueue.main.async {
                guard let self else {return};self.saving=false
                switch result {
                case .success: self.candidate=nil;self.speciesInput="";self.reviewPresented=false;self.resetCapture();self.message=self.captureHint;self.changed()
                case .failure(let error): self.message="下書きを保持しています：\(error.localizedDescription)"
                }
            }
        }
    }
    func csvURL() throws -> URL {
        guard let frame,!loading,unreadableIDs.isEmpty,changeHistoryHealthy else {throw TreeSurveyFailure("保存データと削除・復元履歴を確認してからCSVを出力してください")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("樹木調査-\(UUID().uuidString).csv")
        try TreeSurveyCSV.encode(frame:frame,records:records).write(to:url,options:.atomic)
        return url
    }
}
