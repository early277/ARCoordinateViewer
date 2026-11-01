import SwiftUI
import UniformTypeIdentifiers

/// Preview/merge policy shared by the quick-file path and the staged path.
/// A header may trigger validation, never confirmation or datum inference.
enum PCImportQuickPolicy {
    private struct Origin:Hashable {var source:String;var identifier:String}
    private static func sourceKey(_ point:PCKnownPoint)->Origin {Origin(source:point.source,identifier:point.sourceID)}
    static func unambiguous(_ document:PCTableDocument,_ mapping:PCTableMapping)->Bool {
        guard mapping.header,let first=document.rows.first else {return false}
        let cells=first.cells.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}
        func matches(_ words:[String])->[Int] {cells.indices.filter{words.contains(cells[$0])}}
        let north=matches(["x","north","北","x座標"]),east=matches(["y","east","東","y座標"])
        let names=matches(["name","点名","名称","point","番号"]),heights=matches(["z","height","標高","高さ","h"])
        let used=[mapping.name,Optional(mapping.x),Optional(mapping.y),mapping.height].compactMap{$0}
        return north.count==1 && east.count==1 && names.count<=1 && heights.count<=1 &&
            mapping.x==north[0] && mapping.y==east[0] && Set(used).count==used.count
    }
    static func validate(_ points:[PCKnownPoint],reference:PCControlReference)throws {
        guard reference.valid,points.count<=5000,points.allSatisfy({$0.finite && $0.planeSystem==reference.planeSystem && !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !$0.sourceID.isEmpty}),
              Set(points.map(\.id)).count==points.count,Set(points.map(sourceKey)).count==points.count else {
            throw PCTableFailure.message("入力基準・点ID・由来・座標値を確認してください。異なる基準の点は混在させません")
        }
    }
    static func merged(_ existing:[PCKnownPoint],incoming:[PCKnownPoint],reference:PCControlReference)throws->(points:[PCKnownPoint],added:Int,skipped:Int) {
        try validate(existing,reference:reference)
        var result=existing,bySource=Dictionary(uniqueKeysWithValues:existing.map{(sourceKey($0),$0)}),ids=Set(existing.map(\.id)),added=0,skipped=0
        for point in incoming {
            guard point.finite,point.planeSystem==reference.planeSystem,!point.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!point.sourceID.isEmpty else {throw PCTableFailure.message("入力基準と座標値を確認してください")}
            if let previous=bySource[sourceKey(point)] {
                guard previous.name==point.name,previous.north==point.north,previous.east==point.east,previous.height==point.height,previous.planeSystem==point.planeSystem else {
                    throw PCTableFailure.message("同じ由来の点で値が異なります。入力済みの表で確認・編集してください。既存点は変更していません")
                }
                skipped+=1;continue
            }
            guard ids.insert(point.id).inserted else {throw PCTableFailure.message("同じ点IDが重複しています。既存点は変更していません")}
            guard result.count<5000 else {throw PCTableFailure.message("合計5,000点を超えるため追加していません。表を分割してください")}
            result.append(point);bySource[sourceKey(point)]=point;added+=1
        }
        return(result,added,skipped)
    }
}

