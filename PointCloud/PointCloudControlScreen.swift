import SwiftUI

struct PCControlScreen:View {
    @ObservedObject var model:PCController
    var existing:[PCExistingCoordinate]=[]
    @Environment(\.dismiss) private var dismiss
    @State private var proposal=PCControlProposal()
    @State private var solution:PCControlSolution?
    @State private var status=""
    @State private var initialized=false
    @State private var showImport=false
    @State private var importFileFirst=false
    @State private var coordinateSetName=""
    @State private var pendingCoordinateSet:PCCoordinateSet?
    @StateObject private var coordinateLibrary:PCCoordinateReuseModel
    @State private var selectedGCP:GCPPoint?
    @State private var groupUndo:PCControlProposal?
    @State private var showQualityConfirmation=false
    private var busy:Bool {model.phase != .ready}
    init(model:PCController,existing:[PCExistingCoordinate]=[]) {
        self.model=model;self.existing=existing
        _coordinateLibrary=StateObject(wrappedValue:PCCoordinateReuseModel(root:model.store.root.deletingLastPathComponent().appendingPathComponent("PointCloudCoordinateSets",isDirectory:true)))
    }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    if !proposal.hasSamePointGroups { Picker("補正方法",selection:Binding(get:{proposal.method ?? .global},set:{groupUndo=nil;proposal.method=$0;proposal.driftCorrected=($0 == .global && model.corrected);proposal.baseline=nil})) {
                        ForEach(PCControlMethod.allCases,id:\.self){Text($0.label).tag($0)}
                    }} else {Text("同一点グループを使ったフレーム補正")}
                    Picker("高さの補正",selection:Binding(get:{proposal.heightMode ?? .useAvailable},set:{groupUndo=nil;proposal.heightMode=$0;proposal.baseline=nil})) {
                        Text("高さも補正").tag(PCControlHeightMode.useAvailable)
                        Text("水平のみ").tag(PCControlHeightMode.horizontalOnly)
                    }.pickerStyle(.segmented).accessibilityIdentifier("gcp.heightMode")
                    if !proposal.correctsHeight {
                        Text(proposal.driftCorrected && !proposal.usesFrames ? "入力Zは使わず、内部補正後の相対高を保持します。座標対応による高さ補正は加えません。":"入力Zは使わず、元点群のAR相対高を保持します。標高への変換はしません。").font(.caption)
                    }
                    Text("同じ実物の点を測ったGCPをまとめられます。座標はグループに1点分だけ指定し、座標なしでも相対補正できます。原観測・時刻は保持します。")
                    if proposal.isLocalClosure {
                        Text("既知座標なし：最初の観測を基準に、同一点への戻りのずれをフレームへ配分します。AR軸の向きは固定し、公共座標や絶対方位には整合しません。").font(.caption)
                    } else if proposal.usesFrames {
                        Text("生観測の最遠2点で初期位置と向きを決め、全観測時刻のずれを自動フレームへ配分します。前後は端の補正量を保持。従来の内部補正は重ねません。").font(.caption)
                        Text("GCP1点の場合は並進のみで、方位は未確定です。補正中の回転変化は推定しません。").font(.caption)
                    } else {
                        Text(proposal.driftCorrected ? "内部のフレーム補正 → 座標変換の順です":"未補正の原点群 → 座標変換の順です").font(.caption)
                        Text("同じGCPは原登録観測を使って1組として計算します。").font(.caption)
                    }
                }
                Section("座標データ") {coordinateInputs}
                Section("同じ点の指定") {
                    if model.gcps.count<2 {Text("別々に登録されたGCPが2点以上あると同一点を指定できます。").font(.caption)}
                    ForEach(groupRepresentatives,id:\.self) {id in
                        HStack {
                            Text(groupName(id));Spacer()
                            Menu {
                                ForEach(groupRepresentatives.filter{$0 != id},id:\.self) {other in
                                    Button("\(groupName(other)) と同じ点") {merge(id,into:other)}
                                }
                                if proposal.memberIDs(for:id).count>1 {
                                    Button("グループを解除（座標はG\(model.gcpNumber(id) ?? 0)に残る）") {
                                        groupUndo=proposal;proposal=proposal.ungroupingSamePoints(representativeID:id)
                                    }
                                }
                            } label:{Label("同一点",systemImage:"link").frame(minWidth:70,minHeight:44)}
                            .accessibilityLabel(groupName(id)+"の同一点指定")
                            .disabled(model.gcps.count<2)
                        }
                    }
                    if let previous=groupUndo {
                        Button("直前の同一点指定を戻す",systemImage:"arrow.uturn.backward"){proposal=previous;groupUndo=nil}
                    }
                    Text("番号が異なっていても、同じ実物の点を測った場合だけ指定します。距離からは自動でまとめません。解除しても各観測は残ります。").font(.caption)
                }
                if proposal.isLocalClosure {
                    Section {DisclosureGroup("既知座標も指定する（任意）") {referenceControls;coordinateRows}}
                } else {
                    Section("入力座標の基準") {referenceControls}
                    Section("GCP・同一点グループ → 座標点") {coordinateRows}
                }
                Section {
                    Button("対応を計算する",action:calculate).disabled(!canCalculate)
                    if let solution {resultView(solution)}
                    if !status.isEmpty {Text(status).font(.callout).foregroundStyle(.orange)}
                    if busy {ProgressView(model.message);Button("処理を取り消す",action:model.cancelWork)}
                }
                Section {
                    Button("適用してモデル表示",action:requestApply).disabled(solution.map{$0.canApply(qualityOverride:true)} != true)
                        .accessibilityIdentifier("gcp.applyControl")
                    if model.record?.control?.applied==true,model.record?.control?.qualityOverride==true {
                        Text("現在の保存結果は、残差を確認して適用した補正です。").font(.caption).foregroundStyle(.orange)
                    }
                    Button("対応を保存（補正は適用しない）") {save(apply:false)}
                    if model.record?.control?.applied==true {
                        Button("適用を取り消す") {
                            guard let previous=model.record?.control else {return}
                            model.saveControl(previous.proposal,solution:nil,apply:false){ok in if ok{dismiss()}else{status=model.message}}
                        }
                    }
                    Text("保存時に対応表・参照座標のコピー・変換・残差を記録します。入力元が後で変わっても自動更新しません。適用取消も履歴に残り、元観測は保持されます。").font(.caption)
                }
            }
            .disabled(busy || model.controlNeedsReload || coordinateLibrary.busy)
            .navigationTitle("同じ点・座標の関連付け").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button("閉じる"){dismiss()}.disabled(busy || coordinateLibrary.busy)}
                if model.controlNeedsReload {ToolbarItem(placement:.primaryAction){Button("再読込"){model.reloadControlAfterFailure();dismiss()}}}
                if busy {ToolbarItem(placement:.primaryAction){Button("取消",action:model.cancelWork)}}
                else if coordinateLibrary.busy {ToolbarItem(placement:.primaryAction){Button("取消",action:coordinateLibrary.cancel)}}
            }
            .interactiveDismissDisabled(busy || coordinateLibrary.busy)
            .onAppear {
                guard !initialized else{return};initialized=true
                proposal=model.record?.control?.proposal ?? PCControlProposal()
                coordinateSetName=proposal.coordinateSetName ?? ""
                proposal.driftCorrected=proposal.usesFrames ? false:model.corrected
                if !proposal.usesFrames,let current=model.coordinateSolution,let state=model.record?.control {
                    proposal.baseline=PCControlBaseline(reference:state.proposal.reference,sourceDigest:current.sourceDigest,transform:current.transform)
                }
                // Copy only this already-confirmed saved proposal, never scan or
                // migrate every point-cloud record to populate the library.
                if model.record?.control != nil,proposal.reference.valid,!proposal.targets.isEmpty {
                    let name=rememberedCoordinateName(points:proposal.targets)
                    coordinateLibrary.remember(name:name,reference:proposal.reference,points:proposal.targets)
                } else {coordinateLibrary.refresh()}
            }
            .onChange(of:proposal){old,new in
                var a=old,b=new;a.coordinateSetName=nil;b.coordinateSetName=nil
                if a != b {solution=nil;status="";showQualityConfirmation=false}
            }
            .onChange(of:coordinateSetName){_,value in
                let limited=String(value.prefix(128))
                if limited != value {coordinateSetName=limited}
                let clean=limited.trimmingCharacters(in:.whitespacesAndNewlines)
                proposal.coordinateSetName=clean.isEmpty ? nil:clean
                if var previous=groupUndo {previous.coordinateSetName=proposal.coordinateSetName;groupUndo=previous}
            }
            .alert(pendingCoordinateSet == nil ? "この補正結果を適用しますか？":"座標セットを置き換えますか？",isPresented:Binding(get:{showQualityConfirmation || pendingCoordinateSet != nil},set:{if !$0 {showQualityConfirmation=false;pendingCoordinateSet=nil}})) {
                if let set=pendingCoordinateSet {
                    Button("置き換えて対応を解除") {applyCoordinateSet(set);pendingCoordinateSet=nil}
                    Button("取消",role:.cancel){pendingCoordinateSet=nil}
                } else {
                    Button("残差を確認して適用") {save(apply:true,qualityOverride:true)}
                    Button("取消",role:.cancel){}
                }
            } message: {
                if let set=pendingCoordinateSet {
                    Text("\(set.summary.name)・\(set.points.count)点へ変更し、現在のGCPと座標点の対応\(proposal.bindings.count)件を解除します。元点群と保存済み結果は保持し、新しい対応は再計算後に適用します。")
                } else if let solution {
                    Text("水平RMS \(metric(solution.rmsHorizontal))／最大 \(metric(solution.maxHorizontal))\n"+solution.qualityWarnings.joined(separator:"\n")+"\n元データを残し、この結果を補正として適用します。")
                }
            }
            .sheet(isPresented:$showImport){PCControlImportScreen(existing:existing,reference:proposal.reference,existingTargets:proposal.targets,openFileOnAppear:importFileFirst,allowsReferenceEditing:proposal.targets.isEmpty,onReferenceChange:{proposal.reference=$0}){points in
                let remaining=Set(points.map(\.id))
                proposal.bindings.removeAll{!remaining.contains($0.targetID)}
                proposal.targets=points;solution=nil;groupUndo=nil
                let name=rememberedCoordinateName(points:points)
                coordinateLibrary.remember(name:name,reference:proposal.reference,points:points)
            }}
            .sheet(item:$selectedGCP){gcp in
                PCKnownPointPicker(title:groupName(proposal.representative(for:gcp.id))+" の座標点",points:proposal.targets,current:proposal.bindings.first{$0.gcpID==proposal.representative(for:gcp.id)}?.targetID){target in
                    let id=proposal.representative(for:gcp.id)
                    proposal.bindings.removeAll{$0.gcpID==id}
                    if let target {proposal.bindings.append(PCControlBinding(gcpID:id,targetID:target))}
                    groupUndo=nil
                    selectedGCP=nil
                }
            }
        }
    }
    private var groupRepresentatives:[UUID] {model.gcps.map(\.id).filter{proposal.representative(for:$0)==$0}}
    private var canCalculate:Bool {
        proposal.isLocalClosure || (proposal.reference.valid && proposal.bindings.count >= (proposal.usesFrames ? 1:2))
    }
    private func groupName(_ id:UUID)->String {
        proposal.memberIDs(for:id).sorted{(model.gcpNumber($0) ?? 0)<(model.gcpNumber($1) ?? 0)}
            .map{"G\(model.gcpNumber($0) ?? 0)"}.joined(separator:"・")
    }
    private func merge(_ from:UUID,into target:UUID) {
        guard let record=model.record else{return}
        do {let updated=try proposal.mergingSamePoints(from:from,into:target,record:record);groupUndo=proposal;proposal=updated}
        catch {status=error.localizedDescription}
    }
    @ViewBuilder private var referenceControls:some View {
                    Picker("平面直角の系番号",selection:referenceField(\.planeSystem)){ForEach(1...19,id:\.self){Text("\($0)系").tag($0)}}
                    Picker("測地系",selection:referenceField(\.datum)){ForEach(["未確認","JGD2011","JGD2000","任意座標"],id:\.self){Text($0)}}
                    Picker("高さ基準",selection:referenceField(\.height)){ForEach(["未確認","標高","楕円体高","任意高"],id:\.self){Text($0)}}
                    Toggle("入力元の基準を確認しました",isOn:Binding(get:{proposal.reference.confirmed},set:{groupUndo=nil;proposal.reference.confirmed=$0}))
                    Text("X=北、Y=東、m。数値から基準は推定しません。異なる測地系を混在させないでください。高さ未確認／空欄の値は標高合わせに使いません。").font(.caption)
    }
    @ViewBuilder private var coordinateRows:some View {
        if model.gcps.isEmpty {Text("この記録にはGCPがありません。ローカルPLY出力はそのまま使えます。")}
        ForEach(groupRepresentatives,id:\.self) {id in
            Button {selectedGCP=model.gcps.first{$0.id==id}} label:{
                HStack {Text(groupName(id));Spacer();Text(targetName(id)).foregroundStyle(.secondary)}
            }
        }
        Text("入力点 \(proposal.targets.count) ／座標対応 \(proposal.bindings.count)。同一点グループに座標は1点分です。向きを合わせるには別の地点にある2グループ以上が必要です。").font(.caption)
    }
    @ViewBuilder private var coordinateInputs:some View {
        Button {importFileFirst=true;showImport=true} label:{
            Label("座標ファイルを読み込む",systemImage:"doc.badge.plus").frame(maxWidth:.infinity,minHeight:44)
        }.buttonStyle(.borderedProminent).accessibilityIdentifier("gcp.importCoordinateFile")
        if proposal.reference.datum=="任意座標" {
            TextField("現場・座標セット名（任意）",text:$coordinateSetName).accessibilityIdentifier("gcp.coordinateSetName")
            Text("別の現場は名前を分けてください。同じ現場かは自動判定しません。空欄なら入力元のファイル名を使います。").font(.caption)
        }
        if coordinateLibrary.busy {ProgressView("座標セットを確認・保存中")}
        if let error=coordinateLibrary.error {Text(error).font(.caption).foregroundStyle(.orange)}
        let usable=coordinateLibrary.sets.filter(\.isUsable),recent=Array(usable.prefix(3)),recentIDs=Set(recent.map(\.id))
        if !recent.isEmpty {
            Text("最近使った座標").font(.caption).foregroundStyle(.secondary)
            ForEach(recent){set in coordinateSetButton(set)}
        }
        let others=coordinateLibrary.sets.filter{!recentIDs.contains($0.id)}
        if !others.isEmpty {
            DisclosureGroup("保存した座標セット（\(coordinateLibrary.sets.count)件）") {
                ForEach(others){set in coordinateSetButton(set)}
            }
        }
        Button("座標を追加",systemImage:"plus"){importFileFirst=false;showImport=true}.disabled(!proposal.reference.valid)
            .accessibilityIdentifier("gcp.addCoordinates")
    }
    private func coordinateSetButton(_ set:PCCoordinateSetSummary)->some View {
        Button {coordinateLibrary.load(set.id){selected in if let selected {selectCoordinateSet(selected)}}} label:{
            VStack(alignment:.leading,spacing:3) {
                Text(set.name)
                Text(set.isUsable ? "\(set.pointCount)点・"+set.reference.label:set.status).font(.caption).foregroundStyle(set.isUsable ? Color.secondary:.orange)
            }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
        }.disabled(!set.isUsable)
            .accessibilityIdentifier("gcp.reuseCoordinateSet."+set.id.uuidString)
    }
    @discardableResult private func rememberedCoordinateName(points:[PCKnownPoint])->String {
        let name=PCCoordinateReuseModel.resolvedName(coordinateSetName,points:points)
        coordinateSetName=name;proposal.coordinateSetName=name
        return name
    }
    private func selectCoordinateSet(_ set:PCCoordinateSet) {
        // Reusing numerically identical points need not replace their IDs and
        // erase existing assignments. This is equality, never a spatial GCP match.
        let sameLocalName=proposal.reference.datum != "任意座標" || PCCoordinateReuseModel.resolvedName(coordinateSetName,points:proposal.targets)==set.summary.name.precomposedStringWithCanonicalMapping
        if sameLocalName,proposal.reference==set.summary.reference,PCCoordinateReuseModel.sameCoordinates(proposal.targets,set.points) {
            coordinateSetName=set.summary.name;proposal.coordinateSetName=set.summary.name
            coordinateLibrary.markUsed(set.summary.id);return
        }
        if !proposal.bindings.isEmpty {pendingCoordinateSet=set}
        else {applyCoordinateSet(set)}
    }
    private func applyCoordinateSet(_ set:PCCoordinateSet) {
        coordinateSetName=set.summary.name;proposal.coordinateSetName=set.summary.name
        proposal.reference=set.summary.reference;proposal.targets=set.points
        proposal.bindings=[];proposal.baseline=nil
        solution=nil;groupUndo=nil
        coordinateLibrary.markUsed(set.summary.id)
    }
    private func targetName(_ gcp:UUID)->String {
        guard let id=proposal.bindings.first(where:{$0.gcpID==gcp})?.targetID,let p=proposal.targets.first(where:{$0.id==id}) else {return "未指定"}
        return p.name+"（"+p.source+"）"
    }
    private func referenceField<T>(_ key:WritableKeyPath<PCControlReference,T>)->Binding<T> {
        Binding(get:{proposal.reference[keyPath:key]},set:{groupUndo=nil;proposal.reference[keyPath:key]=$0;proposal.reference.confirmed=false})
    }
    private func calculate() {
        solution=nil;status=""
        model.evaluateControl(proposal){result in switch result {
        case .success(let fit):solution=fit
        case .failure(let e):status=(e as? GCPFailure).map{PCMessage.input(.core($0))} ?? PCMessage.error(e)
        }}
    }
    private func requestApply() {
        guard let solution,solution.structurallyValid else {return}
        if solution.canApply {save(apply:true)}
        else if solution.canApply(qualityOverride:true) {showQualityConfirmation=true}
        else {status="この計算結果は適用できません。対応点と原観測を確認してください。"}
    }
    private func save(apply:Bool,qualityOverride:Bool=false) {
        let savedName=proposal.targets.isEmpty ? coordinateSetName:rememberedCoordinateName(points:proposal.targets)
        let savedProposal=proposal
        model.saveControl(proposal,solution:apply ? solution:nil,apply:apply,qualityOverride:qualityOverride){ok in
            guard ok else {status=model.message;return}
            coordinateLibrary.remember(name:savedName,reference:savedProposal.reference,points:savedProposal.targets){saved in
                if saved {dismiss()}
                else {status="この記録への保存は完了しました。座標セットの再利用用保存は未完了です。"}
            }
        }
    }
    @ViewBuilder private func resultView(_ fit:PCControlSolution)->some View {
        if let frames=fit.frameCorrection {frameResult(fit,frames)} else {
            Text("使用 \(fit.residuals.count) 点／高さ有効 \(fit.heightCount) 点")
            summaryTable(fit)
            PCControlResultTable(columns:[
                .init("GCP",width:90),.init("対応点",width:140),
                .init("ΔX 北 (m)",number:true),.init("ΔY 東 (m)",number:true),
                .init(proposal.correctsHeight ? "ΔZ (m)":"ΔZ 対象外",number:true),
                .init("水平残差 (m)",number:true),.init("3D残差 (m)",number:true)
            ],rows:fit.residuals.map {r in
                .init(id:r.id.uuidString,values:[groupName(r.gcpID),proposal.targets.first{$0.id==r.targetID}?.name ?? "不明",value(r.deltaNorth),value(r.deltaEast),value(r.deltaHeight),value(r.horizontal),value(r.spatial)])
            }).accessibilityIdentifier("gcp.residualsTable")
            if let before=fit.before {
                Text("再計算前の残差（比較可能な同一基準のみ）").font(.caption)
                PCControlResultTable(columns:[.init("GCP",width:90),.init("水平残差 (m)",number:true),.init("3D残差 (m)",number:true)],rows:before.map {r in
                    .init(id:r.id.uuidString,values:[groupName(r.gcpID),value(r.horizontal),value(r.spatial)])
                })
            }
            Text("残差は計算座標−既知座標。小さくても絶対精度の保証ではありません。最少2点だけでは誤対応を検出できない場合があります。補正に使わない独立点でも確認してください。").font(.caption)
            if fit.before==nil {Text("補正前の誤差は表示しません。ローカル座標と既知座標は直接比較できません。").font(.caption)}
            qualityNotice(fit)
            heightNotice(fit)
        }
    }
    @ViewBuilder private func frameResult(_ fit:PCControlSolution,_ result:PCFrameControlResult)->some View {
        if result.localOnly==true {
            Text("同一点の相対補正・ローカルAR座標（既知座標なし）")
            Text("元のAR軸と最初の観測位置を基準にします。補正後の差は同一点指定への適合度で、測量精度ではありません。").font(.caption)
        } else {
            Text(result.yawResolved ? "初期固定 G\(model.gcpNumber(result.anchorGCP) ?? 0) → 方向 G\(result.directionGCP.flatMap{model.gcpNumber($0)} ?? 0)":"1点並進・方位未確定（公共座標への整合完了ではありません）")
            Text("生基線 \(metric(fit.baselineMetres))／既知基線 \(metric(result.targetBaseline))・初期角 \(fit.transform.yaw*180 / .pi, specifier:"%.3f")°（AR軸基準）").font(.caption)
        }
        Text("既知拘束 \(result.observations.filter{$0.relative != true}.count) 観測組／相対拘束 \(result.observations.filter{$0.relative==true}.count) 観測組・\(result.relativeGCPs.count) 点／最大補正 \(metric(result.maxTranslation))").font(.caption)
        summaryTable(fit)
        let local=result.localOnly==true
        PCControlResultTable(columns:[
            .init("GCP",width:90),.init("観測時刻 (s)",width:145),.init("対応・拘束",width:140),
            .init(local ? "補正前水平 (m)":"初期合わせ後 水平 (m)",number:true),
            .init(local ? "AR X (m)":"ΔX 北 (m)",number:true),
            .init(local ? (proposal.correctsHeight ? "AR Y 上 (m)":"AR Y 対象外"):"ΔY 東 (m)",number:true),
            .init(local ? "AR Z (m)":(proposal.correctsHeight ? "ΔZ (m)":"ΔZ 対象外"),number:true),
            .init("補正後水平 (m)",number:true),.init("補正後3D (m)",number:true)
        ],rows:Array(result.observations.prefix(200)).map {row in
            .init(id:row.id.uuidString,values:[
                groupName(row.gcpID),row.times.map{String(format:"%.2f",$0)}.joined(separator:" / "),
                row.relative==true ? "同一点間の相対差":(proposal.targets.first{$0.id==row.targetID}?.name ?? "不明"),
                value(row.before.horizontal),value(local ? row.after.deltaEast:row.after.deltaNorth),
                local ? value(row.after.deltaHeight):value(row.after.deltaEast),
                local ? value(-row.after.deltaNorth):value(row.after.deltaHeight),
                value(row.after.horizontal),value(row.after.spatial)
            ])
        }).accessibilityIdentifier("gcp.frameResidualsTable")
        if result.observations.count>200 {Text("先頭200観測を表示。全観測の残差は計算結果に保存します。").font(.caption)}
        ForEach(result.notes,id:\.self){note in Text(model.gcps.reduce(note){$0.replacingOccurrences(of:$1.id.uuidString,with:"G\(model.gcpNumber($1.id) ?? 0)")}).font(.caption)}
        Text("補正後残差は拘束への適合度です。小さくても精度保証にはなりません。補正に使わない独立点でも確認してください。").font(.caption)
        qualityNotice(fit)
        heightNotice(fit)
    }
    private func summaryTable(_ fit:PCControlSolution)->some View {
        let maximumHeight=fit.evaluatedResiduals.compactMap(\.deltaHeight).map{abs($0)}.max()
        let heightLabel=proposal.correctsHeight ? "高さ":"高さ（対象外）"
        return PCControlResultTable(columns:[.init("評価方向",width:130),.init("RMS (m)",number:true),.init("最大残差 (m)",number:true),.init("使用数",width:75,number:true)],rows:[
            .init(id:"horizontal",values:["水平",value(fit.rmsHorizontal),value(fit.maxHorizontal),String(fit.evaluatedResiduals.count)]),
            .init(id:"height",values:[heightLabel,value(fit.rmsHeight),value(maximumHeight),fit.heightCount>0 ? String(fit.heightCount):"—"]),
            .init(id:"spatial",values:[proposal.correctsHeight ? "3D":"3D（対象外）",value(fit.rms3D),value(fit.max3D),fit.heightCount>0 ? String(fit.heightCount):"—"])
        ]).accessibilityIdentifier("gcp.residualSummaryTable")
    }
    @ViewBuilder private func qualityNotice(_ fit:PCControlSolution)->some View {
        if !fit.structurallyValid {
            Text("計算結果の整合性を確認できないため適用できません。対応点と原観測を確認してください。").foregroundStyle(.orange)
        } else if !fit.canApply,fit.canApply(qualityOverride:true) {
            ForEach(fit.qualityWarnings,id:\.self){warning in Text(warning).foregroundStyle(.orange)}
            Text("残差を確認したうえで「適用してモデル表示」から適用できます。原データは保持します。").font(.caption)
        } else if !fit.canApply {
            Text("この観測条件では適用できません。対応点と原観測を確認してください。").foregroundStyle(.orange)
        }
    }
    @ViewBuilder private func heightNotice(_ fit:PCControlSolution)->some View {
        if !proposal.correctsHeight {
            Text(fit.frameCorrection?.localOnly==true ? "水平のみの補正です。高さ残差・3D残差は評価せず、出力Yは保持したAR相対高です。":"水平のみの補正です。高さ残差・3D残差は評価せず、出力Zは保持した相対高です。").font(.caption)
        } else if fit.heightCount==0 {
            Text("高さは未整合です。変換済みPLYのZもAR相対高で、標高ではありません。").foregroundStyle(.orange)
        }
    }
    private func value(_ value:Double?)->String {value.map{String(format:"%.4f",$0)} ?? "—"}

    private func metric(_ value:Double?)->String {value.map{String(format:"%.4f m",$0)} ?? "未評価"}
}

