import Foundation
import simd

enum PCControlFailure:String,Error,LocalizedError {
    case reference,duplicate,insufficient,degenerate,missingGCP,stale,invalid,notApplied,discontinuity,baselineMismatch,observationMismatch,samePointGroup,groupConflict,solverCapacity
    var errorDescription:String? {
        switch self {
        case .solverCapacity:return "補正の独立した拘束数が計算上限を超えています。原データは保持し、未補正PLYは出力できます"
        case .reference:return "系番号・測地系・高さ基準を確認してください。異なる座標系は結合しません"
        case .duplicate:return "同じGCP／座標点の重複割当があります"
        case .insufficient:return "水平に離れた2組以上のGCPと座標点が必要です"
        case .degenerate:return "基線が短い、または点の配置から向きを安定して決められません"
        case .missingGCP:return "原観測・深度・追跡世代を確認できないGCPです"
        case .stale:return "原観測または内部補正の選択が変わりました。対応付けを再計算してください"
        case .invalid:return "座標値または保存された計算結果の整合性を確認できません"
        case .notApplied:return "有効な座標変換が適用されていません"
        case .discontinuity:return "追跡の断絶・異なる座標系が含まれるため、時系列補正を伝搬できません"
        case .observationMismatch:return "初期合わせ後の観測差が大きくなっています。対応点と原観測を確認してください"
        case .baselineMismatch:return "最遠ペアの生基線と既知基線が一致しません。対応点・原観測を確認してください（倍率は変更しません）"
        case .samePointGroup:return "同一点グループの所属・原観測・追跡世代を確認してください。停止後の有効なGCPだけを重複なくまとめられます"
        case .groupConflict:return "まとめるGCPに異なる既知座標が割り当てられています。対応付けを確認してから同一点にしてください"
        }
    }
}
struct PCControlReference:Codable,Equatable {
    var planeSystem=9
    var datum="未確認" // Explicit user confirmation; never inferred from numbers.
    var height="未確認" // 未確認 => horizontal fit only, never a measured zero.
    var confirmed=false
    var hasHeight:Bool {height != "未確認"}
    var valid:Bool {(1...19).contains(planeSystem) && ["JGD2011","JGD2000","任意座標"].contains(datum) && ["未確認","標高","楕円体高","任意高"].contains(height) && confirmed}
    var label:String {(datum=="任意座標" ? "任意平面座標": "平面直角\(planeSystem)系・\(datum)")+"・m・X=北/Y=東・"+(hasHeight ? height:"高さ未整合（ZはAR相対高）")}
}
struct PCKnownPoint:Codable,Equatable,Identifiable {
    var id=UUID()
    var name:String
    var north:Double
    var east:Double
    var height:Double?
    var planeSystem:Int
    var source:String
    var sourceID:String
    var originalCells:[String]
    var importDetails:String
    var reviewedCells:[String]?=nil // Explicit edits; original strings stay unchanged.
    var reviewDetails:String?=nil
    var finite:Bool {north.isFinite && east.isFinite && abs(north)<2e7 && abs(east)<2e7 && (height.map{$0.isFinite && abs($0)<1e6} ?? true)}
}
struct PCControlBinding:Codable,Equatable {var gcpID:UUID;var targetID:UUID}
/// User-declared physical identity; raw points and observations are never merged.
/// memberIDs includes representativeID. Historical proposals omit this field.
struct PCSamePointGroup:Codable,Equatable {
    var representativeID:UUID
    var memberIDs:[UUID]
}
struct PCControlBaseline:Codable,Equatable {
    var reference:PCControlReference
    var sourceDigest:String
    var transform:PCControlTransform
}
enum PCControlMethod:String,Codable,CaseIterable {case global,frameConstraints
    var label:String {self == .global ? "全体の位置・向き合わせ（従来）":"既知GCPでフレーム補正"}
}
enum PCControlHeightMode:String,Codable,CaseIterable {
    case useAvailable,horizontalOnly
}
struct PCControlProposal:Codable,Equatable {
    var reference=PCControlReference()
    var targets:[PCKnownPoint]=[]
    var bindings:[PCControlBinding]=[]
    var driftCorrected=false
    var baseline:PCControlBaseline?
    var method:PCControlMethod? = nil // Absent in historical records: original global method.
    var samePointGroups:[PCSamePointGroup]? = nil
    var heightMode:PCControlHeightMode? = nil // Missing => historical use-available-heights behaviour.
    var coordinateSetName:String? = nil // Display/provenance only; never part of correction math.
    var correctsHeight:Bool {heightMode != .horizontalOnly}
    var usesFrames:Bool {method == .frameConstraints}
    var hasSamePointGroups:Bool {!(samePointGroups ?? []).isEmpty}
    var isLocalClosure:Bool {hasSamePointGroups && bindings.isEmpty}
    func representative(for id:UUID)->UUID {
        samePointGroups?.first(where:{$0.memberIDs.contains(id)})?.representativeID ?? id
    }
    func memberIDs(for id:UUID)->[UUID] {
        samePointGroups?.first(where:{$0.memberIDs.contains(id)})?.memberIDs ?? [id]
    }
    func validatedSamePointGroups(record:PCRecord)throws {
        guard hasSamePointGroups else {return}
        guard let checkpoint=record.checkpoint,record.captureStateReadable,
              let epoch=record.frames.first?.frame.epoch,(samePointGroups?.count ?? 0)<=128,
              (samePointGroups ?? []).reduce(0,{$0+$1.memberIDs.count})<=128 else {throw PCControlFailure.samePointGroup}
        let active=checkpoint.raw.activePoints
        guard Set(active.map(\.id)).count==active.count,
              Set(checkpoint.raw.observations.map(\.id)).count==checkpoint.raw.observations.count else {throw PCControlFailure.samePointGroup}
        var used=Set<UUID>()
        for group in samePointGroups ?? [] {
            guard group.memberIDs.count>=2,group.memberIDs.count<=128,
                  group.memberIDs.contains(group.representativeID),
                  Set(group.memberIDs).count==group.memberIDs.count else {throw PCControlFailure.samePointGroup}
            for id in group.memberIDs {
                guard used.insert(id).inserted,let p=active.first(where:{$0.id==id}),p.epoch==epoch else {throw PCControlFailure.samePointGroup}
                for observationID in [p.registrationObservationID]+(p.secondRegistrationObservationID.map{[$0]} ?? []) {
                    guard checkpoint.raw.isObservationActive(observationID),
                          let o=checkpoint.raw.observations.first(where:{$0.id==observationID}),o.epoch==epoch,
                          o.time.isFinite,o.time>=0 else {throw PCControlFailure.samePointGroup}
                }
            }
        }
        guard bindings.allSatisfy({representative(for:$0.gcpID)==$0.gcpID}) else {throw PCControlFailure.samePointGroup}
    }
    func mergingSamePoints(from sourceID:UUID,into destinationID:UUID,record:PCRecord)throws->PCControlProposal {
        guard record.checkpoint?.stopped==true,record.captureStateReadable else {throw PCControlFailure.samePointGroup}
        try validatedSamePointGroups(record:record)
        let activeIDs=Set(record.checkpoint?.raw.activePoints.map(\.id) ?? [])
        guard activeIDs.contains(sourceID),activeIDs.contains(destinationID) else {throw PCControlFailure.samePointGroup}
        let source=representative(for:sourceID),destination=representative(for:destinationID)
        guard source != destination else {return self}
        let members=Array(Set(memberIDs(for:source)+memberIDs(for:destination))).sorted{$0.uuidString<$1.uuidString}
        let affected=bindings.filter{$0.gcpID==source || $0.gcpID==destination}
        if affected.count>1 {
            let known=try affected.map {binding -> PCKnownPoint in
                guard let target=targets.first(where:{$0.id==binding.targetID}),target.finite else {throw PCControlFailure.reference};return target
            }
            guard known.dropFirst().allSatisfy({$0.north==known[0].north && $0.east==known[0].east && $0.height==known[0].height && $0.planeSystem==known[0].planeSystem}) else {throw PCControlFailure.groupConflict}
        }
        var result=self
        var groups=(samePointGroups ?? []).filter{$0.representativeID != source && $0.representativeID != destination}
        groups.append(PCSamePointGroup(representativeID:destination,memberIDs:members))
        result.samePointGroups=groups.sorted{$0.representativeID.uuidString<$1.representativeID.uuidString}
        result.bindings=bindings.filter{$0.gcpID != source && $0.gcpID != destination}
        if let chosen=affected.first(where:{$0.gcpID==destination}) ?? affected.first {
            result.bindings.append(PCControlBinding(gcpID:destination,targetID:chosen.targetID))
        }
        result.method = .frameConstraints
        result.baseline=nil
        try result.validatedSamePointGroups(record:record)
        return result
    }
    /// The representative keeps its known-coordinate binding on unlink. Other
    /// members regain independent identity without inventing assignments.
    func ungroupingSamePoints(representativeID id:UUID)->PCControlProposal {
        var result=self
        let representative=representative(for:id)
        let remaining=(samePointGroups ?? []).filter{$0.representativeID != representative}
        result.samePointGroups=remaining.isEmpty ? nil:remaining
        result.baseline=nil
        return result
    }
}
/// Centred Double computation. Preview never subtracts two huge Float values.
struct PCControlTransform:Codable,Equatable {
    var yaw:Double
    var localOrigin:GCPVector
    var east:Double
    var north:Double
    var height:Double?
    func coordinates(_ point:SIMD3<Double>)->(north:Double,east:Double,height:Double) {
        let d=point-localOrigin.v,c=cos(yaw),s=sin(yaw)
        return(north+s*d.x-c*d.z,east+c*d.x+s*d.z,height.map{$0+d.y} ?? point.y)
    }
    func display(_ point:SIMD3<Double>)->SIMD3<Float> {
        let d=point-localOrigin.v,c=cos(yaw),s=sin(yaw)
        return SIMD3<Float>(SIMD3(c*d.x+s*d.z,d.y,-s*d.x+c*d.z))
    }
}
struct PCControlResidual:Codable,Equatable,Identifiable {
    var id:UUID {gcpID}
    var gcpID:UUID;var targetID:UUID
    var deltaNorth:Double;var deltaEast:Double;var deltaHeight:Double?
    var horizontal:Double {hypot(deltaNorth,deltaEast)}
    var spatial:Double? {deltaHeight.map{hypot(horizontal,$0)}}
    var finite:Bool {deltaNorth.isFinite && deltaEast.isFinite && (deltaHeight.map{$0.isFinite} ?? true) && horizontal.isFinite && (spatial.map{$0.isFinite} ?? true)}
}
struct PCControlSolution:Codable,Equatable {
    var sourceDigest:String
    var transform:PCControlTransform
    var residuals:[PCControlResidual]
    var before:[PCControlResidual]?
    var baselineMetres:Double
    var frameCorrection:PCFrameControlResult? = nil
    var evaluatedResiduals:[PCControlResidual] {frameCorrection?.observations.map(\.after) ?? residuals}
    var heightCount:Int {evaluatedResiduals.filter{$0.deltaHeight != nil}.count}
    var rmsHorizontal:Double {evaluatedResiduals.isEmpty ? 0:sqrt(evaluatedResiduals.reduce(0){$0+$1.horizontal*$1.horizontal}/Double(evaluatedResiduals.count))}
    var maxHorizontal:Double {evaluatedResiduals.map(\.horizontal).max() ?? 0}
    var rmsHeight:Double? {let a=evaluatedResiduals.compactMap(\.deltaHeight);return a.isEmpty ? nil:sqrt(a.reduce(0){$0+$1*$1}/Double(a.count))}
    var rms3D:Double? {let a=evaluatedResiduals.compactMap(\.spatial);return a.isEmpty ? nil:sqrt(a.reduce(0){$0+$1*$1}/Double(a.count))}
    var max3D:Double? {evaluatedResiduals.compactMap(\.spatial).max()}
    /// Numerical quality is separate from a structurally valid calculation.
    /// Explicit application of a poor fit never removes observations or scales it.
    var structurallyValid:Bool {
        let t=transform
        guard t.yaw.isFinite,t.localOrigin.finite,t.east.isFinite,t.north.isFinite,
              t.height.map({$0.isFinite}) ?? true,baselineMetres.isFinite,baselineMetres>=0,
              !evaluatedResiduals.isEmpty,rmsHorizontal.isFinite,(rmsHeight.map{$0.isFinite} ?? true),(rms3D.map{$0.isFinite} ?? true) else {return false}
        return residuals.allSatisfy(\.finite) && evaluatedResiduals.allSatisfy(\.finite) &&
            (before?.allSatisfy(\.finite) ?? true) && (frameCorrection?.structurallyValid ?? true)
    }
    var qualityWarnings:[String] {
        var warnings:[String]=[]
        if maxHorizontal>0.25 || (max3D ?? 0)>0.25 {warnings.append("対応点の残差が大きい結果です。対応と残差を確認してください")}
        if let frame=frameCorrection {
            if frame.maxTranslation>2 {warnings.append("フレーム補正量が大きい結果です（最大\(String(format:"%.3f",frame.maxTranslation))m）")}
            if frame.relativeMaxResidual>0.25 {warnings.append("同一点の補正後残差が大きい結果です")}
            if (frame.maximumObservationDifference ?? 0)>2 {warnings.append("初期合わせ後の観測差が大きい結果です（最大\(String(format:"%.3f",frame.maximumObservationDifference!))m）")}
            if frame.yawResolved && abs(baselineMetres-frame.targetBaseline)>max(0.25,frame.targetBaseline*0.05) {warnings.append("生データと既知座標の基線長が異なります。倍率は1のままです")}
        }
        return warnings
    }
    var canApply:Bool {canApply(qualityOverride:false)}
    func canApply(qualityOverride:Bool)->Bool {structurallyValid && (qualityOverride || qualityWarnings.isEmpty)}
}
struct PCControlState:Codable,Equatable {
    var schema=1
    var id=UUID()
    var proposal:PCControlProposal
    var solution:PCControlSolution?
    var applied=false
    var continuationID:UUID? = nil
    var qualityOverride:Bool? = nil // Only an explicit poor-quality application sets true.
}
enum PCControlMath {
    static func markers(record:PCRecord,solution:PCControlSolution)->[SIMD3<Float>?] {
        if !record.posePrepared,record.checkpoint?.poseEvents?.isEmpty==false {
            guard let derived=try? PCPoseCorrection.prepare(record) else {return record.checkpoint?.raw.activePoints.map{_ in nil} ?? []}
            return markers(record:derived,solution:solution)
        }
        return (record.checkpoint?.raw.activePoints ?? []).map {point in
            guard let p=try? source(point,record:record,corrected:record.selection?.corrected ?? false,frameOffsets:solution.frameCorrection?.offsets) else {return nil}
            return solution.transform.display(p)
        }
    }
    static func digest(_ record:PCRecord,corrected:Bool,heightMode:PCControlHeightMode?=nil)throws->String {
        try PCPoseCorrection.validateMotionDecisions(record)
        if !record.posePrepared,record.checkpoint?.poseEvents?.isEmpty==false {return try digest(PCPoseCorrection.prepare(record),corrected:corrected,heightMode:heightMode)}
        guard let checkpoint=record.checkpoint,checkpoint.stopped else {throw PCControlFailure.invalid}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var data=try encoder.encode(checkpoint)
        if checkpoint.poseEvents?.isEmpty==false {data.append(contentsOf:Data(PCPoseCorrection.recipe.utf8))}
        data.append(try encoder.encode(record.frames))
        data.append(contentsOf:corrected ? [1]:[0])
        // Recompute rather than trust stored offsets; preserve old raw-only files.
        if corrected {_=try PCCorrection.offsets(record:record)}
        // Preserve the exact historic digest for nil/useAvailable records.
        if heightMode == .horizontalOnly {data.append(contentsOf:Data("horizontal-only-height-v1".utf8))}
        return PCStore.digest(data)
    }
    static func source(_ point:GCPPoint,record:PCRecord,corrected:Bool,frameOffsets:[UUID:GCPVector]?=nil)throws->SIMD3<Double> {
        if !record.posePrepared,record.checkpoint?.poseEvents?.isEmpty==false {
            let derived=try PCPoseCorrection.prepare(record)
            guard let point=derived.checkpoint?.raw.activePoints.first(where:{$0.id==point.id}) else {throw PCControlFailure.missingGCP}
            return try source(point,record:derived,corrected:corrected,frameOffsets:frameOffsets)
        }
        guard let checkpoint=record.checkpoint,let observation=checkpoint.raw.observations.first(where:{$0.id==point.registrationObservationID}),
              observation.epoch==point.epoch,point.epoch==record.frames.first?.frame.epoch else {throw PCControlFailure.missingGCP}
        guard checkpoint.raw.activePoints.contains(where:{$0.id==point.id}) else {throw PCControlFailure.missingGCP}
        let offsets=try frameOffsets ?? (corrected ? PCCorrection.offsets(record:record):[:])
        func offset(at time:Double)throws->SIMD3<Double> {
            if frameOffsets != nil {return try PCFrameControlMath.offset(time:time,record:record,offsets:offsets)}
            guard corrected else {return .zero}
            let autos=record.frames.filter{$0.frame.automatic}
            guard let first=autos.first,let last=autos.last,time>=first.frame.time,time<=last.frame.time else {throw PCControlFailure.missingGCP}
            if time==last.frame.time {return offsets[last.id]!.v}
            guard let i=(0..<autos.count-1).first(where:{autos[$0].frame.time<=time && time<autos[$0+1].frame.time}) else {throw PCControlFailure.missingGCP}
            let a=autos[i],b=autos[i+1],t=(time-a.frame.time)/(b.frame.time-a.frame.time)
            return offsets[a.id]!.v*(1-t)+offsets[b.id]!.v*t
        }
        let source:SIMD3<Double>
        if let secondID=point.secondRegistrationObservationID {
            guard let second=checkpoint.raw.observations.first(where:{$0.id==secondID}) else {throw PCControlFailure.missingGCP}
            // Correct each observation's camera origin at its own time before
            // re-intersecting. Never reuse a depth sample from the grass in front.
            var a=observation,b=second
            a.pose.position=GCPVector(a.pose.position.v+(try offset(at:a.time)))
            b.pose.position=GCPVector(b.pose.position.v+(try offset(at:b.time)))
            a.captureEvidence=nil;b.captureEvidence=nil
            source=try GCPMath.triangulate(a,b).position.v
        } else {
            try GCPMath.usable(observation)
            source=try observation.depthPoint()+offset(at:observation.time)
        }
        return source
    }
    static func fit(record:PCRecord,proposal:PCControlProposal,work:PCWorkControl?=nil)throws->PCControlSolution {
        if !record.posePrepared,record.checkpoint?.poseEvents?.isEmpty==false {return try fit(record:PCPoseCorrection.prepare(record),proposal:proposal,work:work)}
        try work?.check()
        try proposal.validatedSamePointGroups(record:record)
        guard !proposal.hasSamePointGroups || proposal.usesFrames else {throw PCControlFailure.samePointGroup}
        if proposal.usesFrames {return try PCFrameControlMath.fit(record:record,proposal:proposal,work:work)}
        guard proposal.reference.valid,proposal.targets.count<=5000 else {throw PCControlFailure.reference}
        guard proposal.bindings.count>=2,proposal.bindings.count<=128 else {throw PCControlFailure.insufficient}
        guard Set(proposal.targets.map(\.id)).count==proposal.targets.count,
              Set(proposal.bindings.map(\.gcpID)).count==proposal.bindings.count,
              Set(proposal.bindings.map(\.targetID)).count==proposal.bindings.count else {throw PCControlFailure.duplicate}
        let fingerprint=try digest(record,corrected:proposal.driftCorrected,heightMode:proposal.heightMode)
        var sources:[SIMD3<Double>]=[],targets:[PCKnownPoint]=[]
        for binding in proposal.bindings {
            guard let gcp=record.checkpoint?.raw.activePoints.first(where:{$0.id==binding.gcpID}),
                  let target=proposal.targets.first(where:{$0.id==binding.targetID}),target.finite,
                  target.planeSystem==proposal.reference.planeSystem else {throw PCControlFailure.reference}
            sources.append(try source(gcp,record:record,corrected:proposal.driftCorrected));targets.append(target)
        }
        // Different imported IDs at the same coordinate are also duplicate controls.
        var baseline=0.0,targetBaseline=0.0
        for i in sources.indices {for j in sources.indices where j>i {
            let a=hypot(sources[i].x-sources[j].x,sources[i].z-sources[j].z)
            let b=hypot(targets[i].east-targets[j].east,targets[i].north-targets[j].north)
            guard a>0.001,b>0.001 else {throw PCControlFailure.duplicate}
            baseline=max(baseline,a);targetBaseline=max(targetBaseline,b)
        }}
        guard baseline>=0.5,targetBaseline>=0.5 else {throw PCControlFailure.degenerate}
        let n=Double(sources.count),origin=sources.reduce(SIMD3<Double>.zero,+)/n
        // Stable centring around the first target avoids large-coordinate sums.
        let east=targets[0].east+targets.reduce(0){$0+($1.east-targets[0].east)}/n
        let north=targets[0].north+targets.reduce(0){$0+($1.north-targets[0].north)}/n
        var dot=0.0,cross=0.0,sourceEnergy=0.0,targetEnergy=0.0
        for i in sources.indices {
            let a=SIMD2(sources[i].x-origin.x,-sources[i].z+origin.z),b=SIMD2(targets[i].east-east,targets[i].north-north)
            dot+=simd_dot(a,b);cross+=a.x*b.y-a.y*b.x;sourceEnergy+=simd_length_squared(a);targetEnergy+=simd_length_squared(b)
        }
        guard hypot(dot,cross)>1e-8*sqrt(sourceEnergy*targetEnergy) else {throw PCControlFailure.degenerate}
        let heights=targets.indices.compactMap {i -> Double? in
            guard proposal.correctsHeight,proposal.reference.hasHeight,let h=targets[i].height else {return nil};return h-(sources[i].y-origin.y)
        }
        let height=heights.isEmpty ? nil:heights[0]+heights.reduce(0){$0+($1-heights[0])}/Double(heights.count)
        let transform=PCControlTransform(yaw:atan2(cross,dot),localOrigin:GCPVector(origin),east:east,north:north,height:height)
        func residuals(_ t:PCControlTransform)->[PCControlResidual] {
            sources.indices.map {i in
                let q=t.coordinates(sources[i]),p=targets[i]
                let dz=(proposal.correctsHeight && proposal.reference.hasHeight && t.height != nil) ? p.height.map{q.height-$0}:nil
                return PCControlResidual(gcpID:proposal.bindings[i].gcpID,targetID:p.id,deltaNorth:q.north-p.north,deltaEast:q.east-p.east,deltaHeight:dz)
            }
        }
        let previous=proposal.baseline.flatMap {b in b.reference==proposal.reference && b.sourceDigest==fingerprint ? residuals(b.transform):nil}
        return PCControlSolution(sourceDigest:fingerprint,transform:transform,residuals:residuals(transform),before:previous,baselineMetres:baseline)
    }
    static func active(_ record:PCRecord)throws->PCControlSolution? {
        guard let state=record.control,state.applied else {return nil}
        guard state.schema==1,(state.proposal.usesFrames || state.proposal.driftCorrected==(record.selection?.corrected ?? false)),let saved=state.solution else {throw PCControlFailure.stale}
        let recomputed=try fit(record:record,proposal:state.proposal)
        guard recomputed==saved,recomputed.canApply(qualityOverride:state.qualityOverride==true) else {throw PCControlFailure.stale}
        return recomputed
    }
    static func selectedOffsets(_ record:PCRecord,solution:PCControlSolution?)throws->[UUID:GCPVector] {
        if let frames=solution?.frameCorrection {return frames.offsets}
        return try PCCorrection.checkedSelection(record)
    }
}

