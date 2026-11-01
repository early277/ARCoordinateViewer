import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PCScreen:View {
    var initialRecordID:UUID? = nil
    var knownCandidates:[PCExistingCoordinate]=[]
    @State private var didOpenInitial=false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model=PCController()
    @StateObject private var torch=PCTorchControl()
    @State private var showFolder=false
    @State private var showRecords=false
    @State private var showControl=false
    @State private var exportCoordinates=false
    private var isStoppedPreview:Bool {model.phase == .review || model.phase == .ready}
    private var statusText:String? {
        if isStoppedPreview {return model.previewNotice ?? (model.historical ? nil:model.resumeBlockedReason)}
        return model.message.isEmpty ? nil:model.message
    }
    var body:some View {
        NavigationStack {
            ZStack {
                PCLiveView(model:model,torch:torch,torchAllowed:scenePhase == .active && !showFolder && !showRecords && !showControl)
                    .ignoresSafeArea().onTapGesture {model.captureManual()}
                VStack {
                    if model.phase == .recording,model.pendingGCPRay != nil {
                        Text("第一視線を表示中・横に移動して同じ点を指定／戻すで取消").font(.caption).padding(8).background(.black.opacity(0.85)).foregroundStyle(.yellow)
                    }
                    if let statusText {Text(statusText).font(.subheadline).padding(10).background(.black.opacity(0.75)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius:10))}
                    if let record=model.record,!record.warnings.isEmpty {
                        Text(record.warnings.joined(separator:" / ")).font(.caption).foregroundStyle(.yellow).padding(8).background(.black.opacity(0.8))
                    }
                    if isStoppedPreview,!model.controlNeedsReload,model.savedCount>0,model.detailPreview==nil {
                        Text("全点表示は未完了です").font(.caption).foregroundStyle(.yellow).padding(8).background(.black.opacity(0.8))
                    }
                    if isStoppedPreview,let page=model.previewPageDescription,let detail=model.detailPreview {
                        HStack {
                            Button {model.changePreviewPage(-1)} label:{Image(systemName:"chevron.left").frame(minWidth:44,minHeight:44)}.disabled(detail.page==0)
                            Text(page).font(.caption2).foregroundStyle(.white)
                            Button {model.changePreviewPage(1)} label:{Image(systemName:"chevron.right").frame(minWidth:44,minHeight:44)}.disabled(detail.page+1>=detail.pageCount)
                        }.buttonStyle(.borderedProminent).padding(4).background(.black.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius:10))
                    }
                    if model.waiting>0 {Text("保存待ち \(model.waiting) 枚").foregroundStyle(.white)}
                    Spacer()
                    if model.savedCount>0 && !isStoppedPreview {
                        Text("保存点 \(model.savedCount) ／表示 \(model.displayedCount) 点\n"+(model.detailPreview != nil ? "保存点を全点表示・空白は未取得":(model.phase == .recording ? "取得済み範囲の軽量表示・保存点は全て保持":"全点表示は未完了・表示数を確認してください"))+"\n透視表示／PLYは保存点すべて").font(.caption2).foregroundStyle(.white).padding(5).background(.black.opacity(0.7))
                    }
                    if !model.controlNeedsReload && (model.phase == .review || model.phase == .ready) {
                        VStack(spacing:6) {
                            HStack {
                                Button("モデル表示") {model.setModelView(true)}.disabled(model.showingModel)
                                Button("AR表示") {model.setModelView(false)}.disabled(!model.showingModel || !model.canReturnToAR)
                                Button {model.resume()} label: {Label("再開",systemImage:"record.circle").frame(minHeight:44)}
                                    .disabled(!model.canResume)
                                    .accessibilityHint(model.resumeBlockedReason ?? (model.historical ? "保存記録からは再開できません":"同じ追跡状態を維持している場合に追記します"))
                            }.buttonStyle(.borderedProminent).tint(.blue)
                        }.padding(8).background(.black.opacity(0.78)).clipShape(RoundedRectangle(cornerRadius:12))
                    }
                    controls.padding().background(.black.opacity(0.78)).clipShape(RoundedRectangle(cornerRadius:20))
                }.padding()
            }
            .navigationTitle("色付き点群・試作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.canClose {ToolbarItem(placement:.topBarLeading){Button("閉じる"){dismiss()}}}
                if model.phase == .idle {ToolbarItem(placement:.topBarTrailing){Button("保存した点群"){showRecords=true}}}
                if torch.cameraActive || torch.isOn {
                    ToolbarItem(placement:.topBarTrailing) {
                        Button(action:torch.toggle) {
                            Image(systemName:torch.isOn ? "flashlight.on.fill":"flashlight.off.fill")
                                .font(.title3).foregroundStyle(torch.isOn ? .yellow:.white)
                                .frame(width:44,height:44).background(.black.opacity(0.65),in:Circle())
                        }.buttonStyle(.plain).disabled(!torch.canToggle)
                            .accessibilityLabel(torch.isOn ? "ライトを消す":"ライトをつける")
                            .accessibilityValue(torch.isOn ? "点灯":"消灯")
                            .accessibilityHint(torch.available ? "カメラのライトを手動で切り替えます":"現在のカメラではライトを利用できません")
                    }
                }
                if model.phase == .ready && !model.controlNeedsReload {ToolbarItem(placement:.topBarLeading){Button("補正／生データ"){model.backToChoice()}}}
            }
            .interactiveDismissDisabled(!model.canClose)
            .sheet(isPresented:$showFolder) {PCFolderPicker {url in showFolder=false;if let url {model.export(to:url,knownCoordinates:exportCoordinates)} else {model.message="保存先の選択を取り消しました。原記録は保持されています";model.previewNotice=model.message}}}
            .sheet(isPresented:$showRecords) {PCGalleryScreen(knownCandidates:knownCandidates)}
            .sheet(isPresented:$showControl) {PCControlScreen(model:model,existing:knownCandidates)}
            .onAppear {if !didOpenInitial {didOpenInitial=true;if let initialRecordID {model.open(initialRecordID)}}}
            .alert("ライト",isPresented:Binding(get:{torch.errorMessage != nil},set:{if !$0 {torch.errorMessage=nil}})) {
                Button("OK",role:.cancel){torch.errorMessage=nil}
            } message: {Text(torch.errorMessage ?? "")}
            .onDisappear {torch.setCameraActive(false)}
            .onChange(of:scenePhase) {_,value in if value != .active {torch.setCameraActive(false);model.interrupted()} else {model.becameActive()}}
        }
    }
    @ViewBuilder private var controls:some View {
        switch model.phase {
        case .idle,.recording:
            HStack(alignment:.top,spacing:8) {
                Button(action:{if model.phase == .recording {model.stop()} else {model.begin()}}) {
                    VStack(spacing:4) {
                        Image(systemName:model.phase == .recording ? "stop.fill":"record.circle")
                        Text(model.phase == .recording ? "停止":"開始")
                    }.font(.headline).frame(maxWidth:.infinity,minHeight:56)
                }.buttonStyle(.borderedProminent).tint(model.phase == .recording ? .red:.blue)
                VStack(spacing:2) {
                    Button(action:model.recordGCP){VStack(spacing:4){Image(systemName:"scope");Text("GCP記録")}.font(.headline).frame(maxWidth:.infinity,minHeight:56)}
                        .buttonStyle(.borderedProminent).tint(.blue).disabled(model.phase != .recording || model.input.hasPendingRequest || model.posePulsePending)
                    Menu {
                        Button("深度の点") {model.setGCPMode(.depthPoint)}
                        Button("2視点の視線") {model.setGCPMode(.twoRays)}
                    } label: {
                        Label(model.gcpMode == .twoRays ? "2視点の視線":"深度の点",systemImage:"chevron.down").font(.caption).foregroundStyle(.white).frame(minHeight:44)
                    }.accessibilityLabel("GCP取得方式："+(model.gcpMode == .twoRays ? "2視点の視線":"深度の点"))
                }.frame(maxWidth:.infinity)
                Button(action:model.undoGCP) {
                    VStack(spacing:4){Image(systemName:"arrow.uturn.backward");Text("戻す")}.font(.headline).frame(maxWidth:.infinity,minHeight:56)
                }.buttonStyle(.borderedProminent).tint(.blue).disabled(!model.canUndoGCP)
            }
        case .review:
            VStack {
                HStack {
                    Button(model.record?.checkpoint?.poseEvents?.isEmpty==false ? "推定急変・GCPで補正":"補正する"){model.choose(correct:true)}.buttonStyle(.borderedProminent)
                    Button("生データを残す"){model.choose(correct:false)}.buttonStyle(.borderedProminent)
                }
                if model.detailPreview == nil && model.savedCount>0 {
                    Button("全点表示を再読込",action:model.retryPreview).font(.caption)
                }
            }
        case .ready:
            if model.controlNeedsReload {
                Button("保存結果を再読込",action:model.reloadControlAfterFailure).buttonStyle(.borderedProminent)
            } else { VStack {
                Button {showControl=true} label: {
                    Label("同じ点・座標を関連付ける",systemImage:"link")
                        .frame(maxWidth:.infinity,minHeight:44)
                }.font(.headline).buttonStyle(.borderedProminent).tint(.blue).foregroundStyle(.white)
                if model.coordinateSolution != nil {
                    Button(model.coordinateSolution?.frameCorrection?.localOnly==true ? "同一点補正済みPLY出力":(model.coordinateSolution?.frameCorrection?.yawResolved==false ? "並進のみPLY（方位未確定）":"座標変換済みPLY出力"),systemImage:"folder"){exportCoordinates=true;showFolder=true}.font(.title2.bold()).buttonStyle(.borderedProminent).disabled(!model.canExport)
                }
                Button(model.corrected ? "ローカル補正済みPLY出力":"ローカル未補正PLY出力",systemImage:"folder"){exportCoordinates=false;showFolder=true}.font(model.coordinateSolution == nil ? .title2.bold():.body).buttonStyle(.borderedProminent).disabled(!model.canExport)
            }}
        case .starting,.saving:
            ProgressView(model.phase == .starting ? "準備中":"受理済み入力を保存中").tint(.white).foregroundStyle(.white)
        case .processing,.exporting:
            VStack {
                if model.phase == .exporting || model.detailLoading {ProgressView(value:model.progress)} else {ProgressView().tint(.white)}
                Button("取消",action:model.cancelWork).disabled(!model.canCancel)
            }
        case .failed:
            Button("保存を再試行",action:model.retrySave).buttonStyle(.borderedProminent)
        }
    }
}
struct PCFolderPicker:UIViewControllerRepresentable {
    var completion:(URL?)->Void
    func makeCoordinator()->Coordinator{Coordinator(completion)}
    func makeUIViewController(context:Context)->UIDocumentPickerViewController {
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:[.folder],asCopy:false)
        picker.allowsMultipleSelection=false;picker.delegate=context.coordinator;return picker
    }
    func updateUIViewController(_ uiViewController:UIDocumentPickerViewController,context:Context){}
    final class Coordinator:NSObject,UIDocumentPickerDelegate {
        var completion:(URL?)->Void;private var finished=false
        init(_ completion:@escaping(URL?)->Void){self.completion=completion}
        private func finish(_ url:URL?){guard !finished else {return};finished=true;completion(url)}
        func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]){finish(urls.first)}
        func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController){finish(nil)}
    }
}