/// The coordinate library is independent of a scan. Operations are bounded,
/// serial and asynchronous; immutable sets never include GCP assignments.
@MainActor private final class PCCoordinateReuseModel:ObservableObject {
    @Published private(set) var sets:[PCCoordinateSetSummary]=[]
    @Published private(set) var busy=false
    @Published private(set) var error:String?
    private let library:PCCoordinateLibrary
    private let queue=DispatchQueue(label:"point-cloud-coordinate-library",qos:.utility)
    private var control:PCWorkControl?
    private var operationID:UUID?
    init(root:URL){library=PCCoordinateLibrary(root:root)}
    func cancel() {
        guard busy else {return}
        control?.cancel();operationID=nil;control=nil;busy=false
        error="座標セットの処理を取り消しました。既に保存が完了している場合は、画面を開き直すと確認できます。"
    }
    private func perform<T>(_ operation:@escaping(PCCoordinateLibrary,PCWorkControl)throws->T,completion:@escaping(Result<T,Error>)->Void) {
        guard !busy else {completion(.failure(PCFailure.interrupted));return}
        busy=true;error=nil
        let library=library,work=PCWorkControl(),token=UUID();control=work;operationID=token
        queue.async {
            let result=Result{try operation(library,work)}
            DispatchQueue.main.async { [weak self] in
                guard let self,self.operationID==token else {return}
                // The result may have waited on main after a successful read.
                // Never apply it after cancellation/deadline or clear a newer job.
                let delivered:Result<T,Error>
                do {try work.check();delivered=result} catch {delivered = .failure(error)}
                self.busy=false;self.control=nil;self.operationID=nil
                if case .failure(let e)=delivered {self.error="座標セットの確認・保存が未完了です："+PCMessage.error(e)+"。保存済みの場合は画面を開き直して確認できます。"}
                completion(delivered)
            }
        }
    }
    func refresh() {perform({try $0.list(control:$1)}){[weak self] result in if case .success(let sets)=result {self?.sets=sets}}}
    func load(_ id:UUID,completion:@escaping(PCCoordinateSet?)->Void) {
        perform({try $0.load(id,control:$1)}){result in completion(try? result.get())}
    }
    func remember(name:String="",reference:PCControlReference,points:[PCKnownPoint],completion:@escaping(Bool)->Void={_ in}) {
        guard reference.valid,!points.isEmpty else {completion(true);return}
        perform({library,work in
            _=try library.save(name:name,reference:reference,points:points,control:work)
            return try? library.list(control:work)
        }){[weak self] result in
            switch result {
            case .success(let sets):if let sets {self?.sets=sets} else {self?.error="座標セットは保存済みですが一覧の更新は未完了です。画面を開き直して確認できます。"};completion(true)
            case .failure:completion(false)
            }
        }
    }
    func markUsed(_ id:UUID) {
        perform({library,work in _=try library.touch(id,control:work);return try library.list(control:work)}){[weak self] result in if case .success(let sets)=result {self?.sets=sets}}
    }
    static func resolvedName(_ supplied:String,points:[PCKnownPoint])->String {
        let name=supplied.trimmingCharacters(in:.whitespacesAndNewlines)
        let sourceValue=points.first?.source.components(separatedBy:" / ").first ?? ""
        let source=sourceValue.isEmpty ? "":URL(fileURLWithPath:sourceValue).lastPathComponent
        return String((name.isEmpty ? (source.isEmpty ? "座標セット":source):name).prefix(128)).precomposedStringWithCanonicalMapping
    }
    private struct Key:Hashable {var name:String;var north:Double;var east:Double;var height:Double?;var system:Int}
    static func sameCoordinates(_ a:[PCKnownPoint],_ b:[PCKnownPoint])->Bool {
        guard a.count==b.count else {return false}
        func keys(_ values:[PCKnownPoint])->[Key:Int] {
            values.reduce(into:[:]){result,p in result[Key(name:p.name,north:p.north,east:p.east,height:p.height,system:p.planeSystem),default:0]+=1}
        }
        return keys(a)==keys(b)
    }
}