enum PCControlPLY {
    /// Explicit opt-in only. Double XYZ avoids loss at large public coordinates;
    /// bytes are X=north, Y=east, Z=confirmed height or labelled local AR height.
    static func export(store:PCStore,id:UUID,folder:URL,control:PCWorkControl=PCWorkControl(),progress:(Double)->Void={_ in})throws->URL {
        try control.check();let record=try PCPoseCorrection.prepare(store.load(id))
        guard let solution=try PCControlMath.active(record),let state=record.control else {throw PCControlFailure.notApplied}
        let offsets=try PCControlMath.selectedOffsets(record,solution:solution),count=record.frames.reduce(0){$0+$1.pointCount}
        guard count>0,store.freeBytes()>store.minimumFree+Int64(count*27+65536) else {throw PCFailure.capacity}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let localOnly=solution.frameCorrection?.localOnly==true
        let stem="point-cloud-"+id.uuidString+(localOnly ? "-local-closure-":"-coordinates-")+UUID().uuidString
        let partial=folder.appendingPathComponent(stem+".partial"),final=folder.appendingPathComponent(stem+".ply")
        guard FileManager.default.createFile(atPath:partial.path,contents:nil) else {throw PCFailure.capacity}
        let file=try FileHandle(forWritingTo:partial);defer{try? file.close()}
        let reference=state.proposal.reference
        let datum=["JGD2011":"JGD2011","JGD2000":"JGD2000","任意座標":"local-user-reference"][reference.datum] ?? "unconfirmed"
        let heightName=["標高":"orthometric-user-confirmed","楕円体高":"ellipsoidal-user-confirmed","任意高":"local-user-height"][reference.height] ?? "unconfirmed"
        let plane=reference.datum=="任意座標" ? "user-defined local plane (no geographic datum)":"Japanese plane zone \(reference.planeSystem)"
        let header="""
        ply
        format binary_little_endian 1.0
        comment \(localOnly ? "units metre; X=raw AR x Y=raw AR y (up) Z=raw AR z; local same-point closure":"units metre; X=north Y=east Z=up; \(plane)")
        comment \(localOnly ? "NO geographic datum; NO known coordinates; AR axes retained; Y is local relative height, NOT an elevation":"datum \(datum); height \(solution.transform.height == nil ? "UNREFERENCED local AR y, NOT an elevation":heightName)")
        comment yaw-and-translation only; fixed scale 1; source \(id.uuidString)
        comment control-event \(state.id.uuidString); original inputs preserved; no accuracy guarantee
        comment \(solution.frameCorrection?.plyDescription ?? "internal-drift-correction \(state.proposal.driftCorrected); then coordinate transform")
        comment RGB sRGB; measured points only; missing regions not filled
        comment \(localOnly ? "local closure residuals, NOT absolute accuracy":"known-coordinate residuals"); horizontal RMS \(solution.rmsHorizontal); max \(solution.maxHorizontal); controls \(solution.residuals.count); observations \(solution.evaluatedResiduals.count); valid heights \(solution.heightCount)
        comment \(localOnly ? "output stores corrected local AR XYZ Double coordinates":"display-origin east \(solution.transform.east) north \(solution.transform.north); output stores absolute Double coordinates")
        element vertex \(count)
        property double x
        property double y
        property double z
        property uchar red
        property uchar green
        property uchar blue
        end_header
        """+"\n"
        var annotated=header
        var comments:[String]=[]
        if (record.checkpoint?.motionDecisionCount ?? 0)>0 {comments.append("comment physical-motion-by-rule decisions \(record.checkpoint?.motionDecisionCount ?? 0); no pose delta added for these decisions; causal accuracy not guaranteed")}
        if record.checkpoint?.poseEvents?.isEmpty==false {comments.append("comment heuristic segment-local pose steps applied before GCP/coordinate fit; no ARKit cause assertion")}
        if state.proposal.heightMode == .horizontalOnly {comments.append("comment horizontal-only coordinate correction; known heights ignored; source relative height preserved")}
        if state.qualityOverride==true {comments.append("comment quality-warning override explicitly applied by user; NOT an accuracy approval")}
        if !comments.isEmpty {annotated=header.replacingOccurrences(of:"element vertex \(count)\n",with:comments.joined(separator:"\n")+"\nelement vertex \(count)\n")}
        try file.write(contentsOf:Data(annotated.utf8))
        for (i,entry) in record.frames.enumerated() {
            try control.check();guard store.freeBytes()>store.minimumFree else {throw PCFailure.capacity}
            var bytes=Data();bytes.reserveCapacity(entry.pointCount*27)
            for p in try store.points(entry,id:id) {
                let base=record.poseTransforms[entry.id]?.point(SIMD3<Double>(p.position)) ?? SIMD3<Double>(p.position)
                let corrected=base+(offsets[entry.id] ?? GCPVector()).v
                let q=solution.transform.coordinates(corrected)
                for value in localOnly ? [corrected.x,corrected.y,corrected.z]:[q.north,q.east,q.height] {var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){bytes.append(contentsOf:$0)}}
                bytes.append(contentsOf:[p.r,p.g,p.b])
            }
            try file.write(contentsOf:bytes);progress(Double(i+1)/Double(record.frames.count))
        }
        try control.check();try file.synchronize();try file.close()
        try FileManager.default.moveItem(at:partial,to:final);return final
    }
}

