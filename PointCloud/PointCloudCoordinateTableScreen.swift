import SwiftUI

struct PCCoordinateTableScreen:View {
    @Environment(\.dismiss) private var dismiss
    @State var table:PCReviewTable
    var completion:([PCKnownPoint])->Void
    @State private var verified:[PCKnownPoint]?
    @State private var errors:[UUID:String]=[:]
    @State private var message=""
    @State private var busy=false
    @State private var control:PCWorkControl?
    var body:some View {
        NavigationStack {
            VStack(alignment:.leading) {
                Text("点名・X・Y・Zを直接編集できます。横にスクロールして確認してください。Zの空欄は高さ欠損です。元の文字列は保持します。").font(.caption).padding(.horizontal)
                Text("\(table.rows.count)行 / X=\(table.xIsNorth ? "北":"東") / 1入力単位=\(table.metresPerUnit)m / \(table.planeSystem)系").font(.caption).padding(.horizontal)
                ScrollView(.horizontal) {
                    List {
                        HStack {Text("行").frame(width:35);Text("点名").frame(width:110);Text("X").frame(width:150);Text("Y").frame(width:150);Text("Z（高さ）").frame(width:120)}.font(.caption.bold())
                        ForEach($table.rows){$row in
                            VStack(alignment:.leading) {
                                HStack {
                                    Text(String(row.line)).font(.caption).frame(width:35)
                                    ForEach(0..<4,id:\.self){i in
                                        TextField(i==0 ? "点名":(i==3 ? "欠損":"数値"),text:Binding(get:{row.cells[i]},set:{
                                            guard $0.utf8.count<=4096 else {errors[row.id]="セルは4,096byteまでです。入力は変更していません";verified=nil;return}
                                            row.cells[i]=$0;verified=nil;errors[row.id]=nil
                                        }))
                                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                                            .accessibilityLabel("\(row.line)行目、\(row.cells[0].isEmpty ? "点名未入力":row.cells[0])、\(["点名",table.xIsNorth ? "X 北方向":"X 東方向",table.xIsNorth ? "Y 東方向":"Y 北方向","Z 高さ"][i])")
                                            .accessibilityHint(i==3 ? "空欄は高さ欠損として扱います":"元の入力値を確認して編集します")
                                            .keyboardType(i==0 ? .default:.numbersAndPunctuation).frame(width:i==0 ? 110:(i==3 ? 120:150))
                                    }
                                }
                                Text(row.source).font(.caption2).foregroundStyle(.secondary)
                                if let error=errors[row.id]{Text(error).font(.caption).foregroundStyle(.orange)}
                            }
                        }
                    }.frame(width:740)
                }.disabled(busy)
                if !message.isEmpty{Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal)}
                HStack {
                    if busy{ProgressView("検証中");Button("取消"){control?.cancel()}}
                    else if let verified{Button("この表を使用する"){completion(verified);dismiss()}.buttonStyle(.borderedProminent)}
                    else{Button("値を検証する",action:validate).buttonStyle(.borderedProminent)}
                }.padding()
            }
            .navigationTitle("座標テーブル").navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.cancellationAction){Button("閉じる"){dismiss()}.disabled(busy)}}
            .interactiveDismissDisabled(busy)
        }
    }
    private func validate(){
        guard !busy else{return};busy=true;verified=nil;let input=table,control=PCWorkControl();self.control=control
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result{try input.validate(control:control)}
            DispatchQueue.main.async {
                busy=false;self.control=nil
                switch result {
                case .success(let result):
                    errors=result.errors
                    verified=result.errors.isEmpty && !result.points.isEmpty ? result.points:nil
                    message="有効\(result.points.count)点／エラー\(result.errors.count)行。"+result.warnings.prefix(4).joined(separator:" / ")
                case .failure(let e):message=e.localizedDescription
                }
            }
        }
    }
}
