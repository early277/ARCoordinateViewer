import SwiftUI
import UIKit

struct ScanCaptureControls:View {
    @ObservedObject var controller:ScanCaptureController
    let supported:Bool
    let start:()->Void
    @State private var records=false
    @State private var details=false
    var body:some View {
        GeometryReader { geometry in
            VStack {
                HStack {
                    VStack(alignment:.leading,spacing:2) {
                        Label("LiDARスキャン（試作）",systemImage:"cube.transparent").font(.headline)
                        Text(ScanPrototypeIdentity().label).font(.caption2)
                    }
                    Spacer()
                    if !controller.isRecording {
                        Button("閉じる") {controller.modeOpen=false}.disabled(controller.preparing || controller.isSaving)
                    }
                }.padding(10).arControlSurface(in:RoundedRectangle(cornerRadius:12))
                Spacer()
                VStack(alignment:.leading,spacing:10) {
                    Text(controller.message).font(.caption).fixedSize(horizontal:false,vertical:true)
                    if let error=controller.error {Text(error).font(.caption).foregroundStyle(.orange)}
                    Text("保存済み画像 \(controller.savedImages)枚 / GCP \(controller.savedPoints)点"+(controller.pendingCount>0 ? "・保存待ち \(controller.pendingCount)件":"")).font(.caption2)
                    if controller.isRecording {
                        Text("水色:保存済み形状　黄:GCP番号").font(.caption2)
                        if let outcome=controller.input.lastOutcome {gcpOutcome(outcome)}
                    }
                    if controller.preparing {
                        if let began=controller.exportStarted {
                            TimelineView(.periodic(from:began,by:1)) {context in
                                VStack(alignment:.leading) {
                                    ProgressView(value:controller.exportFraction)
                                    Text("\(controller.exportStage)・\(max(0,Int(context.date.timeIntervalSince(began))))秒 / 上限120秒").font(.caption)
                                }
                            }
                            Button("出力を取り消す") {controller.cancelExport()}.disabled(!controller.canCancelExport)
                        } else {ProgressView("保存記録を確認中")}
                    }
                    HStack(spacing:12) {
                        Button {if controller.isRecording {controller.stop(reason:"停止")} else {start()}} label: {
                            Label(controller.isRecording ? "停止":"開始",systemImage:controller.isRecording ? "stop.fill":"play.fill").font(.title3.bold()).frame(maxWidth:.infinity,minHeight:52)
                        }.tint(controller.isRecording ? .red:.blue).disabled(!controller.isRecording && (!supported || !controller.canStart))
                        Button {controller.captureGCP(controller.gcpIntent)} label: {
                            Label("GCP記録",systemImage:"scope").font(.title3.bold()).frame(maxWidth:.infinity,minHeight:52)
                        }.disabled(!controller.isRecording)
                    }.buttonStyle(.borderedProminent)
                    if !controller.isRecording {
                        ScrollView {
                            VStack(alignment:.leading,spacing:10) {
                                if !supported {Text("LiDAR対応端末が必要です").font(.caption)}
                                if let reason=controller.exportBlockReason {Text(reason).font(.caption2)}
                                Button {controller.exportTexture(saveToFiles:true)} label: {
                                    Label("テクスチャ付きメッシュを保存",systemImage:"square.and.arrow.up").frame(maxWidth:.infinity,minHeight:44)
                                }.disabled(!controller.canExport).buttonStyle(.borderedProminent).tint(.blue)
                                Text("停止すると自動保存。上のボタンでZIPを作り、Filesの保存先を選びます。灰色面は画像未確認です。").font(.caption2)
                                HStack {
                                    Button("保存記録") {records.toggle();if records {controller.discover()}}.disabled(controller.isSaving || controller.preparing)
                                    Button("新規") {controller.newRecording()}.disabled(controller.isSaving || controller.preparing || controller.filesRequest != nil)
                                    Button(details ? "詳細を閉じる":"詳細") {details.toggle()}
                                }.font(.caption)
                                if records {
                                    if controller.available.isEmpty {Text(controller.preparing ? "確認中":"保存記録なし")}
                                    ForEach(controller.available,id:\.self) {id in
                                        Button("保存記録を開く: "+id.uuidString.prefix(8)) {controller.restore(id);records=false}.disabled(controller.isSaving || controller.preparing)
                                    }
                                }
                                if details {
                                    Toggle("保存済み形状を表示",isOn:$controller.showCoverage)
                                    Text("水色は保存済みの形状です。色のない範囲は未取得・表示省略・別区間の可能性があります。画像貼付の完了ではありません。再開・追跡変更・再起動前の区間は重ねません。").font(.caption2)
                                    Picker("次のGCP記録",selection:$controller.gcpIntent) {
                                        Text("自動判定").tag(GCPCaptureIntent.automatic)
                                        Text("新規のみ").tag(GCPCaptureIntent.register)
                                        Text("再観測のみ").tag(GCPCaptureIntent.reobserve)
                                    }.disabled(controller.preparing)
                                    Text("中央十字線を対象へ。初回は深度が必要です。自動判定で対応が曖昧な点は保留します。").font(.caption2)
                                    HStack {
                                        Button("補正を適用") {controller.applyCorrection()}.disabled(!controller.canApplyCorrection)
                                        Button("補正を取消") {controller.undoCorrection()}.disabled(!controller.canUndoCorrection)
                                    }
                                    Button("形状のみを保存") {controller.exportShape(saveToFiles:true)}.disabled(!controller.canExport)
                                    if controller.lastExportURL != nil {Button("Filesに保存（ZIP）") {controller.prepareFiles()}.disabled(!controller.canPrepareFiles)}
                                    if controller.error != nil,controller.isSaving {Button("保存を再試行") {controller.retrySave()}}
                                    if controller.canRecoverCopy {Button("確定部分の回復コピー") {controller.makeRecoveryCopy()}}
                                    HStack {
                                        Button("終了して保持") {controller.stop(.ended,reason:"ユーザー終了")}.disabled(!controller.canFinish)
                                        Button("中止して保持") {controller.stop(.cancelled,reason:"ユーザー中止")}.disabled(!controller.canFinish)
                                    }
                                    Text("画像は最大\(controller.limits.maximumImages)枚・容量不足時は停止。再開した区間は自動結合しません。").font(.caption2)
                                    if let issue=controller.previewIssue {Text(issue).foregroundStyle(.orange)}
                                    if controller.normalWarnings>0 {Text("一部の法線は面の形から計算。原本は保持しています").font(.caption2)}
                                    if controller.previewFailures>0 {Text("原画像は保存済み・JPEG生成保留 \(controller.previewFailures)枚").font(.caption2)}
                                }
                            }.font(.caption)
                        }.frame(maxHeight:min(250,geometry.size.height*0.35))
                    }
                }.padding(12).arControlSurface(in:RoundedRectangle(cornerRadius:16))
            }.padding(10).buttonStyle(.bordered).tint(.white).foregroundStyle(.white).environment(\.colorScheme,.dark)
        }
        .sheet(item:Binding(get:{controller.filesRequest},set:{if $0==nil {controller.filesPickerDismissed()}})) {request in
            ScanFilesPicker(url:request.url) {controller.filesPickerFinished(request.id,outcome:$0)}
        }
    }
    @ViewBuilder private func gcpOutcome(_ outcome:GCPInputOutcome)->some View {
        switch outcome {
        case .draftRegistered(let id):Text("GCP \((controller.input.raw?.points.firstIndex(where:{$0.id==id}) ?? 0)+1) を追加").font(.caption)
        case .draftReobserved(let id,let rank):Text("GCP \((controller.input.raw?.points.firstIndex(where:{$0.id==id}) ?? 0)+1) を再観測"+(rank==2 ? "・奥行き未確定、移動して再観測":"・停止後に補正を適用できます")).font(.caption)
        case .held:Text("GCP保留・追跡、深度、同じ対象かを確認して再度タップ").font(.caption).foregroundStyle(.orange)
        }
    }
}

