import SwiftUI
import UniformTypeIdentifiers

struct DXFDrawingDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension:"dxf") ?? .data] }
    var data: Data
    init(data:Data) { self.data=data }
    init(configuration:ReadConfiguration) throws { data=configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct DXFDrawingExportView: View {
    @EnvironmentObject private var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var documentID=""
    private var documents:[DrawingExportDocument] { model.drawingExportDocuments }
    var body:some View {
        NavigationStack {
            Form {
                Section("合わせる元図面") {
                    if documents.count > 1 {
                        Picker("図面",selection:$documentID) {
                            Text("選択してください").tag("")
                            ForEach(documents) { document in Text(document.name).tag(document.id) }
                        }.accessibilityIdentifier("export.document")
                    } else if let document=documents.first { Text(document.name) }
                }
                if let document=documents.first(where:{ $0.id==documentID }) {
                    DrawingExportOptions(document:document,profile:model.drawingExportProfile(for:document))
                        .id(document.id)
                }
            }
            .navigationTitle("DXF書き出し")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("閉じる") { dismiss() }.accessibilityIdentifier("export.close") } }
            .onAppear {
                model.prepareDrawingExport()
                if let saved=model.drawingExportDocument, documents.contains(where:{ $0.id==saved }) { documentID=saved }
                else if documents.count==1 { documentID=documents[0].id }
            }
        }
    }
}