@MainActor final class PCTableImportModel:ObservableObject {
    @Published private(set) var document:PCTableDocument?
    @Published private(set) var conversion:PCTableConversion?
    @Published private(set) var busy=false
    @Published private(set) var error=""
    private var bytes:Data?
    private var name="貼付け.tsv"
    private let worker=DispatchQueue(label:"point-cloud-coordinate-import",qos:.userInitiated)
    private let deliver:@Sendable (@escaping @MainActor @Sendable ()->Void)->Void
    private var control:PCWorkControl?
    private var operation:UUID?
    private var validationGeneration=0
    private var converting=false
    private var pendingConversion:(PCTableMapping,PCControlReference)?
    init(delivery:@escaping @Sendable (@escaping @MainActor @Sendable ()->Void)->Void = {job in DispatchQueue.main.async {job()}}) {deliver=delivery}
    func cancel(){
        validationGeneration &+= 1;pendingConversion=nil;control?.cancel()
        operation=nil;control=nil;busy=false;converting=false;conversion=nil
    }
    private func finish(_ token:UUID)->Bool {
        guard operation==token else{return false}
        operation=nil;control=nil;busy=false;converting=false;return true
    }
    func read(url:URL,completion:@escaping(PCTableDocument)->Void) {
        guard !busy else{return};busy=true;error="";document=nil;conversion=nil
        let control=PCWorkControl(),token=UUID(),deliver=deliver;self.control=control;operation=token
        worker.async {
            let scope=url.startAccessingSecurityScopedResource();defer{if scope{url.stopAccessingSecurityScopedResource()}}
            let result=Result {()->(Data,PCTableDocument) in
                let data=try PCTableReader.file(url,control:control)
                return(data,try PCTableReader.read(data,name:url.lastPathComponent,control:control))
            }
            deliver {
                guard self.finish(token) else{return}
                do {try control.check()}catch{self.error=error.localizedDescription;return}
                switch result {
                case .success(let (data,doc)):self.bytes=data;self.name=url.lastPathComponent;self.document=doc;completion(doc)
                case .failure(let e):self.error=e.localizedDescription
                }
            }
        }
    }
    func paste(_ text:String,completion:@escaping(PCTableDocument)->Void) {
        guard !busy else{return}
        guard text.utf8.count<=PCTableReader.maximumBytes else {error="貼付けは8MiBまでです。表を分割してください";return}
        bytes=Data(text.utf8);name="貼付け.tsv";parse(completion:completion)
    }
    func parse(encoding:PCTableEncoding = .automatic,delimiter:PCTableDelimiter = .automatic,sheet:Int=0,completion:@escaping(PCTableDocument)->Void) {
        guard !busy,let bytes else{return};busy=true;error="";conversion=nil
        let control=PCWorkControl(),name=name,token=UUID(),deliver=deliver;self.control=control;operation=token
        worker.async {let result=Result{try PCTableReader.read(bytes,name:name,encoding:encoding,delimiter:delimiter,sheet:sheet,control:control)}
            deliver {
                guard self.finish(token) else{return}
                do {try control.check()}catch{self.error=error.localizedDescription;return}
                switch result {
                case .success(let doc):self.document=doc;completion(doc)
                case .failure(let e):self.document=nil;self.error=e.localizedDescription
                }
            }
        }
    }
    func convert(_ mapping:PCTableMapping,reference:PCControlReference) {
        guard let document else{return}
        guard !busy else {if converting {pendingConversion=(mapping,reference)};return}
        busy=true;converting=true;error="";conversion=nil
        let control=PCWorkControl(),generation=validationGeneration,token=UUID(),deliver=deliver;self.control=control;operation=token
        worker.async {let result=Result{try PCTableReader.convert(document,mapping:mapping,planeSystem:reference.planeSystem,control:control)}
            deliver {
                guard self.finish(token) else{return}
                // A cancelled mapping/reference must never restore an old preview.
                if generation==self.validationGeneration {
                    do {try control.check();switch result {
                    case .success(let value):self.conversion=value
                    case .failure(let e):self.error=e.localizedDescription
                    }}catch{self.error=error.localizedDescription}
                }
                if let pending=self.pendingConversion {self.pendingConversion=nil;self.convert(pending.0,reference:pending.1)}
            }
        }
    }
    func invalidate(){validationGeneration &+= 1;conversion=nil;pendingConversion=nil;if converting{control?.cancel()}}
}

