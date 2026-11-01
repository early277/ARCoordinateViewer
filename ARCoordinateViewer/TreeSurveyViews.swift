import SwiftUI
import UIKit

extension TreeColor {
    var uiColor: UIColor {
        switch self {
        case .red:return .systemRed
        case .yellow:return .systemYellow
        case .white:return .white
        case .blue:return .systemBlue
        case .pink:return .systemPink
        case .cyan:return .cyan
        }
    }
}

/// Explicit action contrast: AR overlays inherit a white tint, which must never
/// become a white prominent-button background with a white foreground.
private struct TreePrimaryActionStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.body.weight(.semibold))
            .padding(.horizontal,12).frame(minHeight:44)
            .foregroundStyle(Color.white)
            .background(configuration.role == .destructive ? Color(red:0.66,green:0.10,blue:0.12):Color(red:0.08,green:0.28,blue:0.64),in:RoundedRectangle(cornerRadius:10))
            .opacity(enabled ? (configuration.isPressed ? 0.75:1):0.45)
            .contentShape(RoundedRectangle(cornerRadius:10))
    }
}
private struct TreeSheetStyle:ViewModifier {
    func body(content:Content)->some View {
        content.foregroundStyle(Color.primary).tint(Color.blue)
            .background(Color(uiColor:.systemBackground))
    }
}

private enum TreeOptionsAction {case end,retake,skipHeight,records}