/// Versioned derived result. Offsets are in raw AR axes so every renderer/exporter
/// uses exactly T0(raw + offset), never the old internal correction as well.
struct PCFrameControlObservation:Codable,Equatable,Identifiable {
    var id:UUID {observationIDs[0]}
    var gcpID:UUID
    var targetID:UUID
    var observationIDs:[UUID]
    var times:[Double]
    var before:PCControlResidual
    var after:PCControlResidual
    var relative:Bool? = nil // targetID identifies a same-point group, not a known coordinate.
}
struct PCFrameControlResult:Codable,Equatable {
    var version=1
    var epoch:GCPEpoch
    var anchorGCP:UUID
    var directionGCP:UUID?
    var yawResolved:Bool
    var targetBaseline:Double
    var offsets:[UUID:GCPVector]
    var observations:[PCFrameControlObservation]
    var relativeGCPs:[UUID]
    var relativeMaxResidual:Double
    var firstConstraintTime:Double
    var lastConstraintTime:Double
    var maxTranslation:Double
    var maximumRayOffsetDifference:Double
    var notes:[String]
    var localOnly:Bool? = nil
    // Only new fits exceeding the old gate need this field; leaving it nil for
    // ordinary fits preserves equality with historical applied results.
    var maximumObservationDifference:Double? = nil
    var structurallyValid:Bool {
        maxTranslation.isFinite && maxTranslation>=0 && relativeMaxResidual.isFinite && relativeMaxResidual>=0 &&
        maximumRayOffsetDifference.isFinite && maximumRayOffsetDifference>=0 && maximumRayOffsetDifference<=0.005 &&
        (maximumObservationDifference.map{$0.isFinite && $0>=0} ?? true) &&
        firstConstraintTime.isFinite && firstConstraintTime>=0 && lastConstraintTime.isFinite && firstConstraintTime<=lastConstraintTime &&
        targetBaseline.isFinite && targetBaseline>=0 && epoch.generation>=0 &&
        !offsets.isEmpty && offsets.count<=PCLimits.maximumFrames && offsets.values.allSatisfy(\.finite) &&
        !observations.isEmpty && observations.allSatisfy {o in
            !o.observationIDs.isEmpty && o.observationIDs.count<=2 && o.times.count==o.observationIDs.count &&
            o.times.allSatisfy{$0.isFinite && $0>=0} && o.before.finite && o.after.finite
        }
    }
    var safe:Bool {
        structurallyValid && maxTranslation<=2 && relativeMaxResidual<=0.25 && (maximumObservationDifference ?? 0)<=2 &&
        observations.allSatisfy{$0.after.horizontal<=0.25 && ($0.after.spatial ?? 0)<=0.25}
    }
    var plyDescription:String {
        if localOnly==true {return "user-declared same-point local closure v1; AR axes retained; first observation correction fixed at zero; old internal correction NOT applied; endpoint hold; NO absolute position or heading alignment"}
        return "known-GCP frame translation v1; fixed initial yaw; old internal correction NOT applied; endpoint hold; " +
        (yawResolved ? "yaw from farthest raw horizontal pair":"YAW UNRESOLVED: one-control translation only; NOT a survey coordinate alignment")
    }
}