struct PCControlImportScreen:View {
    var existing:[PCExistingCoordinate]
    @State private var reference:PCControlReference
    var existingTargets:[PCKnownPoint]
    var completion:([PCKnownPoint])->Void
    var openFileOnAppear:Bool
    var allowsReferenceEditing:Bool
    var onReferenceChange:((PCControlReference)->Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reader=PCTableImportModel()
    @State private var mode="入力方法"
    @State private var filePicker=false
    @State private var pasted=""
    @State private var encoding=PCTableEncoding.automatic
    @State private var delimiter=PCTableDelimiter.automatic
    @State private var sheet=0
    @State private var mapping:PCTableMapping?
    @State private var search=""
    @State private var selected=Set<String>()
    @State private var pointName=""
    @State private var x=""
    @State private var y=""
    @State private var height=""
    @State private var manualUnit=1.0
    @State private var manualXIsNorth=true
    @State private var message=""
    @State private var working:[PCKnownPoint]=[]
    @State private var changed=false
    @State private var tableEditor:PCReviewTable?
    @State private var editingExisting=false
    @State private var ready=false
    @State private var visible=false
    @State private var readingSettingsExpanded=false
    init(existing:[PCExistingCoordinate],reference:PCControlReference,existingTargets:[PCKnownPoint],openFileOnAppear:Bool=false,allowsReferenceEditing:Bool=false,onReferenceChange:((PCControlReference)->Void)?=nil,completion:@escaping([PCKnownPoint])->Void) {
        self.existing=existing;self.existingTargets=existingTargets;self.completion=completion
        self.openFileOnAppear=openFileOnAppear;self.allowsReferenceEditing=allowsReferenceEditing;self.onReferenceChange=onReferenceChange
        _reference=State(initialValue:reference)
        _mode=State(initialValue:openFileOnAppear ? "ファイル":"入力方法")
    }
    private var canEditReference:Bool {allowsReferenceEditing && existingTargets.isEmpty && working.isEmpty}
    private var canCommit:Bool {changed && reference.valid && (try? PCImportQuickPolicy.validate(working,reference:reference)) != nil}
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(reference.label).font(.caption)
                    Picker("入力方法",selection:$mode) {ForEach(["入力方法","入力済みの表","既存のAR点","ファイル","表を貼付け","手入力"],id:\.self){Text($0)}}
                    Text("入力元を上書きしません。点名の重複は座標と由来で区別します。最大5,000点です。").font(.caption)
                }
                if canEditReference {referenceControls}
                else if !reference.valid {Section{Text("入力座標の基準を前の画面で確認してください。既存点と異なる基準は混在させません。").font(.caption).foregroundStyle(.orange)}}
                switch mode {
                case "入力済みの表":
                    Section {
                        Text("\(working.count)点。点名・X・Y・Zを確認・編集できます。既存のGCP割当は点IDで保持されます。")
                        Button("テーブルを開く"){editingExisting=true;tableEditor=PCReviewTable.points(working,planeSystem:reference.planeSystem)}.disabled(working.isEmpty)
                    }
                case "既存のAR点":existingView
                case "ファイル":
                    Section {
                        Button("ファイルを選択"){filePicker=true}.accessibilityIdentifier("coordinateImport.selectFile")
                        Text("CSV / TXT / TSV / SIMA（A01）/ xlsx（8MiBまで）。xls・xlsm・Numbersは直接読めません。表をコピーして貼り付けてください。").font(.caption)
                    }
                    tableView
                case "表を貼付け":
                    Section {
                        TextEditor(text:$pasted).frame(height:130).autocorrectionDisabled()
                        Text("Excel・Numbers・Sheetsのセルをここに貼り付けてください。貼り付けた内容だけを読み取ります。").font(.caption)
                        Button("表をプレビュー"){mapping=nil;reader.paste(pasted,completion:received)}.disabled(pasted.isEmpty)
                    }
                    tableView
                case "手入力":manualView
                default:Text("入力方法を選んでください。複数の方法で追加できます。")
                }
                if !message.isEmpty {Section{Text(message).foregroundStyle(.orange)}}
                if !reader.error.isEmpty {Section{Text(reader.error).foregroundStyle(.orange)}}
                if reader.busy {Section{ProgressView("表を確認中")}}
                Section {
                    Text("座標点 \(working.count) 点（開いた時点: \(existingTargets.count)点）")
                    Button("変更を確定",action:commit).disabled(!canCommit).accessibilityIdentifier("coordinateImport.commit")
                    Text("確定後に対応を選び、対応表を保存してください。この画面を閉じるだけでは変更されません。").font(.caption)
                }
            }
            .disabled(reader.busy)
            .navigationTitle("座標を追加").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(reader.busy ? "処理取消":"閉じる"){if reader.busy{reader.cancel()}else{dismiss()}}}
            }
            .interactiveDismissDisabled(reader.busy)
            .fileImporter(isPresented:$filePicker,allowedContentTypes:[.data],allowsMultipleSelection:false){result in
                switch result {
                case .success(let urls):if let url=urls.first {mapping=nil;reader.read(url:url,completion:received)}
                case .failure(let e):message="ファイル選択未完了: "+e.localizedDescription
                }
            }
            .onChange(of:mapping){_,_ in revalidateIfClear()}
            .onChange(of:reference){_,_ in revalidateIfClear()}
            .onChange(of:encoding){_,_ in reader.invalidate();readingSettingsExpanded=true}
            .onChange(of:delimiter){_,_ in reader.invalidate();readingSettingsExpanded=true}
            .onChange(of:sheet){_,value in
                guard let document=reader.document,value != document.sheetIndex,!reader.busy else{return}
                mapping=nil;reader.parse(encoding:encoding,delimiter:delimiter,sheet:value,completion:received)
            }
            .sheet(item:$tableEditor){table in PCCoordinateTableScreen(table:table){points in
                if editingExisting {working=points;changed=true}
                else{add(points)}
            }}
            .onAppear {
                visible=true
                guard !ready else {return};ready=true;working=existingTargets
                if openFileOnAppear {
                    mode="ファイル"
                    // Wait for the parent sheet's presentation; request only once.
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {if visible {filePicker=true}}
                } else if !working.isEmpty {mode="入力済みの表"}
            }
            .onDisappear {visible=false}
        }
    }
    @ViewBuilder private var referenceControls:some View {
        Section("入力座標の基準") {
            Picker("平面直角の系番号",selection:referenceField(\.planeSystem)){ForEach(1...19,id:\.self){Text("\($0)系").tag($0)}}
            Picker("測地系",selection:referenceField(\.datum)){ForEach(["未確認","JGD2011","JGD2000","任意座標"],id:\.self){Text($0)}}
            Picker("高さ基準",selection:referenceField(\.height)){ForEach(["未確認","標高","楕円体高","任意高"],id:\.self){Text($0)}}
            Toggle("入力元の基準を確認しました",isOn:$reference.confirmed).accessibilityIdentifier("coordinateImport.confirmReference")
            Text("X=北・Y=東・mを基準に、下の列・軸・単位を確認してください。系番号や測地系は数値から推定しません。高さが不明なら空欄のまま扱います。").font(.caption)
        }
    }
    private func referenceField<T>(_ key:WritableKeyPath<PCControlReference,T>)->Binding<T> {
        Binding(get:{reference[keyPath:key]},set:{reference[keyPath:key]=$0;reference.confirmed=false})
    }
    private func received(_ doc:PCTableDocument) {
        mapping=PCTableMapping(document:doc);sheet=doc.sheetIndex;message=""
        readingSettingsExpanded = doc.sheetNames.count>1 || !PCImportQuickPolicy.unambiguous(doc,mapping!)
        revalidateIfClear()
    }
    private func revalidateIfClear() {
        reader.invalidate()
        guard openFileOnAppear,let document=reader.document,let mapping,PCImportQuickPolicy.unambiguous(document,mapping) else {return}
        reader.convert(mapping,reference:reference)
    }
    private func commit() {
        guard !reader.busy else{return}
        do {try PCImportQuickPolicy.validate(working,reference:reference)}
        catch {message=error.localizedDescription;return}
        guard changed else{return}
        onReferenceChange?(reference);completion(working);dismiss()
    }
    private func useVerified(_ points:[PCKnownPoint]) {
        do {
            let merged=try PCImportQuickPolicy.merged(working,incoming:points,reference:reference)
            working=merged.points;changed=true;commit()
        } catch {message=error.localizedDescription}
    }
    @discardableResult private func add(_ points:[PCKnownPoint])->Bool {
        do {
            let merged=try PCImportQuickPolicy.merged(working,incoming:points,reference:reference)
            working=merged.points;changed=changed || merged.added>0
            let names=Dictionary(grouping:working,by:{$0.name}).filter{$0.value.count>1}.count
            message="\(merged.added)点を追加予定にしました。同じ由来の\(merged.skipped)点は重複追加していません。"+(names>0 ? "重複点名\(names)種類は由来・座標で確認してください。":"")
            return merged.added>0
        } catch {message=error.localizedDescription;return false}
    }
    @ViewBuilder private var existingView:some View {
        Section {
            TextField("点名・ファイル名で検索",text:$search)
            Text("既存点を最大5,000点、検索結果を先頭200点表示します。元の緯度経度しかない場合は選択した系へ投影します。測地系間の変換はしません。").font(.caption)
            let filtered=existing.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search)}
            if filtered.isEmpty{Text("該当する読み込み済み座標点はありません")}
            ForEach(Array(filtered.prefix(200))){p in
                Toggle(isOn:Binding(get:{selected.contains(p.id)},set:{if $0{selected.insert(p.id)}else{selected.remove(p.id)}})){
                    VStack(alignment:.leading){Text(p.name);Text(p.source+" / "+p.note).font(.caption)}
                }
            }
            Button("選択した点を追加予定に入れる") {
                do {let points=try existing.filter{selected.contains($0.id)}.map{try $0.point(reference:reference)};add(points);selected=[]}
                catch {message=error.localizedDescription}
            }.disabled(selected.isEmpty || !reference.valid)
        }
    }
    @ViewBuilder private var manualView:some View {
        Section("1点を入力") {
            TextField("点名（先頭0を保持）",text:$pointName)
            TextField("X",text:$x).keyboardType(.numbersAndPunctuation)
            TextField("Y",text:$y).keyboardType(.numbersAndPunctuation)
            TextField("高さ（不明なら空欄）",text:$height).keyboardType(.numbersAndPunctuation)
            Picker("Xの向き",selection:$manualXIsNorth){Text("北（平面直角X）").tag(true);Text("東").tag(false)}
            unitPicker($manualUnit)
            Button("追加予定に入れる") {
                guard let vx=PCTableReader.number(x),let vy=PCTableReader.number(y),!pointName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{message="点名・X・Yを確認してください";return}
                let ht=height.trimmingCharacters(in:.whitespacesAndNewlines),h=PCTableReader.number(ht)
                guard ht.isEmpty || h != nil else{message="高さを確認してください。不明なら空欄です";return}
                let p=PCKnownPoint(name:pointName.trimmingCharacters(in:.whitespacesAndNewlines),north:(manualXIsNorth ? vx:vy)*manualUnit,east:(manualXIsNorth ? vy:vx)*manualUnit,height:h.map{$0*manualUnit},planeSystem:reference.planeSystem,source:"手入力",sourceID:UUID().uuidString,originalCells:[pointName,x,y,height],importDetails:"X-is-north=\(manualXIsNorth); metres/unit=\(manualUnit)")
                guard p.finite else{message="座標範囲を確認してください";return};if add([p]){pointName="";x="";y="";height=""}
            }.disabled(!reference.valid)
        }
    }
    @ViewBuilder private var tableView:some View {
        if let doc=reader.document,let current=mapping {
            if openFileOnAppear {
                if let result=reader.conversion {conversionView(result,document:doc,mapping:current)}
                Section {
                    DisclosureGroup("列・読み取り設定を確認",isExpanded:$readingSettingsExpanded) {tableSettings(doc,current)}
                }
            } else {
                Section("読込方法・列を確認") {tableSettings(doc,current)}
                if let result=reader.conversion {conversionView(result,document:doc,mapping:current)}
            }
        }
    }
    @ViewBuilder private func tableSettings(_ doc:PCTableDocument,_ current:PCTableMapping)->some View {
        Text(doc.source+" / "+doc.encoding).font(.caption)
        if doc.sheetNames.count>1 {Picker("シート",selection:$sheet){ForEach(doc.sheetNames.indices,id:\.self){Text(doc.sheetNames[$0]).tag($0)}}}
        if !doc.source.lowercased().hasSuffix(".xlsx") {
            Picker("文字コード",selection:$encoding){ForEach(PCTableEncoding.allCases,id:\.self){Text($0.rawValue).tag($0)}}
            Picker("区切り",selection:$delimiter){ForEach(PCTableDelimiter.allCases,id:\.self){Text($0.rawValue).tag($0)}}
        }
        Button("この設定で再読込"){mapping=nil;reader.parse(encoding:encoding,delimiter:delimiter,sheet:sheet,completion:received)}
        Toggle("先頭行はヘッダー",isOn:map(\.header,current))
        columnPicker("点名",value:map(\.name,current),document:doc,optional:true)
        columnPicker("X",value:Binding(get:{mapping?.x},set:{if let n=$0{mapping?.x=n}}),document:doc,optional:false)
        columnPicker("Y",value:Binding(get:{mapping?.y},set:{if let n=$0{mapping?.y=n}}),document:doc,optional:false)
        columnPicker("高さ",value:map(\.height,current),document:doc,optional:true)
        Picker("Xの向き",selection:map(\.xIsNorth,current)){Text("北（平面直角X）").tag(true);Text("東").tag(false)}
        unitPicker(map(\.metresPerUnit,current))
        Text("\(doc.rows.count)行（先頭20行を表示）。行番号は元ファイルの行です。").font(.caption)
        ForEach(Array(doc.rows.prefix(20).enumerated()),id:\.offset){_,row in Text("\(row.number): "+row.cells.joined(separator:" | ")).font(.caption).textSelection(.enabled)}
        Button("列と値を検証する"){reader.convert(current,reference:reference)}
        Button("点名・X・Y・Zの表を確認・編集") {
            do {editingExisting=false;tableEditor=try PCReviewTable.source(doc,mapping:current,planeSystem:reference.planeSystem)}
            catch {message=error.localizedDescription}
        }.disabled(!reference.valid)
    }
    @ViewBuilder private func conversionView(_ result:PCTableConversion,document:PCTableDocument,mapping:PCTableMapping)->some View {
        Section("座標プレビュー") {
            Text(document.source+" / "+(document.sheetNames[safe:document.sheetIndex] ?? "表")).font(.caption)
            Text("取込列 X=\(mapping.x+1)・Y=\(mapping.y+1)／"+(mapping.xIsNorth ? "X=北・Y=東":"X=東・Y=北")+"／1入力単位="+String(format:"%.4f",mapping.metresPerUnit)+"m。下表はmです。").font(.caption)
            Text("有効 \(result.points.count) 点／エラー \(result.errors.count) 行").accessibilityIdentifier("coordinateImport.validatedCount")
            if !result.points.isEmpty {PCImportPointPreview(points:result.points)}
            ForEach(Array(result.errors.prefix(100).enumerated()),id:\.offset){_,text in Text(text).foregroundStyle(.orange).font(.caption)}
            if result.errors.count>100{Text("エラーは先頭100行を表示。元の表を修正して再読込してください").font(.caption)}
            ForEach(Array(result.warnings.prefix(30).enumerated()),id:\.offset){_,text in Text(text).font(.caption)}
            if openFileOnAppear {
                let mergeIssue=reference.valid ? mergeError(result.points):nil
                if let mergeIssue {Text(mergeIssue).font(.caption).foregroundStyle(.orange)}
                if !working.isEmpty {Text("入力済み\(working.count)点とまとめて確定します。入力元は変更しません。").font(.caption)}
                Button("この座標を使う（\(result.points.count)点）") {useVerified(result.points)}
                    .disabled(!result.errors.isEmpty || result.points.isEmpty || !reference.valid || mergeIssue != nil)
                    .accessibilityIdentifier("coordinateImport.useCoordinates")
            } else {
                Button("確認した点を追加予定に入れる"){add(result.points)}.disabled(!result.errors.isEmpty || result.points.isEmpty || !reference.valid)
            }
        }
    }
    private func mergeError(_ points:[PCKnownPoint])->String? {
        do {_=try PCImportQuickPolicy.merged(working,incoming:points,reference:reference);return nil}
        catch {return error.localizedDescription}
    }
    private func map<T>(_ key:WritableKeyPath<PCTableMapping,T>,_ fallback:PCTableMapping)->Binding<T>{Binding(get:{mapping?[keyPath:key] ?? fallback[keyPath:key]},set:{mapping?[keyPath:key]=$0})}
    private func columnPicker(_ title:String,value:Binding<Int?>,document:PCTableDocument,optional:Bool)->some View {
        let columns=min(64,document.rows.map{$0.cells.count}.max() ?? 0)
        return Picker(title,selection:value){
            if optional{Text(title=="点名" ? "行番号で命名":"使用しない").tag(nil as Int?)}
            ForEach(0..<columns,id:\.self){i in
                Text("列\(i+1): "+String((document.rows.first?.cells[safe:i] ?? "").prefix(24))).tag(Optional(i))
            }
        }
    }
    private func unitPicker(_ value:Binding<Double>)->some View {Picker("入力の単位",selection:value){Text("m").tag(1.0);Text("cm").tag(0.01);Text("mm").tag(0.001);Text("ft（国際）").tag(0.3048)}}
}
/// A short normalized preview keeps the confirmation adjacent to the values.
/// Full editing remains available; missing height is never displayed as zero.
private struct PCImportPointPreview:View {
    var points:[PCKnownPoint]
    private let widths:[CGFloat]=[100,130,130,110]
    var body:some View {
        ScrollView(.horizontal) {
            VStack(alignment:.leading,spacing:5) {
                row(["点名","X 北 (m)","Y 東 (m)","高さ (m)"],header:true)
                ForEach(Array(points.prefix(8))){p in row([p.name,String(format:"%.4f",p.north),String(format:"%.4f",p.east),p.height.map{String(format:"%.4f",$0)} ?? "—"])}
            }
        }.accessibilityIdentifier("coordinateImport.previewTable")
        if points.count>8 {Text("先頭8点を表示しています。全点は表の確認・編集で確認できます。").font(.caption)}
    }
    private func row(_ cells:[String],header:Bool=false)->some View {
        HStack(spacing:6) {
            ForEach(Array(cells.enumerated()),id:\.offset){i,text in
                Text(text).font(header ? .caption.bold():.caption).monospacedDigit().lineLimit(2).frame(width:widths[i],alignment:i==0 ? .leading:.trailing)
            }
        }.accessibilityElement(children:.combine)
    }
}
private extension Array {subscript(safe index:Int)->Element? {indices.contains(index) ? self[index]:nil}}