struct TreeSurveyControls:View {
    @ObservedObject var controller:TreeSurveyController
    var collapsible=false
    var start:()->Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var idleExpanded=false
    @State private var optionsPresented=false
    @State private var pendingOption:TreeOptionsAction?
    private var confirm:some View {
        Button {
            if controller.canReviewCircle {controller.reviewCircle()}
            else {controller.requestCenterCapture()}
        } label: {
            Group {
                if controller.capturePending || controller.saving {ProgressView()}
                else {Text(controller.canReviewCircle ? "確認":"確定")}
            }.frame(minWidth:64,minHeight:44)
        }.buttonStyle(TreePrimaryActionStyle())
            .disabled(!(controller.canCapture || controller.canReviewCircle))
            .accessibilityLabel(controller.canReviewCircle ? "測定値を確認して保存へ":controller.confirmTitle)
            .accessibilityIdentifier("tree.confirmCenter")
    }
    private var options:some View {
        Button {optionsPresented=true} label: {Image(systemName:"ellipsis.circle").frame(minWidth:44,minHeight:44)}
            .buttonStyle(DrawingActionStyle())
            .disabled(controller.capturePending || controller.saving)
            .overlay(alignment:.topTrailing) {if !controller.warnings.isEmpty {Image(systemName:"exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)}}
            .accessibilityLabel(controller.warnings.isEmpty ? "樹木調査の設定と一覧":"樹木調査の設定と一覧・保存の確認があります")
            .accessibilityIdentifier("tree.options")
    }
    private var undo:some View {
        Button {controller.undo()} label: {Image(systemName:"arrow.uturn.backward").frame(minWidth:44,minHeight:44)}
            .buttonStyle(DrawingActionStyle()).disabled(!controller.canUndo).accessibilityLabel("一つ戻す").accessibilityIdentifier("tree.undo")
    }
    private var savedRecordsButton:some View {
        Button {controller.openRecords()} label: {
            Label("保存 \(controller.records.count)本",systemImage:"list.bullet")
                .frame(minHeight:44)
        }.buttonStyle(DrawingActionStyle()).disabled(!controller.canOpenRecords)
            .accessibilityLabel("保存した樹木 \(controller.records.count)本を開く")
            .accessibilityIdentifier("tree.savedRecords")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            if controller.active {
                if typeSize.isAccessibilitySize {
                    Text(controller.stageTitle).font(.body.weight(.semibold)).accessibilityLabel(controller.captureHint)
                    HStack {options;Spacer(minLength:4);confirm;undo}
                } else {
                    HStack(spacing:4) {
                        options
                        Text(controller.stageTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                            .frame(maxWidth:.infinity,alignment:.leading).accessibilityLabel(controller.captureHint)
                        confirm;undo
                    }
                }
                HStack(spacing:8) {
                    savedRecordsButton
                    if let notice=controller.savedNotice {Text(notice).font(.caption).lineLimit(2).accessibilityIdentifier("tree.savedNotice")}
                    Spacer(minLength:0)
                }
                if let warning=controller.captureWarning {Text(warning).font(.caption).lineLimit(3).foregroundStyle(.orange)}
            } else {
                HStack(spacing:6) {
                    if collapsible {
                        Button {withAnimation(.easeInOut(duration:0.15)) {idleExpanded.toggle()}} label: {
                            HStack(spacing:4) {
                                Text("樹木調査")
                                Image(systemName:idleExpanded ? "chevron.down":"chevron.up").font(.caption2)
                            }
                        }.buttonStyle(DrawingActionStyle(selected:idleExpanded))
                            .accessibilityIdentifier("tree.toggle")
                            .accessibilityValue(idleExpanded ? "開いています":"閉じています")
                            .accessibilityHint("測定の開始と保存した樹木を表示します")
                    }
                    if !collapsible || idleExpanded {
                        Button(collapsible ? "開始":"樹木調査",action:start).buttonStyle(DrawingActionStyle(selected:false))
                            .disabled(controller.loading || controller.saving).accessibilityIdentifier("tree.start")
                        savedRecordsButton
                    }
                }
            }
            if let warning=controller.displayWarning {Text(warning).font(.caption).foregroundStyle(.orange).lineLimit(3)}
            if !controller.unreadableIDs.isEmpty || !controller.changeHistoryHealthy || controller.changeFailed {
                Button("保存の確認が必要・一覧を開く") {controller.openRecords()}
                    .font(.caption).foregroundStyle(.orange).frame(minHeight:44)
            }
        }.padding(.horizontal,6).padding(.vertical,2)
            .arControlSurface(in:RoundedRectangle(cornerRadius:10))
            .sheet(isPresented:$optionsPresented,onDismiss:{
                guard let action=pendingOption else {return};pendingOption=nil
                switch action {
                case .end:controller.end()
                case .retake:controller.retake()
                case .skipHeight:controller.abandonHeight()
                case .records:controller.openRecords()
                }
            }) {
                TreeSurveyOptionsView(controller:controller) {action in pendingOption=action;optionsPresented=false}
            }
            .sheet(isPresented:Binding(get:{controller.reviewPresented && !controller.recordsPresented},set:{controller.reviewPresented=$0})) {TreeReviewView(controller:controller)}
            .sheet(isPresented:$controller.recordsPresented) {TreeRecordsView(controller:controller)}
    }
}
private struct TreeSurveyOptionsView:View {
    @ObservedObject var controller:TreeSurveyController
    var action:(TreeOptionsAction)->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            List {
                Section("測定") {
                    Text(controller.captureHint)
                    Text(controller.message).font(.callout)
                    if controller.active {
                        if controller.candidate==nil {Button("今の測定を取り直す") {action(.retake)}.buttonStyle(.bordered).frame(minHeight:44).disabled(controller.saving)}
                        if controller.measuringHeight {Button("樹高は未測定で確認する") {action(.skipHeight)}.buttonStyle(.bordered).frame(minHeight:44).disabled(controller.saving)}
                        Button("測定を終了") {action(.end)}.buttonStyle(.bordered).frame(minHeight:44).disabled(controller.saving)
                    }
                }
                Section("記録") {
                    Button {action(.records)} label: {
                        Label("保存した樹木 \(controller.records.count)本／ゴミ箱 \(controller.deletedRecords.count)本",systemImage:"list.bullet")
                            .frame(minHeight:44)
                    }.buttonStyle(.bordered)
                    Text("全削除と復元は一覧から操作できます。点群・GCPは対象外です。").font(.caption).foregroundStyle(.secondary)
                    if controller.canUndoRecordDeletion {Button("直前の削除を元に戻す") {controller.undoRecordDeletion()}.buttonStyle(.bordered).frame(minHeight:44)}
                }
                Section("測り方") {
                    Text("中央の十字線に合わせ、樹皮表面・左端・右端を確定すると直径が表示されます。直径だけ記録するか、さらに下端・上端を確定して樹高も記録できます。表面以外は方向だけを取得します。")
                    Text("高さは幹までの水平距離と、下端・梢の上下角度から計算します。")
                }
                if let frame=controller.frame {Section("座標基準") {Text(frame.description).font(.caption)}}
                if !controller.warnings.isEmpty {Section("保存の確認") {ForEach(controller.warnings,id:\.self) {Text($0)}}}
            }.navigationTitle("樹木調査")
                .toolbar {ToolbarItem(placement:.cancellationAction) {Button("閉じる") {dismiss()}.frame(minHeight:44)}}
        }.modifier(TreeSheetStyle())
    }
}

struct TreeReviewView: View {
    @ObservedObject var controller: TreeSurveyController
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var numberFocused: Bool
    @FocusState private var speciesFocused: Bool
    @State private var confirmDiscard = false
    private let columns=Array(repeating:GridItem(.flexible()),count:3)
    private let speciesColumns=[GridItem(.adaptive(minimum:90),spacing:8)]
    private func endInput() {numberFocused=false;speciesFocused=false}
    private var saveTitle:String {
        if controller.reviewingExisting {return "変更を保存"}
        return controller.candidate?.geometry.height == nil ? "直径だけ記録":"直径・樹高を記録"
    }
    private var actions:some View {
        let layout=typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing:8)):AnyLayout(HStackLayout(spacing:8))
        return layout {
            Button {endInput();controller.save()} label: {
                HStack {if controller.saving {ProgressView()};Text(controller.saving ? "保存中":saveTitle)}
                    .frame(maxWidth:.infinity,minHeight:44)
            }.buttonStyle(TreePrimaryActionStyle()).accessibilityIdentifier("tree.save")
                .disabled(controller.saving || (Int(controller.numberInput).map {$0<0} ?? true))
            if controller.candidate?.geometry.height == nil && controller.canMeasureHeight {
                Button {endInput();controller.beginHeight()} label: {
                    Text("樹高も測る").frame(maxWidth:.infinity,minHeight:44)
                }.buttonStyle(.bordered)
                    .accessibilityIdentifier("tree.height")
            }
        }.padding().background(.regularMaterial)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if let record=controller.candidate {
                        Text(String(format:"直径 %.1f cm",record.geometry.circle.diameter*100)).font(.title2.bold())
                        if let height=record.geometry.height {Text(String(format:"樹高 %.2f m",height.metres))}
                        else {Text("樹高 未測定").foregroundStyle(.secondary)}
                        VStack(alignment:.leading,spacing:8) {
                            Text("樹種").font(.headline)
                            TextField("樹種名（未入力でも記録できます）",text:Binding(get:{controller.speciesInput},set:controller.setSpecies))
                                .textFieldStyle(.roundedBorder).focused($speciesFocused)
                                .accessibilityIdentifier("tree.species")
                            if !controller.recentSpecies.isEmpty {
                                Text("最近使った樹種").font(.caption).foregroundStyle(.secondary)
                                LazyVGrid(columns:speciesColumns,alignment:.leading,spacing:8) {
                                    ForEach(controller.recentSpecies,id:\.self) {name in
                                        Button {endInput();controller.setSpecies(name)} label: {
                                            Text(name).lineLimit(2).frame(maxWidth:.infinity,minHeight:44)
                                        }.buttonStyle(.bordered).accessibilityLabel("樹種を"+name+"にする")
                                    }
                                }
                            }
                        }
                        LazyVGrid(columns:columns,spacing:12) {
                            ForEach(TreeColor.allCases,id:\.self) { color in
                                Button {controller.setColor(color)} label: {
                                    HStack {
                                        Circle().fill(Color(uiColor:color.uiColor)).overlay(Circle().stroke(.gray,lineWidth:1)).frame(width:24,height:24)
                                        Text(color.title)
                                        if controller.color==color {Image(systemName:"checkmark")}
                                    }.foregroundStyle(Color.primary).frame(maxWidth:.infinity,minHeight:44)
                                        .background(controller.color==color ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
                                }.buttonStyle(.plain).contentShape(RoundedRectangle(cornerRadius:8)).accessibilityIdentifier("tree.color.\(color.rawValue)")
                            }
                        }
                        HStack {
                            Text("番号")
                            TextField("番号",text:Binding(get:{controller.numberInput},set:controller.setNumber))
                                .keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($numberFocused)
                                .accessibilityIdentifier("tree.number")
                        }
                        if record.geometry.height != nil && controller.canMeasureHeight {
                            Button("樹高を測り直す") {endInput();controller.beginHeight()}
                                .frame(minHeight:44).accessibilityIdentifier("tree.height")
                        }
                        Text(controller.message).font(.caption).foregroundStyle(controller.saving ? .secondary : .primary)
                    }
                }.padding()
            }.scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge:.bottom) {if controller.candidate != nil {actions}}
                .disabled(controller.saving)
                .navigationTitle("木の記録").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button("取消") {confirmDiscard=true}.disabled(controller.saving || controller.failedSaveHolding)}
                    ToolbarItem(placement:.primaryAction) {Button("一つ戻す") {endInput();controller.undo()}.disabled(!controller.canUndo)}
                    ToolbarItemGroup(placement:.keyboard) {Spacer();Button("入力完了") {endInput()}}
                }
                .confirmationDialog("未保存の入力を取り消しますか？",isPresented:$confirmDiscard,titleVisibility:.visible) {
                    Button("取り消す",role:.destructive) {controller.cancelReview()}
                    Button("入力を保持",role:.cancel) {}
                }
        }.modifier(TreeSheetStyle()).interactiveDismissDisabled().presentationDetents([.medium,.large])
    }
}