/// Fixed columns remain readable on a narrow phone by horizontal scrolling.
/// Each cell carries its header for VoiceOver; missing values stay unmeasured.
private struct PCControlResultTable:View {
    struct Column {var title:String;var width:CGFloat;var number:Bool
        init(_ title:String,width:CGFloat=115,number:Bool=false){self.title=title;self.width=width;self.number=number}
    }
    struct Row:Identifiable {var id:String;var values:[String]}
    var columns:[Column]
    var rows:[Row]
    var body:some View {
        ScrollView(.horizontal,showsIndicators:true) {
            LazyVStack(alignment:.leading,spacing:0) {
                HStack(spacing:0) {
                    ForEach(Array(columns.enumerated()),id:\.offset) {_,column in
                        Text(column.title).font(.caption.bold()).frame(width:column.width,alignment:column.number ? .trailing:.leading).padding(.horizontal,8).padding(.vertical,9)
                    }
                }.background(Color.secondary.opacity(0.13))
                ForEach(Array(rows.enumerated()),id:\.element.id) {index,row in
                    HStack(spacing:0) {
                        ForEach(Array(columns.enumerated()),id:\.offset) {columnIndex,column in
                            let value=row.values.indices.contains(columnIndex) ? row.values[columnIndex]:"—"
                            Text(value).font(.caption).monospacedDigit().lineLimit(3)
                                .frame(width:column.width,alignment:column.number ? .trailing:.leading).frame(minHeight:32)
                                .padding(.horizontal,8).padding(.vertical,5)
                                .accessibilityLabel(column.title+"："+value)
                        }
                    }.background(index.isMultiple(of:2) ? Color.secondary.opacity(0.04):Color.clear)
                        .accessibilityElement(children:.combine)
                }
            }
        }.accessibilityHint("横にスクロールしてすべての列を確認できます")
    }
}
struct PCKnownPointPicker:View {
    var title:String
    var points:[PCKnownPoint]
    var current:UUID?
    var completion:(UUID?)->Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var search=""
    @State private var listMode=false
    @State private var selectedID:UUID?
    @State private var planeSystem:Int
    private var systems:[Int] {Array(Set(points.map(\.planeSystem))).sorted()}
    private var filtered:[PCKnownPoint] {points.filter{$0.planeSystem==planeSystem && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search))}}
    private var selected:PCKnownPoint? {
        let matches=points.filter{$0.id==selectedID}
        return matches.count==1 && matches[0].finite ? matches[0]:nil
    }
    init(title:String="座標点を選択",points:[PCKnownPoint],current:UUID?,completion:@escaping(UUID?)->Void) {
        self.title=title;self.points=points;self.current=current;self.completion=completion
        _selectedID=State(initialValue:current)
        _planeSystem=State(initialValue:points.first{$0.id==current}?.planeSystem ?? points.first?.planeSystem ?? 9)
    }
    var body:some View {
        NavigationStack {
            GeometryReader {available in VStack(spacing:8) {
                Picker("表示",selection:$listMode) {Text("平面図").tag(false);Text("一覧").tag(true)}
                    .pickerStyle(.segmented).padding(.horizontal)
                    .accessibilityIdentifier("gcp.knownPointMode")
                if systems.count>1 {
                    Picker("平面直角の系番号",selection:$planeSystem) {
                        ForEach(systems,id:\.self) {Text("\($0)系").tag($0)}
                    }.padding(.horizontal).accessibilityIdentifier("gcp.knownPointSystem")
                } else if !points.isEmpty {Text("\(planeSystem)系・X=北 / Y=東・m").font(.caption)}
                if listMode {pointList}
                else {
                    ScrollView {
                    PCKnownPointPlan(points:filtered,selectedID:$selectedID)
                        .id(search+"|\(planeSystem)")
                        .frame(height:max(verticalSizeClass == .compact ? 140:220,available.size.height-100))
                    }
                }
            }}
            .safeAreaInset(edge:.bottom,spacing:0) {selectionControls}
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .searchable(text:$search,prompt:"点名・入力元を検索")
            .onChange(of:planeSystem) {_,_ in selectedID=nil}
            .toolbar {ToolbarItem(placement:.cancellationAction) {Button("閉じる") {dismiss()}}}
        }
    }
    private var pointList:some View {
        List {
            Text("\(filtered.count) 件（先頭200件。検索で絞れます）").font(.caption)
            ForEach(Array(filtered.prefix(200))){p in
                Button {selectedID=p.id} label:{
                    HStack {
                        VStack(alignment:.leading) {
                            Text(p.name)
                            Text("\(p.source)\nX \(p.north) / Y \(p.east) / H \(p.height.map{String($0)} ?? "欠損") / \(p.planeSystem)系").font(.caption)
                        }
                        Spacer(minLength:4)
                        if p.id==selectedID {Image(systemName:"checkmark.circle.fill")}
                    }
                }.disabled(!p.finite)
            }
        }.accessibilityIdentifier("gcp.knownPointList")
    }
    private var selectionControls:some View {
        VStack(alignment:.leading,spacing:8) {
            if let point=selected {
                Text(point.name).font(.headline).lineLimit(1).accessibilityIdentifier("gcp.currentKnownPoint")
                Text("\(point.source)・\(point.planeSystem)系\nX 北 \(point.north, specifier:"%.4f") / Y 東 \(point.east, specifier:"%.4f") / H \(point.height.map{String(format:"%.4f",$0)} ?? "欠損") m")
                    .font(.caption).monospacedDigit().lineLimit(verticalSizeClass == .compact ? 1:3)
            }
            HStack {
                Button("未指定に戻す") {completion(nil)}.buttonStyle(.bordered).frame(minHeight:44).lineLimit(1)
                Spacer(minLength:4)
                Button("この座標を適用") {if let selected {completion(selected.id)}}
                    .buttonStyle(.borderedProminent).frame(minHeight:44).disabled(selected==nil)
                    .lineLimit(1)
                    .accessibilityIdentifier("gcp.applyKnownPoint")
            }
        }.padding().background(.regularMaterial)
    }
}