enum PCFrameControlMath {
    struct Sample {
        var pointID:UUID
        var observations:[GCPObservation]
        var point:SIMD3<Double>
        var times:[Double] {observations.map(\.time)}
        var time:Double {observations[0].time}
    }
    struct Row {var coefficients:[Double];var value:Double;var time:Double;var fromTime:Double? = nil}
    static func weights(time:Double,autos:[PCFrame])->[Double] {
        var a=[Double](repeating:0,count:autos.count)
        if time<=autos[0].time {a[0]=1;return a}
        if time>=autos.last!.time {a[a.count-1]=1;return a}
        let i=(0..<autos.count-1).first{autos[$0].time<=time && time<autos[$0+1].time}!
        let f=(time-autos[i].time)/(autos[i+1].time-autos[i].time)
        a[i]=1-f;a[i+1]=f;return a
    }
    static func offset(time:Double,record:PCRecord,offsets:[UUID:GCPVector])throws->SIMD3<Double> {
        let autos=record.frames.filter{$0.frame.automatic}.map(\.frame)
        guard !autos.isEmpty,time.isFinite,autos.allSatisfy({offsets[$0.id]?.finite==true}) else {throw PCControlFailure.invalid}
        return zip(autos,weights(time:time,autos:autos)).reduce(SIMD3<Double>.zero){$0+offsets[$1.0.id]!.v*$1.1}
    }
    /// Only accepted, noncancelled operations become constraints. Pending or
    /// rejected observations are evidence, not implicitly associated by distance.
    static func samples(record:PCRecord)throws->([Sample],[String]) {
        guard let checkpoint=record.checkpoint else {throw PCControlFailure.invalid}
        let raw=checkpoint.raw
        guard raw.observations.count<=4096,Set(raw.observations.map(\.id)).count==raw.observations.count else {throw PCControlFailure.invalid}
        let byID=Dictionary(uniqueKeysWithValues:raw.observations.map{($0.id,$0)})
        var result:[Sample]=[],notes:[String]=[],used=Set<UUID>()
        func append(_ ids:[UUID],point:UUID,direction:Bool=false)throws {
            guard !ids.isEmpty,ids.count<=2 else {throw PCControlFailure.invalid}
            guard ids.allSatisfy({raw.isObservationActive($0)}) else {return}
            if ids.allSatisfy({used.contains($0)}) {return}
            guard ids.allSatisfy({!used.contains($0)}),let epoch=record.frames.first?.frame.epoch else {throw PCControlFailure.invalid}
            let observations=try ids.map {id -> GCPObservation in
                guard let o=byID[id],o.epoch==epoch else {throw PCControlFailure.discontinuity};return o
            }.sorted{$0.time<$1.time}
            let position:SIMD3<Double>
            if observations.count==2 {
                position=try GCPMath.triangulate(observations[0],observations[1]).position.v
            } else {
                let o=observations[0]
                if direction || o.associationEvidence?.directionOnly==true || o.depth==nil {
                    notes.append("単独視線 \(o.id.uuidString): 奥行き未拘束のため今回の3軸補正には不使用（原観測保持）")
                    used.insert(o.id);return
                }
                try GCPMath.usable(o);position=try o.depthPoint()
            }
            used.formUnion(ids);result.append(Sample(pointID:point,observations:observations,point:position))
        }
        for p in raw.activePoints {
            try append([p.registrationObservationID]+(p.secondRegistrationObservationID.map{[$0]} ?? []),point:p.id)
        }
        let activeIDs=Set(raw.activePoints.map(\.id)),cancelled=Set((raw.captureCancellations ?? []).compactMap(\.operationID))
        if let operations=raw.captureOperations {
            for operation in operations where !cancelled.contains(operation.id) && activeIDs.contains(operation.pointID) {
                try append(operation.observationIDs,point:operation.pointID)
            }
        } else {
            // Legacy records: accepted fit bindings are the association evidence.
            // Keep a two-ray pair together, never triangulate arbitrary old rays.
            for fit in try PCCorrection.activeFits(raw:raw,fits:checkpoint.fits) {
                let bindings=raw.activeBindings(fit.bindings)
                if bindings.count==2,bindings[0].pointID==bindings[1].pointID,bindings.allSatisfy({$0.directionOnly}) {
                    try append(bindings.map(\.observationID),point:bindings[0].pointID)
                } else {for b in bindings {try append([b.observationID],point:b.pointID,direction:b.directionOnly)}}
            }
        }
        result.sort {$0.time==$1.time ? $0.observations[0].id.uuidString<$1.observations[0].id.uuidString:$0.time<$1.time}
        return(result,notes)
    }
    /// Equal-weight observations with weak second-difference regularization in
    /// AUTOMATIC frame ordinal (1e-6). Manual frames never add unknowns/weight.
    /// Endpoint groups are collapsed exactly; no extrapolated slope or zero reset.
    // The capture limit does not become a dense matrix dimension. A live scan
    // accepts 128 GCP observations, each supporting at most two automatic-frame
    // neighbours: <=258 support nodes including the endpoints. Bound imported
    // or malformed historical constraint sets separately before allocating m².
    static let maximumSupportKnots=512
    static func solve(rows:[Row],autos:[PCFrame],bounds:(Double,Double),work:PCWorkControl?=nil)throws->[Double] {
        try work?.check()
        let n=autos.count
        guard n>0,n<=PCLimits.maximumFrames,bounds.0.isFinite,bounds.1.isFinite,bounds.0<=bounds.1,
              autos.allSatisfy({$0.time.isFinite}),zip(autos,autos.dropFirst()).allSatisfy({$0.time<$1.time}),
              rows.allSatisfy({$0.coefficients.count==n && $0.coefficients.allSatisfy(\.isFinite) && $0.value.isFinite}) else {throw PCControlFailure.invalid}
        guard !rows.isEmpty else {return [Double](repeating:0,count:n)}
        let first=weights(time:bounds.0,autos:autos),last=weights(time:bounds.1,autos:autos)
        let left=first.lastIndex(where:{$0>0})!,right=last.firstIndex(where:{$0>0})!
        let low=min(left,right),high=max(left,right)
        // If controls fall in the same automatic interval, a constant correction
        // is the identifiable endpoint-hold model. Conflicting observations stay residuals.
        var knotSet=Set([low,high])
        for row in rows {
            try work?.check()
            for i in 0..<n where row.coefficients[i] != 0 {knotSet.insert(max(low,min(high,i)))}
        }
        let knots=left>=right ? [low]:knotSet.sorted(),m=knots.count
        guard m<=maximumSupportKnots else {throw PCControlFailure.solverCapacity}
        let basis=try (0..<n).map {i -> [(Int,Double)] in
            if i%128==0 {try work?.check()}
            if i<=knots[0] {return [(0,1)]}
            if i>=knots.last! {return [(m-1,1)]}
            let j=(0..<m-1).first{knots[$0]<=i && i<knots[$0+1]}!
            let f=Double(i-knots[j])/Double(knots[j+1]-knots[j])
            return [(j,1-f),(j+1,f)]
        }
        var a=[Double](repeating:0,count:m*m),b=[Double](repeating:0,count:m)
        func add(_ coefficients:[Double],_ value:Double,_ weight:Double)throws {
            try work?.check()
            var c=[Double](repeating:0,count:m)
            for i in 0..<n where coefficients[i] != 0 {for (j,w) in basis[i] {c[j]+=coefficients[i]*w}}
            let nonzero=c.indices.filter{c[$0] != 0}
            for i in nonzero {b[i]+=weight*c[i]*value;for j in nonzero {a[i*m+j]+=weight*c[i]*c[j]}}
        }
        for row in rows {try add(row.coefficients,row.value,1)}
        // Every gap without an observation is EXACTLY linear in automatic-frame
        // ordinal. Only adjacent observation-support nodes remain unknown. Weak
        // slope regularization resolves a subframe constraint's remaining freedom.
        if m>2 {for i in 1..<m-1 {
            try work?.check()
            let l=Double(knots[i]-knots[i-1]),r=Double(knots[i+1]-knots[i])
            let c=[(i-1,1/l),(i,-1/l-1/r),(i+1,1/r)]
            for (j,x) in c {for (k,y) in c {a[j*m+k]+=1e-6*x*y}}
        }}
        // Cholesky is bounded by observation support, not the capture frame
        // count. Cancellation is checked during factorisation/solve as well.
        // Singular problems remain held; weights and arithmetic are unchanged.
        var l=[Double](repeating:0,count:m*m)
        for i in 0..<m {try work?.check();for j in 0...i {
            if j%32==0 {try work?.check()}
            var sum=a[i*m+j]
            if j>0 {for k in 0..<j {sum-=l[i*m+k]*l[j*m+k]}}
            if i==j {guard sum.isFinite,sum>1e-14 else {throw PCControlFailure.degenerate};l[i*m+j]=sqrt(sum)}
            else {l[i*m+j]=sum/l[j*m+j]}
        }}
        var x=[Double](repeating:0,count:m)
        for i in 0..<m {try work?.check();var s=b[i];for j in 0..<i {s-=l[i*m+j]*x[j]};x[i]=s/l[i*m+i]}
        for i in (0..<m).reversed() {try work?.check();var s=x[i];if i+1<m {for j in i+1..<m {s-=l[j*m+i]*x[j]}};x[i]=s/l[i*m+i]}
        guard x.allSatisfy(\.isFinite) else {throw PCControlFailure.invalid}
        return basis.map{row in row.reduce(0){$0+x[$1.0]*$1.1}}
    }
    static func fit(record:PCRecord,proposal:PCControlProposal,work:PCWorkControl?=nil)throws->PCControlSolution {
        if !record.posePrepared,record.checkpoint?.poseEvents?.isEmpty==false {return try fit(record:PCPoseCorrection.prepare(record),proposal:proposal,work:work)}
        try work?.check()
        try proposal.validatedSamePointGroups(record:record)
        guard !proposal.hasSamePointGroups || proposal.usesFrames else {throw PCControlFailure.samePointGroup}
        let localOnly=proposal.isLocalClosure
        guard (localOnly || proposal.reference.valid),proposal.targets.count<=5000 else {throw PCControlFailure.reference}
        guard (localOnly || !proposal.bindings.isEmpty),proposal.bindings.count<=128 else {throw PCControlFailure.insufficient}
        guard Set(proposal.targets.map(\.id)).count==proposal.targets.count,
              Set(proposal.bindings.map(\.gcpID)).count==proposal.bindings.count,
              Set(proposal.bindings.map(\.targetID)).count==proposal.bindings.count else {throw PCControlFailure.duplicate}
        guard let checkpoint=record.checkpoint,checkpoint.stopped,record.captureStateReadable,
              let epoch=record.frames.first?.frame.epoch,!record.frames.isEmpty,record.frames.count<=PCLimits.maximumFrames else {throw PCControlFailure.invalid}
        guard record.frames.allSatisfy({$0.frame.epoch==epoch && $0.frame.time.isFinite && $0.frame.time>=0}),
              Set(record.frames.map(\.id)).count==record.frames.count,
              checkpoint.raw.trajectory.allSatisfy({$0.time.isFinite && $0.time>=0}),
              zip(record.frames,record.frames.dropFirst()).allSatisfy({$0.frame.time<$1.frame.time}) else {throw PCControlFailure.discontinuity}
        let autos=record.frames.filter{$0.frame.automatic}.map(\.frame)
        guard !autos.isEmpty else {throw PCControlFailure.insufficient}
        let (samples,initialNotes)=try samples(record:record)
        var notes=initialNotes
        guard !samples.isEmpty else {throw PCControlFailure.missingGCP}
        if samples.flatMap(\.times).contains(where:{$0<autos[0].time || $0>autos.last!.time}) {notes.append("自動フレーム保存範囲外の観測は端のフレームへ拘束。保存されていない点やフレームは生成しません")}
        let start=min(record.frames[0].frame.time,samples.first!.time),end=max(record.frames.last!.frame.time,samples.flatMap(\.times).max()!)
        guard checkpoint.raw.trajectory.filter({$0.time>=start && $0.time<=end}).allSatisfy({$0.epoch==epoch && $0.tracking == .normal}) else {throw PCControlFailure.discontinuity}
        notes.append("同一追跡世代内でのみ計算。記録にない追跡履歴や空白区間の連続性・精度は保証しません")
        let grouped=Dictionary(grouping:samples,by:{proposal.representative(for:$0.pointID)})
        let explicitGroups=Set((proposal.samePointGroups ?? []).map(\.representativeID))
        // A declared member without a usable sample cannot silently disappear
        // from the physical identity constraint.
        for group in proposal.samePointGroups ?? [] {
            guard group.memberIDs.allSatisfy({id in samples.contains(where:{$0.pointID==id})}) else {throw PCControlFailure.missingGCP}
        }
        var representatives:[Sample]=[],targets:[PCKnownPoint]=[]
        for binding in proposal.bindings {
            guard let sample=grouped[binding.gcpID]?.first,let target=proposal.targets.first(where:{$0.id==binding.targetID}),target.finite,target.planeSystem==proposal.reference.planeSystem else {throw PCControlFailure.missingGCP}
            representatives.append(sample);targets.append(target)
        }
        var pair=(0,0),baseline=0.0,targetBaseline=0.0
        for i in representatives.indices {for j in representatives.indices where j>i {
            let d=representatives[j].point-representatives[i].point
            let distance=hypot(d.x,d.z),known=hypot(targets[j].east-targets[i].east,targets[j].north-targets[i].north)
            guard distance>0.001,known>0.001 else {throw PCControlFailure.duplicate}
            // UUID tie break is stable if UI assignment order changes.
            let key=[representatives[i].pointID.uuidString,representatives[j].pointID.uuidString].sorted().joined()
            let previous=[representatives[pair.0].pointID.uuidString,representatives[pair.1].pointID.uuidString].sorted().joined()
            if distance>baseline || (distance==baseline && key<previous) {pair=(i,j);baseline=distance;targetBaseline=known}
        }}
        if representatives.count>1 {
            guard baseline>=0.5,targetBaseline>=0.5 else {throw PCControlFailure.degenerate}
        }
        if !localOnly,representatives[pair.0].time>representatives[pair.1].time {pair=(pair.1,pair.0)}
        let anchor:Sample
        if localOnly {
            guard let first=samples.first(where:{explicitGroups.contains(proposal.representative(for:$0.pointID)) && (grouped[proposal.representative(for:$0.pointID)]?.count ?? 0)>=2}) else {throw PCControlFailure.insufficient}
            anchor=first
        } else {anchor=representatives[pair.0]}
        let target=localOnly ? nil:targets[pair.0]
        var yaw=0.0
        if representatives.count>1 {
            let d=representatives[pair.1].point-anchor.point,a=SIMD2(d.x,-d.z)
            let b=SIMD2(targets[pair.1].east-target!.east,targets[pair.1].north-target!.north)
            yaw=atan2(a.x*b.y-a.y*b.x,simd_dot(a,b))
        } else if !localOnly {notes.append("既知GCPは1点。AR軸の向きを保持して並進のみ。絶対方位は未確定です")}
        let height=localOnly ? nil:((proposal.correctsHeight && proposal.reference.hasHeight) ? target?.height:nil)
        if !proposal.correctsHeight {notes.append("水平のみ補正。入力の既知高さは使わず、各フレームの原点群Yを保持します")}
        if localOnly {notes.append(proposal.correctsHeight ? "利用者が同一点と指定した原観測の3軸閉合。最初の観測の補正量を0に固定し、AR軸を保持します。公共座標・標高・絶対方位・絶対精度は得られません":"利用者が同一点と指定した水平閉合。最初の観測の補正量を0に固定し、AR軸と原点群Yを保持します。公共座標・標高・絶対方位・絶対精度は得られません")}
        else if height==nil {notes.append("初期固定点の高さ基準／高さが欠損。鉛直既知拘束は使わず、ZはAR相対高を保持します")}
        let transform=localOnly ? PCControlTransform(yaw:0,localOrigin:GCPVector(),east:0,north:0,height:0):PCControlTransform(yaw:yaw,localOrigin:GCPVector(anchor.point),east:target!.east,north:target!.north,height:height)
        func world(_ point:SIMD3<Double>)->SIMD3<Double> {let q=transform.coordinates(point);return SIMD3(q.east,q.height,q.north)}
        func coefficients(_ time:Double)->[Double] {weights(time:time,autos:autos)}
        var rows=[[Row]](repeating:[],count:3),knownSamples:[(Sample,PCKnownPoint)]=[],relativePairs:[(Sample,Sample)]=[]
        var commonPairs:[(Double,Double)]=[],constraintTimes:[Double]=[],maximumObservationDifference=0.0
        if localOnly {
            for axis in 0..<3 where axis != 1 || proposal.correctsHeight {rows[axis].append(Row(coefficients:coefficients(anchor.time),value:0,time:anchor.time))}
            constraintTimes.append(anchor.time)
        }
        for sample in samples {
            try work?.check()
            guard let i=proposal.bindings.firstIndex(where:{$0.gcpID==proposal.representative(for:sample.pointID)}) else {continue}
            let known=targets[i],q=world(sample.point),difference=SIMD3(known.east-q.x,(height != nil ? known.height.map{$0-q.y}:nil) ?? 0,known.north-q.z)
            guard difference.x.isFinite,difference.y.isFinite,difference.z.isFinite else {throw PCControlFailure.invalid}
            maximumObservationDifference=max(maximumObservationDifference,simd_length(difference))
            knownSamples.append((sample,known));constraintTimes+=sample.times
            for t in sample.times {for axis in [0,1,2] where axis != 1 || (height != nil && known.height != nil) {
                rows[axis].append(Row(coefficients:coefficients(t),value:difference[axis],time:t))
            }}
            if sample.times.count==2 {commonPairs.append((sample.times[0],sample.times[1]))}
        }
        // Unmapped repeats supply relative closure constraints, never a fabricated
        // absolute coordinate. A single unbound observation supplies no row.
        let mapped=Set(proposal.bindings.map(\.gcpID));var relativeIDs:[UUID]=[]
        for id in grouped.keys.sorted(by:{$0.uuidString<$1.uuidString}) where !mapped.contains(id) {
            let group=grouped[id]!
            guard group.count>=2 else {notes.append("未対応GCP \(id.uuidString): 単独観測のため拘束なし");continue}
            // Mixed bearing-only relative constraints require a joint ray/point
            // solver; don't approximate a pair's two times as one depth timestamp.
            guard explicitGroups.contains(id) || group.allSatisfy({$0.observations.count==1}) else {notes.append("未対応GCP \(id.uuidString): 二視点を含む相対拘束は今回保留（原観測保持）");continue}
            relativeIDs.append(id);let first=group[0];constraintTimes+=group.flatMap(\.times)
            if explicitGroups.contains(id) {
                for sample in group where sample.times.count==2 {commonPairs.append((sample.times[0],sample.times[1]))}
            }
            for other in group.dropFirst() {
                let d=world(first.point)-world(other.point)
                guard d.x.isFinite,d.y.isFinite,d.z.isFinite else {throw PCControlFailure.invalid}
                maximumObservationDifference=max(maximumObservationDifference,proposal.correctsHeight ? simd_length(d):hypot(d.x,d.z))
                relativePairs.append((first,other))
                for time in other.times {
                    let a=zip(coefficients(time),coefficients(first.time)).map(-)
                    for axis in [0,1,2] where axis != 1 || (proposal.correctsHeight && (height != nil || localOnly)) {rows[axis].append(Row(coefficients:a,value:d[axis],time:time,fromTime:first.time))}
                }
            }
        }
        guard let firstTime=constraintTimes.min(),let lastTime=constraintTimes.max() else {throw PCControlFailure.insufficient}
        // A two-ray point requires a common translation at both exposures. Add
        // equality as a high-weight observation and verify the actual difference.
        for (a,b) in commonPairs {for axis in 0..<3 where !rows[axis].isEmpty {
            let c=zip(coefficients(a),coefficients(b)).map{($0-$1)*1000}
            rows[axis].append(Row(coefficients:c,value:0,time:b,fromTime:a))
        }}
        var values=try (0..<3).map {axis in
            try work?.check()
            // Horizontal-only never introduces a vertical unknown. In particular,
            // zero two-ray equality rows outside the saved time span cannot make
            // an otherwise-unused vertical system singular.
            if axis==1 && !proposal.correctsHeight {return [Double](repeating:0,count:autos.count)}
            let times=rows[axis].flatMap{[$0.time]+($0.fromTime.map{[$0]} ?? [])}
            return try solve(rows:rows[axis],autos:autos,bounds:(times.min() ?? firstTime,times.max() ?? lastTime),work:work)
        }
        if localOnly {
            // All remaining equations are differences: removing this constant
            // gives an exact zero gauge without changing any closure constraint.
            let anchorWeights=coefficients(anchor.time)
            for axis in 0..<3 {
                let shift=zip(values[axis],anchorWeights).reduce(0){$0+$1.0*$1.1}
                values[axis]=values[axis].map{$0-shift}
            }
        }
        var autoOffsets:[UUID:GCPVector]=[:]
        for i in autos.indices {
            let east=values[0][i],up=values[1][i],north=values[2][i]
            autoOffsets[autos[i].id]=GCPVector(cos(yaw)*east+sin(yaw)*north,up,sin(yaw)*east-cos(yaw)*north)
        }
        var offsets:[UUID:GCPVector]=[:]
        for entry in record.frames {offsets[entry.id]=GCPVector(try offset(time:entry.frame.time,record:record,offsets:autoOffsets))}
        func corrected(_ sample:Sample)throws->SIMD3<Double> {
            if sample.observations.count==1 {return sample.point+(try offset(time:sample.time,record:record,offsets:offsets))}
            var a=sample.observations[0],b=sample.observations[1]
            a.pose.position=GCPVector(a.pose.position.v+(try offset(time:a.time,record:record,offsets:offsets)))
            b.pose.position=GCPVector(b.pose.position.v+(try offset(time:b.time,record:record,offsets:offsets)))
            a.captureEvidence=nil;b.captureEvidence=nil
            return try GCPMath.triangulate(a,b).position.v
        }
        func residual(_ sample:Sample,_ target:PCKnownPoint,_ point:SIMD3<Double>)->PCControlResidual {
            let q=transform.coordinates(point)
            return PCControlResidual(gcpID:sample.pointID,targetID:target.id,deltaNorth:q.north-target.north,deltaEast:q.east-target.east,deltaHeight:height != nil ? target.height.map{q.height-$0}:nil)
        }
        var observed=try knownSamples.map {sample,target in PCFrameControlObservation(gcpID:sample.pointID,targetID:target.id,observationIDs:sample.observations.map(\.id),times:sample.times,before:residual(sample,target,sample.point),after:residual(sample,target,try corrected(sample)))}
        if proposal.hasSamePointGroups {
            for id in relativeIDs where localOnly || explicitGroups.contains(id) {
                let group=grouped[id]!,first=group[0],correctedFirst=try corrected(first)
                func relativeResidual(_ sample:Sample,point:SIMD3<Double>,reference:SIMD3<Double>)->PCControlResidual {
                    let delta=world(point)-world(reference)
                    return PCControlResidual(gcpID:sample.pointID,targetID:id,deltaNorth:delta.z,deltaEast:delta.x,deltaHeight:proposal.correctsHeight && (localOnly || height != nil) ? delta.y:nil)
                }
                for sample in group {
                    observed.append(PCFrameControlObservation(gcpID:sample.pointID,targetID:id,observationIDs:sample.observations.map(\.id),times:sample.times,before:relativeResidual(sample,point:sample.point,reference:first.point),after:relativeResidual(sample,point:try corrected(sample),reference:correctedFirst),relative:true))
                }
            }
            observed.sort{$0.times[0]==$1.times[0] ? $0.id.uuidString<$1.id.uuidString:$0.times[0]<$1.times[0]}
        }
        let residuals: [PCControlResidual]
        if localOnly {residuals=relativeIDs.compactMap{id in observed.first{$0.targetID==id}?.after}}
        else {residuals=representatives.map {sample in observed.first{$0.id==sample.observations[0].id}!.after}}
        var relativeMax=0.0,rayDifference=0.0
        for (a,b) in relativePairs {let delta=try corrected(a)-corrected(b);relativeMax=max(relativeMax,!proposal.correctsHeight || (height==nil && !localOnly) ? hypot(delta.x,delta.z):simd_length(delta))}
        for (a,b) in commonPairs {rayDifference=max(rayDifference,simd_distance(try offset(time:a,record:record,offsets:offsets),try offset(time:b,record:record,offsets:offsets)))}
        if !commonPairs.isEmpty {notes.append("二視点は各時刻に同じ並進を拘束。15秒以内・交会品質・補正差5mm以内を確認。フレーム別回転は推定しません")}
        notes.append("拘束間は自動フレーム番号の滑らかさを仮定。外側は端の補正量を保持（補間区間・端保持区間とも独立精度は未検証）")
        let frame=PCFrameControlResult(epoch:epoch,anchorGCP:anchor.pointID,directionGCP:representatives.count>1 ? representatives[pair.1].pointID:nil,yawResolved:representatives.count>1,targetBaseline:targetBaseline,offsets:offsets,observations:observed,relativeGCPs:relativeIDs,relativeMaxResidual:relativeMax,firstConstraintTime:firstTime,lastConstraintTime:lastTime,maxTranslation:offsets.values.map{simd_length($0.v)}.max() ?? 0,maximumRayOffsetDifference:rayDifference,notes:notes,localOnly:localOnly ? true:nil,maximumObservationDifference:maximumObservationDifference>2 ? maximumObservationDifference:nil)
        return PCControlSolution(sourceDigest:try PCControlMath.digest(record,corrected:false,heightMode:proposal.heightMode),transform:transform,residuals:residuals,before:nil,baselineMetres:baseline,frameCorrection:frame)
    }
}