/// Browsing never starts an AR session. Metadata and bounded thumbnail samples
/// load asynchronously; opening a record uses the same offline model view.
struct PCGalleryScreen:View {
    var knownCandidates:[PCExistingCoordinate]=[]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model=PCController()
    @State private var selected:PCSavedRecord?
    @State private var pendingDeletion:PCSavedRecord?
    init(knownCandidates:[PCExistingCoordinate]=[],controller:PCController?=nil) {
        self.knownCandidates=knownCandidates
        _model=StateObject(wrappedValue:controller ?? PCController())
    }
    var body:some View {
        NavigationStack {
            List {
                Text("点群は停止時にアプリ内へ保存されます。PLY出力は任意です。サムネイルは軽量な抜粋表示です。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.recordsLoading {ProgressView("保存記録を確認中")}
                else if let error=model.recordsError {Text(error+"。表示中の一覧は前回取得した内容です").foregroundStyle(.orange)}
                else if model.savedRecords.isEmpty {Text("保存した点群はありません")}
                if let notice=model.deletionMessage {Text(notice).font(.callout).accessibilityIdentifier("pointCloud.deleteStatus")}
                if model.deletingRecordID != nil {ProgressView("点群を削除中")}
                ForEach(model.savedRecords) {item in
                    Button {if item.state == .deletionPending {pendingDeletion=item} else {selected=item}} label:{
                        HStack {
                            PCThumbnailView(value:model.thumbnails[item.id]).frame(width:88,height:88).clipShape(RoundedRectangle(cornerRadius:8))
                            VStack(alignment:.leading,spacing:4) {
                                if let date=item.date {Text(date,format:.dateTime.year().month().day().hour().minute())}
                                else {Text("保存日時不明")}
                                if item.state == .unreadable || item.state == .deletionPending {Text("点数・GCP件数は未確認").font(.subheadline)}
                                else {Text("\(item.pointCount) 点・GCP \(item.gcpCount)").font(.subheadline)}
                                Text(item.storedBytes.map{ "内部データ " + ByteCountFormatter.string(fromByteCount:$0,countStyle:.file) } ?? "内部データ容量：確認できません")
                                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("pointCloud.recordSize."+item.id.uuidString)
                                Text(item.status).font(.caption).foregroundStyle(item.state == .saved ? Color.secondary:.orange)
                                if let error=model.thumbnailErrors[item.id] {Text(error).font(.caption2).foregroundStyle(.secondary)}
                                Text(String(item.id.uuidString.prefix(8))).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain).task(id:item.thumbnailKey){model.loadThumbnail(item)}
                        .accessibilityIdentifier("pointCloud.record."+item.id.uuidString)
                        .disabled(model.deletingRecordID != nil)
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            // Do not use destructive role until confirmation;
                            // cancelling must leave the row visibly unchanged.
                            Button {pendingDeletion=item} label:{Label(item.state == .deletionPending ? "削除を再実行":"削除",systemImage:"trash")}
                                .tint(.red).disabled(model.deletionBlockedReason(item.id) != nil)
                                .accessibilityIdentifier("pointCloud.delete."+item.id.uuidString)
                        }
                        .contextMenu {
                            Button {pendingDeletion=item} label:{Label("削除",systemImage:"trash")}
                                .disabled(model.deletionBlockedReason(item.id) != nil)
                        }
                }
            }
            .navigationTitle("保存した点群")
            .toolbar {ToolbarItem(placement:.cancellationAction){Button("閉じる"){dismiss()}.disabled(model.deletingRecordID != nil)}}
            .interactiveDismissDisabled(model.deletingRecordID != nil)
            .refreshable{model.discover()}
            .alert("この点群を完全に削除しますか？",isPresented:Binding(get:{pendingDeletion != nil},set:{if !$0 {pendingDeletion=nil}})) {
                if let item=pendingDeletion {
                    Button("点群を完全に削除",role:.destructive) {model.deleteRecord(item.id);pendingDeletion=nil}
                        .disabled(model.deletionBlockedReason(item.id) != nil)
                    Button("取消",role:.cancel){pendingDeletion=nil}
                }
            } message: {
                if let item=pendingDeletion {
                    Text("対象 \(item.id.uuidString.prefix(8))。この記録の原点群・画像・GCP・補正情報を削除します。元に戻せません。外部へ出力したPLY、他の点群、樹木記録は残ります。")
                }
            }
            .onAppear{model.discover()}
            .fullScreenCover(item:$selected,onDismiss:model.discover) {item in PCScreen(initialRecordID:item.id,knownCandidates:knownCandidates)}
        }
    }
}
struct PCThumbnailView:View {
    var value:PCThumbnail?
    var body:some View {
        ZStack {
            Color.black
            if let value,!value.dots.isEmpty {
                Canvas {context,size in
                    for p in value.dots {
                        let box=CGRect(x:CGFloat(p.x)*size.width-1,y:CGFloat(p.y)*size.height-1,width:2,height:2)
                        // SwiftUI colour objects are managed sRGB; do not apply
                        // the SceneKit vertex-buffer decode here a second time.
                        context.fill(Path(ellipseIn:box),with:.color(Color(.sRGB,red:Double(p.r)/255,green:Double(p.g)/255,blue:Double(p.b)/255)))
                    }
                }
            } else {Image(systemName:"circle.hexagongrid").foregroundStyle(.gray).accessibilityLabel("サムネイル未生成。記録は開けます")}
        }.allowsHitTesting(false)
    }
}