private struct PCPlanGestureState {
    var zoom:CGFloat=1
    var translation:CGSize = .zero
}
private struct PCPlanCandidates:Identifiable {
    let id=UUID()
    let points:[PCKnownPoint]
}
/// Local Canvas only: no basemap, network requests or coordinate conversion.
private struct PCKnownPointPlan:View {
    var points:[PCKnownPoint]
    @Binding var selectedID:UUID?
    @State private var viewport:PCPlanViewport?
    @State private var candidates:PCPlanCandidates?
    @GestureState private var motion=PCPlanGestureState()
    // Coordinate input is already limited to 5,000 points. Cap only unexpected
    // historical catalogues visibly; selection always uses drawn markers.
    private let renderLimit=6_000
    private var valid:[PCKnownPoint] {points.filter(\.finite)}
    private var mapPoints:[PCPlanPoint] {valid.map{PCPlanPoint(id:$0.id,north:$0.north,east:$0.east)}}
    var body:some View {
        GeometryReader {proxy in
            let size=proxy.size
            let origin=viewport ?? PCPlanViewport.fit(mapPoints,width:Double(size.width),height:Double(size.height))
            let view=origin?.transformed(zoom:Double(motion.zoom),dx:Double(motion.translation.width),dy:Double(motion.translation.height))
            let visible=visiblePoints(in:view,size:size)
            ZStack(alignment:.topLeading) {
                Color(uiColor:.secondarySystemBackground)
                Canvas {context,canvas in
                    guard let view else {return}
                    var axes=Path()
                    axes.move(to:CGPoint(x:canvas.width/2,y:0));axes.addLine(to:CGPoint(x:canvas.width/2,y:canvas.height))
                    axes.move(to:CGPoint(x:0,y:canvas.height/2));axes.addLine(to:CGPoint(x:canvas.width,y:canvas.height/2))
                    context.stroke(axes,with:.color(.secondary.opacity(0.2)),lineWidth:1)
                    var dots=Path()
                    for item in visible {
                        guard let p=screen(item,view:view,size:canvas) else {continue}
                        dots.addEllipse(in:CGRect(x:p.x-3.5,y:p.y-3.5,width:7,height:7))
                    }
                    context.fill(dots,with:.color(.primary))
                    if visible.count<=35 {
                        for item in visible {
                            guard let p=screen(item,view:view,size:canvas) else {continue}
                            context.draw(Text(String(item.name.prefix(24))).font(.caption2).foregroundStyle(.primary),at:CGPoint(x:p.x+7,y:p.y-9),anchor:.leading)
                        }
                    }
                    if let selected=visible.first(where:{$0.id==selectedID}),let p=screen(selected,view:view,size:canvas) {
                        let ring=Path(ellipseIn:CGRect(x:p.x-10,y:p.y-10,width:20,height:20))
                        context.stroke(ring,with:.color(.blue),lineWidth:3)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:8).simultaneously(with:MagnifyGesture())
                    .updating($motion){value,state,_ in
                        state.translation=value.first?.translation ?? .zero
                        state.zoom=value.second?.magnification ?? 1
                    }
                    .onEnded {value in
                        viewport=origin?.transformed(zoom:Double(value.second?.magnification ?? 1),dx:Double(value.first?.translation.width ?? 0),dy:Double(value.first?.translation.height ?? 0))
                    })
                .simultaneousGesture(SpatialTapGesture().onEnded {value in
                    guard let view else {return}
                    select(at:value.location,view:view,size:size,visible:visible)
                })
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("座標平面図、北が上・東が右、表示\(visible.count)点")
                .accessibilityHint("点を選んで適用します。VoiceOverでは上の一覧表示から点名を選べます")
                .accessibilityIdentifier("gcp.knownPointPlanCanvas")
                VStack(alignment:.leading,spacing:4) {
                    HStack {Text("北 X ↑");Spacer();Text("東 Y →")}
                    Text("表示 \(visible.count) / \(valid.count) 点").font(.caption2)
                    if valid.count != points.count {Text("座標を確認できない\(points.count-valid.count)点は平面図に表示できません").font(.caption2).foregroundStyle(.orange)}
                    if visible.count>=renderLimit {Text("表示上限\(renderLimit)点・拡大または検索してから選択してください").font(.caption2).foregroundStyle(.orange)}
                }.font(.caption.weight(.semibold)).padding(8).allowsHitTesting(false)
                if mapPoints.isEmpty {ContentUnavailableView("座標点がありません",systemImage:"point.topleft.down.curvedto.point.bottomright.up")}
                VStack {Spacer();HStack {
                    if let view {Text("画面100pt = \(view.metresPerPoint*100, specifier:"%.3f") m").font(.caption2).padding(5).background(.regularMaterial,in:RoundedRectangle(cornerRadius:5))}
                    Spacer(minLength:0)
                    HStack(spacing:4) {
                        Button {viewport=origin?.transformed(zoom:0.5)} label:{Image(systemName:"minus.magnifyingglass").frame(width:44,height:44)}.accessibilityLabel("縮小")
                        Button {viewport=origin?.transformed(zoom:2)} label:{Image(systemName:"plus.magnifyingglass").frame(width:44,height:44)}.accessibilityLabel("拡大")
                        Button {viewport=PCPlanViewport.fit(mapPoints,width:Double(size.width),height:Double(size.height))} label:{Image(systemName:"arrow.up.left.and.arrow.down.right").frame(width:44,height:44)}.accessibilityLabel("すべての座標点を表示")
                    }.buttonStyle(.bordered).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))
                }.padding(8)}
            }.clipped()
                .sheet(item:$candidates){candidate in
                    NavigationStack {
                        List(candidate.points){point in
                            Button {selectedID=point.id;candidates=nil} label:{
                                VStack(alignment:.leading) {
                                    Text(point.name)
                                    Text("\(point.source)・\(point.planeSystem)系\nX \(point.north, specifier:"%.4f") / Y \(point.east, specifier:"%.4f") / H \(point.height.map{String(format:"%.4f",$0)} ?? "欠損")").font(.caption)
                                }
                            }
                        }.navigationTitle("近くの点 \(candidate.points.count)件").navigationBarTitleDisplayMode(.inline)
                            .toolbar {ToolbarItem(placement:.cancellationAction) {Button("閉じる"){candidates=nil}}}
                    }
                }
        }
    }
    private func visiblePoints(in view:PCPlanViewport?,size:CGSize)->[PCKnownPoint] {
        guard let view else {return []}
        var result:[PCKnownPoint]=[]
        for point in valid {
            guard let p=screen(point,view:view,size:size),p.x>=0,p.y>=0,p.x<=size.width,p.y<=size.height else {continue}
            if result.count<renderLimit {result.append(point)}
        }
        return result
    }
    private func screen(_ point:PCKnownPoint,view:PCPlanViewport,size:CGSize)->CGPoint? {
        view.screen(PCPlanPoint(id:point.id,north:point.north,east:point.east),width:Double(size.width),height:Double(size.height)).map{CGPoint(x:$0.x,y:$0.y)}
    }
    private func select(at tap:CGPoint,view:PCPlanViewport,size:CGSize,visible:[PCKnownPoint]) {
        // Do not overlook an undisplayed coincident candidate in unexpected
        // historical catalogues larger than the supported input bound.
        guard visible.count<renderLimit else {return}
        let ids=view.candidates(visible.map{PCPlanPoint(id:$0.id,north:$0.north,east:$0.east)},at:PCPlanScreenPoint(x:Double(tap.x),y:Double(tap.y)),width:Double(size.width),height:Double(size.height))
        guard !ids.isEmpty else {return}
        let idsSet=Set(ids),matches=visible.filter{idsSet.contains($0.id)}
        if matches.count==1 {selectedID=matches[0].id}
        else {candidates=PCPlanCandidates(points:matches)}
    }
}