private struct TreeDispositionRequest:Identifiable {
    var id=UUID()
    var frameID:UUID
    var surveyCreated:Date
    var kind:TreeRecordChangeKind
    var records:[TreeRecord]
}
struct TreeRecordsView:View {
    @ObservedObject var controller:TreeSurveyController
    @State private var export:URL?
    @State private var exportError:String?
    @State private var showTrash=false
    @State private var selected=Set<UUID>()
    @State private var editing=EditMode.inactive
    @State private var request:TreeDispositionRequest?
    @Environment(\.dismiss) private var dismiss
    private var visible:[TreeRecord] {showTrash ? controller.deletedRecords:controller.records}
    private func ask(_ records:[TreeRecord],kind:TreeRecordChangeKind) {
        guard controller.canChangeRecords,let frame=controller.frame,!records.isEmpty else {return}
        request=TreeDispositionRequest(frameID:frame.id,surveyCreated:frame.created,kind:kind,records:records)
    }
    private func row(_ record:TreeRecord)->some View {
        HStack {
            Circle().fill(Color(uiColor:record.color.uiColor)).overlay(Circle().stroke(.gray,lineWidth:1)).frame(width:18,height:18)
            VStack(alignment:.leading,spacing:2) {
                Text(record.color.title+" "+String(record.number)).foregroundStyle(.primary)
                Text(TreeSpecies.name(record.species) ?? "樹種 未入力").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment:.trailing,spacing:2) {
                Text(String(format:"%.1f cm",record.geometry.circle.diameter*100))
                Text(record.geometry.height.map {String(format:"樹高 %.2f m",$0.metres)} ?? "樹高 未測定").font(.caption)
            }.foregroundStyle(.secondary)
        }.frame(minHeight:44)
    }
    var body:some View {
        NavigationStack {
            List(selection:$selected) {
                Section {
                    Picker("表示",selection:$showTrash) {
                        Text("保存済み \(controller.records.count)本").tag(false)
                        Text("ゴミ箱 \(controller.deletedRecords.count)本").tag(true)
                    }.pickerStyle(.segmented)
                    if let frame=controller.frame {
                        Text("現在の調査："+frame.created.formatted(date:.abbreviated,time:.shortened)).font(.caption)
                    }
                    Text(controller.message).font(.callout)
                    Text("この一覧はアプリ内に保存済みです。CSV出力は任意です。").font(.caption).foregroundStyle(.secondary)
                    if controller.saving {ProgressView("履歴を保存中")}
                    if controller.changeFailed {Button("操作を再試行") {controller.retryRecordChange()}.buttonStyle(.bordered).frame(minHeight:44).disabled(controller.saving)}
                    if controller.canUndoRecordDeletion {Button("直前の削除を元に戻す") {controller.undoRecordDeletion()}.buttonStyle(.bordered).frame(minHeight:44)}
                }
                if !controller.warnings.isEmpty || !controller.unreadableIDs.isEmpty {
                    Section("復旧の確認") {
                        ForEach(controller.warnings,id:\.self) {Text($0).font(.caption)}
                        if !controller.unreadableIDs.isEmpty {Text("\(controller.unreadableIDs.count)件が未読込・元ファイルは保護しています")}
                        Button("再読込") {controller.reload()}.buttonStyle(.bordered).frame(minHeight:44).disabled(controller.saving)
                    }
                }
                Section("樹木の整理") {
                    if !selected.isEmpty {
                        Button(showTrash ? "選択した\(selected.count)本を復元":"選択した\(selected.count)本を削除",role:showTrash ? nil:.destructive) {
                            ask(visible.filter {selected.contains($0.id)},kind:showTrash ? .restore:.delete)
                        }.disabled(!controller.canChangeRecords)
                    }
                    Button(showTrash ? "この調査のゴミ箱をすべて復元":"樹木を全削除（\(visible.count)本）",role:showTrash ? nil:.destructive) {
                        ask(visible,kind:showTrash ? .restore:.delete)
                    }.buttonStyle(.bordered).frame(minHeight:44)
                        .accessibilityIdentifier(showTrash ? "tree.restoreAll":"tree.deleteAll")
                        .disabled(!controller.canChangeRecords || visible.isEmpty)
                    Text("削除してもゴミ箱から復元できます。対象は現在の調査の樹木だけです。点群・GCP・図形・写真は含みません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(showTrash ? "復元できる樹木":"保存した樹木") {
                    if visible.isEmpty {Text(controller.loading ? "読み込み中":(showTrash ? "ゴミ箱は空です":"保存した樹木はありません")).foregroundStyle(.secondary)}
                    ForEach(visible) {record in
                        Group {
                            if !editing.isEditing && !showTrash {
                                Button {controller.edit(record)} label:{HStack {row(record);Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)}}.contentShape(Rectangle()).disabled(controller.candidate != nil || controller.saving)
                            } else {row(record)}
                        }.tag(record.id)
                            .swipeActions {
                                Button(showTrash ? "復元":"削除",role:showTrash ? nil:.destructive) {
                                    ask([record],kind:showTrash ? .restore:.delete)
                                }.disabled(!controller.canChangeRecords)
                            }
                    }
                }
                if let exportError {Text(exportError).foregroundStyle(.red)}
            }.environment(\.editMode,$editing)
                .navigationTitle("樹木の記録")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button("閉じる") {dismiss()}}
                    ToolbarItem(placement:.primaryAction) {
                        Button(editing.isEditing ? "選択完了":"選択") {editing=editing.isEditing ? .inactive:.active;selected=[]}.disabled(!controller.canChangeRecords)
                    }
                    ToolbarItem(placement:.bottomBar) {
                        if let export {ShareLink(item:export) {Text("CSVを共有")}}
                        else {Button("保存済みのCSV") {do {export=try controller.csvURL()} catch {exportError=error.localizedDescription}}}
                    }
                }
                .onChange(of:showTrash) {_,_ in selected=[];editing = .inactive;export=nil}
                .onChange(of:controller.recordsRevision) {_,_ in selected.formIntersection(Set(visible.map(\.id)));export=nil}
                .sheet(isPresented:$controller.reviewPresented) {TreeReviewView(controller:controller)}
                .sheet(item:$request) {value in TreeDispositionReviewView(controller:controller,request:value)}
        }.modifier(TreeSheetStyle())
    }
}
private struct TreeDispositionReviewView:View {
    @ObservedObject var controller:TreeSurveyController
    var request:TreeDispositionRequest
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            List {
                Section {
                    Text(request.kind == .delete ? "\(request.records.count)本をゴミ箱へ移動します":"\(request.records.count)本を復元します").font(.headline)
                    Text("調査開始："+request.surveyCreated.formatted(date:.abbreviated,time:.shortened))
                    Text("対象の色・番号を確認してください。現在の調査の樹木だけに適用します。")
                    if request.kind == .delete {Text("元の記録は保持し、ゴミ箱または「直前の削除を元に戻す」から復元できます。")}
                }
                Section("対象 \(request.records.count)本") {
                    ForEach(request.records) {record in
                        HStack {
                            Circle().fill(Color(uiColor:record.color.uiColor)).overlay(Circle().stroke(.gray,lineWidth:1)).frame(width:18,height:18)
                            Text(record.color.title+" "+String(record.number))
                            Spacer()
                            Text(String(format:"%.1f cm",record.geometry.circle.diameter*100)).foregroundStyle(.secondary)
                        }.frame(minHeight:44)
                    }
                }
            }.navigationTitle(request.kind == .delete ? "削除の確認":"復元の確認")
                .toolbar {ToolbarItem(placement:.cancellationAction) {Button("取消") {dismiss()}}}
                .safeAreaInset(edge:.bottom) {
                    Button(request.kind == .delete ? "\(request.records.count)本をゴミ箱へ移動":"\(request.records.count)本を復元",role:request.kind == .delete ? .destructive:nil) {
                        controller.changeRecords(Set(request.records.map(\.id)),kind:request.kind);dismiss()
                    }.buttonStyle(TreePrimaryActionStyle()).frame(maxWidth:.infinity,minHeight:44).padding()
                        .disabled(!controller.canChangeRecords || controller.frame?.id != request.frameID)
                        .background(.regularMaterial)
                }
        }.modifier(TreeSheetStyle()).interactiveDismissDisabled(controller.saving)
    }
}

struct ARMeasurementCrosshairView: View {
    var body: some View {
        Image(systemName:"plus").font(.system(size:30,weight:.medium))
            .foregroundStyle(.white).shadow(color:.black,radius:1)
            .frame(width:40,height:40).allowsHitTesting(false)
            .accessibilityLabel("画面中央の照準")
    }
}