private struct DrawingExportOptions:View {
    @EnvironmentObject private var model:AppModel
    let document:DrawingExportDocument
    @State private var profile:DrawingExportProfile
    @State private var unitText:String
    @State private var heightText:String
    @State private var coordinatesExpanded:Bool
    @State private var heightExpanded=false
    @State private var preparing=false
    @State private var showingFileExporter=false
    @State private var data=Data()
    @State private var message=""
    init(document:DrawingExportDocument,profile:DrawingExportProfile) {
        self.document=document
        _profile=State(initialValue:profile)
        _unitText=State(initialValue:profile.metresPerUnit.map { String($0) } ?? "")
        _heightText=State(initialValue:profile.anchorAltitude.map { String($0) } ?? "")
        _coordinatesExpanded=State(initialValue:profile.reference == nil)
    }
    private var anchors:[DrawingExportAnchor] { model.drawingExportAnchors }
    private var eligibleAnchors:[DrawingExportAnchor] { anchors.filter { $0.info.elevation == nil || $0.info.elevationSource == .sourceDrawing } }
    private var selectedAnchor:DrawingExportAnchor? { anchors.first { $0.id==profile.anchorID } }
    private var unknownHeight:Bool { anchors.contains { $0.info.elevation == nil } }
    private var heightSummary:String {
        if profile.heightMode == .planar { return document.planar ? "元図面と同じ Z=0" : "平面図として Z=0" }
        if profile.heightMode == .automatic && document.planar { return "元図面と同じ Z=0" }
        if profile.heightMode == .referencePoint { return "不明な標高を基準点から推定" }
        if unknownHeight { return "観測点の標高基準が不明です" }
        if anchors.contains(where:{ $0.info.elevationSource == .arEstimate }) { return "元図面の標高基準・AR観測点は推定" }
        return "元図面の標高を保持"
    }
    private var snapshot:DrawingExportSnapshot? { try? model.makeDrawingExportSnapshot(document:document,profile:profile) }
    private var coordinateSummary:String {
        guard let r=profile.reference else { return "元図面の読込設定を指定" }
        let unit=r.metersPerUnit==1 ? "m" : (r.metersPerUnit==0.001 ? "mm" : "1単位=\(r.metersPerUnit)m")
        return "\(r.planeSystem)系・\(unit)・X=\(r.xIsEasting ? "東" : "北")"
    }
    var body:some View {
        Group {
            Section {
                DisclosureGroup(isExpanded:$coordinatesExpanded) {
                    Picker("平面直角座標系",selection:$profile.planeSystem) {
                        Text("選択").tag(0)
                        ForEach(1...19,id:\.self) { Text("\($0)系").tag($0) }
                    }.accessibilityIdentifier("export.plane")
                    Picker("DXFの軸",selection:Binding(get:{ profile.xIsEasting.map { $0 ? 1 : 2 } ?? 0 },set:{ profile.xIsEasting=$0==0 ? nil : $0==1 })) {
                        Text("選択").tag(0); Text("X=東・Y=北").tag(1); Text("X=北・Y=東").tag(2)
                    }.accessibilityIdentifier("export.axes")
                    LabeledContent("1単位の長さ（m）") {
                        TextField("mは1、mmは0.001",text:$unitText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("export.units")
                    }
                } label: {
                    VStack(alignment:.leading,spacing:3) {
                        Text("座標設定")
                        Text(coordinateSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("export.coordinates")
            }
            Section("高さ") {
                Text(heightSummary).font(.subheadline)
                    .foregroundStyle(profile.heightMode == .automatic && unknownHeight && !document.planar ? Color.orange : Color.primary)
                    .accessibilityIdentifier("export.heightSummary")
                DisclosureGroup("高さの扱い",isExpanded:$heightExpanded) {
                    Picker("書き出す高さ",selection:$profile.heightMode) {
                        Text("図面に合わせる").tag(DrawingExportHeightMode.automatic)
                        Text("平面図 Z=0").tag(DrawingExportHeightMode.planar)
                        Text("基準点から推定").tag(DrawingExportHeightMode.referencePoint)
                    }.accessibilityIdentifier("export.heightMode")
                    if profile.heightMode == .referencePoint {
                        Picker("標高の基準点",selection:$profile.anchorID) {
                            Text("選択").tag(Optional<UUID>.none)
                            if let id=profile.anchorID, !eligibleAnchors.contains(where:{ $0.id==id }) { Text("基準点を選び直してください").tag(Optional(id)) }
                            ForEach(eligibleAnchors) { Text($0.name).tag(Optional($0.id)) }
                        }.accessibilityIdentifier("export.anchor")
                        if let anchor=selectedAnchor, anchor.info.elevationSource == .sourceDrawing, let height=anchor.info.elevation {
                            LabeledContent("元図面の標高",value:String(format:"%.3f m",height))
                        } else {
                            LabeledContent("基準点の標高（m）") {
                                TextField("標高",text:$heightText).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("export.anchorHeight")
                            }
                        }
                        Text("選んだ作図点を基準に、高さ不明の観測点を推定します。").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("export.heightOptions")
            }
            Section {
                Button("DXFを保存",action:prepare).disabled(snapshot == nil || preparing)
                    .accessibilityIdentifier("export.save")
                if preparing { ProgressView("作成中") }
                if !message.isEmpty { Text(message).font(.caption) }
                if model.origin == nil { Text("先に立ち位置を設定してください。").font(.caption).foregroundStyle(.orange) }
                Text("追加した点・線を別ファイルに保存").font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(preparing)
        .onAppear {
            heightExpanded=profile.heightMode != .automatic || (unknownHeight && !document.planar)
            model.saveDrawingExportProfile(profile,document:document.id)
        }
        .onChange(of:profile) { _, value in model.saveDrawingExportProfile(value,document:document.id) }
        .onChange(of:unitText) { _, value in
            profile.metresPerUnit=Double(value)
            profile.insertionUnits=profile.metresPerUnit==document.reference?.metersPerUnit ? document.reference?.insertionUnits : nil
        }
        .onChange(of:heightText) { _, value in profile.anchorAltitude=Double(value) }
        .onChange(of:profile.heightMode) { _, mode in
            if mode == .referencePoint && profile.anchorID == nil { profile.anchorID=eligibleAnchors.first?.id }
        }
        .onChange(of:profile.anchorID) { _, _ in heightText=""; profile.anchorAltitude=nil }
        .fileExporter(isPresented:$showingFileExporter,document:DXFDrawingDocument(data:data),contentType:DXFDrawingDocument.readableContentTypes[0],defaultFilename:"AR追加作図_\(Int(Date().timeIntervalSince1970))") { result in
            switch result {
            case .success: message="保存しました"
            case .failure(let error): message=(error as NSError).code == NSUserCancelledError ? "保存を中止しました" : error.localizedDescription
            }
        }
    }
    private func prepare() {
        guard let snapshot else { return }
        preparing=true; message=""
        Task {
            let result=await Task.detached(priority:.userInitiated) { Result { try snapshot.encode() } }.value
            preparing=false
            switch result {
            case .success(let output): data=output; showingFileExporter=true
            case .failure(let error): message=error.localizedDescription
            }
        }
    }
}
