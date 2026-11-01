import SwiftUI

struct PhotoSettingsView:View {
    @EnvironmentObject private var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var documentID=""
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("ARの位置・向きを使う",isOn:$model.useARPhotoPose).accessibilityIdentifier("photo.source")
                    Text(model.useARPhotoPose ? "図面に合わせた位置・向きを使用します。任意座標も撮影記録に残します。" : "端末のGPS位置を使用します。位置やカメラ方向が取得できない場合は、その項目を省きます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("合わせる元図面") {
                    if model.drawingExportDocuments.count>1 {
                        Picker("図面",selection:$documentID) {
                            Text("選択してください").tag("")
                            ForEach(model.drawingExportDocuments) { Text($0.name).tag($0.id) }
                        }
                    } else if let document=model.drawingExportDocuments.first { Text(document.name) }
                }
                if let document=model.drawingExportDocuments.first(where:{$0.id==documentID}) {
                    PhotoReferenceOptions(document:document,settings:model.photoReferenceSettings[document.id] ?? PhotoReferenceSettings()).id(document.id)
                }
                Section("撮影記録") {
                    Text("写真とXYZ・向きの記録、写真名付きCSVを、このiPhone内の「AR境界簡易表示／撮影記録」に保存します。写真アプリにも同じ写真を追加します。")
                        .font(.footnote)
                    Text("ARを再起動した後は現地と位置を合わせてください。追跡や撮影時刻の対応が不確かなときは、その状態を記録しGPS情報を省きます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("写真の座標")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("閉じる") { dismiss() }.accessibilityIdentifier("photo.close") } }
            .onAppear {
                let documents=model.drawingExportDocuments
                if let saved=model.photoReferenceDocument,documents.contains(where:{$0.id==saved}) { documentID=saved }
                else if documents.count==1 { documentID=documents[0].id }
            }
        }
    }
}
private struct PhotoReferenceOptions:View {
    @EnvironmentObject private var model:AppModel
    let document:DrawingExportDocument
    @State private var settings:PhotoReferenceSettings
    init(document:DrawingExportDocument,settings:PhotoReferenceSettings) { self.document=document;_settings=State(initialValue:settings) }
    var body:some View {
        Section("座標の基準") {
            if let r=document.reference {
                LabeledContent("元図面",value:"\(r.planeSystem)系・\(r.metersPerUnit==1 ? "m" : r.metersPerUnit==0.001 ? "mm" : "1単位=\(r.metersPerUnit)m")・X=\(r.xIsEasting ? "東" : "北")")
            } else { Text("XYZは図面の立ち位置を基準にした東・北・高さ（m）で記録") .font(.footnote) }
            Picker("測地系",selection:$settings.datum) { ForEach(SurveyDatum.allCases,id:\.self) { Text($0.title).tag($0) } }
            if let datum=model.drawingCaptureDatum { LabeledContent("図面の基準標高",value:String(format:"%.3f m",datum)) }
            else { Text("標高基準は未設定です。相対高さを記録します。") .font(.footnote).foregroundStyle(.secondary) }
            Picker("標高の種類",selection:$settings.heightReference) { ForEach(SurveyHeightReference.allCases,id:\.self) { Text($0.title).tag($0) } }
            Text("不明な基準は推測しません。緯度経度には測地系、写真のGPS標高には海面基準であることの確認が必要です。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { model.savePhotoReference(settings,document:document.id) }
        .onChange(of:settings) { _, value in model.savePhotoReference(value,document:document.id) }
    }
}