/// The app offers a local ZIP copy. Only the user's system picker choice writes a destination.
/// No destination URL, cloud account or provider is selected by the app.
private struct ScanFilesPicker:UIViewControllerRepresentable {
    let url:URL
    let finish:(ScanFilesOutcome)->Void
    func makeCoordinator()->Coordinator {Coordinator(finish)}
    func makeUIViewController(context:Context)->UIDocumentPickerViewController {
        let picker=UIDocumentPickerViewController(forExporting:[url],asCopy:true)
        picker.delegate=context.coordinator
        return picker
    }
    func updateUIViewController(_ controller:UIDocumentPickerViewController,context:Context) {}
    final class Coordinator:NSObject,UIDocumentPickerDelegate {
        private let finish:(ScanFilesOutcome)->Void
        private var completed=false
        init(_ finish:@escaping(ScanFilesOutcome)->Void) {self.finish=finish}
        private func complete(_ outcome:ScanFilesOutcome) {guard !completed else {return};completed=true;finish(outcome)}
        func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
            complete(urls.isEmpty ? .failed("保存先が確定しませんでした"):.saved)
        }
        func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) {complete(.cancelled)}
    }
}

/// A finite OS background allowance drains accepted work; expiration never deletes staging files.
@MainActor enum ScanBackgroundFlush {
    private static var token=UIBackgroundTaskIdentifier.invalid
    private static func end() {if token != .invalid {UIApplication.shared.endBackgroundTask(token);token = .invalid}}
    static func stop(_ controller:ScanCaptureController) {
        guard controller.isRecording || controller.isSaving else {return}
        if token == .invalid {token=UIApplication.shared.beginBackgroundTask(withName:"Scan original save") {Task {@MainActor in end()}}}
        controller.stop(reason:"バックグラウンド")
        Task {@MainActor [weak controller] in
            for _ in 0..<80 {if controller?.isSaving != true {break};try? await Task.sleep(nanoseconds:250_000_000)}
            end()
        }
    }
}
