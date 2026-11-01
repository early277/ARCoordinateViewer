import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum PCTableFailure:Error,LocalizedError {
    case message(String)
    var errorDescription:String? {if case .message(let text)=self{return text};return nil}
}
enum PCTableEncoding:String,CaseIterable {case automatic="自動",utf8="UTF-8",shiftJIS="Shift_JIS",eucJP="EUC-JP",utf16="UTF-16"}
enum PCTableDelimiter:String,CaseIterable {case automatic="自動",comma="カンマ",tab="タブ",space="空白"}
struct PCTableRow {var number:Int;var cells:[String];var cellIssues:[Int:String]=[:];var notes:[String]=[];var originalCells:[String]?=nil;var rowIssues:[String]=[]}
struct PCTableDocument {
    var source:String;var hash:String;var encoding:String
    var sheetNames:[String];var sheetIndex:Int;var rows:[PCTableRow]
    var notes:[String]=[]
}
struct PCTableMapping:Equatable {
    var header=true
    var name:Int?=0;var x=1;var y=2;var height:Int?=3
    var xIsNorth=true;var metresPerUnit=1.0
    init(document:PCTableDocument) {
        guard let first=document.rows.first else {return}
        let cells=first.cells.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}
        func index(_ words:[String])->Int? {cells.firstIndex{words.contains($0)}}
        let nx=index(["x","north","北","x座標"]),ny=index(["y","east","東","y座標"])
        header=nx != nil && ny != nil
        if header {name=index(["name","点名","名称","point","番号"]);x=nx!;y=ny!;height=index(["z","height","標高","高さ","h"])}
        else {height=first.cells.count>=4 ? 3:nil}
    }
}
struct PCTableConversion {var points:[PCKnownPoint];var errors:[String];var warnings:[String]}
enum PCTableReader {
    static let maximumBytes=8*1024*1024,maximumRows=10_000,maximumColumns=64,maximumCell=4096
    static func file(_ url:URL,control:PCWorkControl)throws->Data {
        try control.check();let meta=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard meta.isRegularFile==true,let size=meta.fileSize,size<=maximumBytes else {throw PCTableFailure.message("ファイルは8MiBまでです。表を分割してください")}
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()};var bytes=Data()
        while true {try control.check();let chunk=try handle.read(upToCount:65536) ?? Data();if chunk.isEmpty{break};guard bytes.count+chunk.count<=maximumBytes else {throw PCTableFailure.message("読込中に8MiBを超えました")};bytes.append(chunk)}
        return bytes
    }
    static func read(_ data:Data,name:String,encoding:PCTableEncoding = .automatic,delimiter:PCTableDelimiter = .automatic,sheet:Int=0,control:PCWorkControl=PCWorkControl())throws->PCTableDocument {
        try control.check();guard data.count<=maximumBytes else {throw PCTableFailure.message("表は8MiBまでです")}
        let ext=URL(fileURLWithPath:name).pathExtension.lowercased()
        if ext=="xlsx" {return try spreadsheet(data,name:name,sheet:sheet,control:control)}
        guard ["csv","txt","tsv","sim","sima",""].contains(ext) else {throw PCTableFailure.message("対応はCSV/TXT/TSV・SIMA（A01）・xlsxです。.xls・.xlsm・Numbersファイルは表をコピーして貼り付けてください")}
        let choices:[(PCTableEncoding,String.Encoding)]
        switch encoding {
        case .automatic:
            choices=data.starts(with:[0xff,0xfe]) || data.starts(with:[0xfe,0xff]) ? [(.utf16,.utf16)]:[(.utf8,.utf8),(.shiftJIS,.shiftJIS),(.eucJP,.japaneseEUC)]
        case .utf8:choices=[(.utf8,.utf8)]
        case .shiftJIS:choices=[(.shiftJIS,.shiftJIS)]
        case .eucJP:choices=[(.eucJP,.japaneseEUC)]
        case .utf16:choices=[(.utf16,.utf16)]
        }
        let candidates=choices.compactMap {kind,enc in String(data:data,encoding:enc).map{(kind,$0)}}
        // UTF-8/BOM wins when valid. Legacy Japanese encodings can both decode;
        // familiar header words help, but the preview always exposes the guess.
        let decoded=candidates.first.flatMap {first -> (PCTableEncoding,String)? in
            if encoding != .automatic || first.0 == .utf8 || first.0 == .utf16 {return first}
            func score(_ text:String)->Int {["点名","座標","高さ","標高","名称"].reduce(0){$0+(text.prefix(4096).contains($1) ? 10:0)}}
            return candidates.max{score($0.1)<score($1.1)}
        }
        guard let decoded else {throw PCTableFailure.message("文字コードを確認してください")}
        let text=decoded.1.trimmingCharacters(in:CharacterSet(charactersIn:"\u{FEFF}"))
        guard !text.contains("\0") else {throw PCTableFailure.message("テキストとして読めません。文字コードを確認してください")}
        let resolved:PCTableDelimiter
        if delimiter == .automatic {let sample=text.prefix(4096);resolved=sample.contains("\t") ? .tab:(sample.contains(",") ? .comma:.space)} else {resolved=delimiter}
        var rows=try delimited(text,separator:["sim","sima"].contains(ext) ? .comma:resolved,control:control)
        if ["sim","sima"].contains(ext) || (rows.prefix(50).contains(where:{$0.cells.first?.uppercased()=="A00"}) && rows.prefix(50).contains(where:{$0.cells.first?.uppercased()=="A01"})) {
            rows=try simaRows(rows)
            return PCTableDocument(source:name,hash:PCStore.digest(data),encoding:decoded.0.rawValue+"／SIMA A01",sheetNames:["座標"],sheetIndex:0,rows:rows,notes:["SIMAの座標A01のみ。画地・路線など非座標レコードは対象外です","系番号・測地系・高さ種別は推定していません。入力基準を確認してください"])
        }
        return PCTableDocument(source:name,hash:PCStore.digest(data),encoding:decoded.0.rawValue+"／"+resolved.rawValue,sheetNames:["表"],sheetIndex:0,rows:rows,notes:encoding == .automatic ? ["文字コードと区切りは推定です。表を確認して確定してください"]:[])
    }
    static func simaRows(_ input:[PCTableRow])throws->[PCTableRow] {
        var rows=[PCTableRow(number:0,cells:["点名","X","Y","高さ"])],numbers=Set<String>()
        for row in input where row.cells.first?.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()=="A01" {
            guard let f=SIMACoordinateFields(row.cells) else {
                rows.append(PCTableRow(number:row.number,cells:["","","",""],originalCells:row.cells,rowIssues:["A01の列数不足。点番号・点名・X・Y・Zを確認してください"]));continue
            }
            var issues:[Int:String]=[:]
            if f.number.isEmpty || !numbers.insert(f.number).inserted {issues[0]="SIMA点番号が空欄または重複しています"}
            // Empty trailing fields are conventional. Unknown nonempty extensions
            // are held for explicit review rather than guessed as coordinates.
            if row.cells.dropFirst(6).contains(where:{!$0.trimmingCharacters(in:.whitespaces).isEmpty}) {issues[1]="A01の追加項目は未対応です。座標列を確認してください"}
            rows.append(PCTableRow(number:row.number,cells:[f.name.isEmpty ? f.number:f.name,f.x,f.y,f.height],notes:["SIMA点番号: "+f.number],originalCells:row.cells,rowIssues:Array(issues.values)))
        }
        guard rows.count>1 else {throw PCTableFailure.message("対応するSIMA A01座標がありません。JPGIS XML版は未対応です")};return rows
    }
    static func delimited(_ source:String,separator:PCTableDelimiter,control:PCWorkControl)throws->[PCTableRow] {
        let text=source.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        var rows:[PCTableRow]=[],cells:[String]=[],value="",quoted=false,afterQuote=false,line=1,start=1,index=0
        let chars=Array(text)
        func appendCell()throws {guard cells.count<maximumColumns,value.utf8.count<=maximumCell else {throw PCTableFailure.message("行\(start): 列数またはセル長の上限です")};cells.append(value);value="";afterQuote=false}
        func appendRow()throws {
            try appendCell()
            if cells.contains(where:{!$0.trimmingCharacters(in:.whitespaces).isEmpty}) {guard rows.count<maximumRows else {throw PCTableFailure.message("表は10,000行までです。分割してください")};rows.append(PCTableRow(number:start,cells:cells))}
            cells=[];start=line+1
        }
        while index<chars.count {
            if index%4096==0 {try control.check()}
            let ch=chars[index]
            if quoted {
                if ch=="\"" {if index+1<chars.count,chars[index+1]=="\"" {value.append("\"");index+=1} else {quoted=false;afterQuote=true}}
                else {value.append(ch);if ch=="\n"{line+=1}}
            } else if ch=="\"",value.isEmpty,!afterQuote {quoted=true}
            else if ch=="\n" {try appendRow();line+=1}
            else if (separator == .comma && ch==",") || (separator == .tab && ch=="\t") || (separator == .space && (ch==" " || ch=="\t")) {
                if separator != .space || !value.isEmpty || afterQuote {try appendCell()}
            } else if afterQuote {
                guard ch==" " else {throw PCTableFailure.message("行\(line): 引用符の後の区切りを確認してください")}
            } else {
                guard ch != "\"" else {throw PCTableFailure.message("行\(line): 引用符が不正です")};value.append(ch)
            }
            guard value.utf8.count<=maximumCell else {throw PCTableFailure.message("行\(line): セルが長すぎます")};index+=1
        }
        guard !quoted else {throw PCTableFailure.message("行\(start): 引用符が閉じていません")}
        if !value.isEmpty || !cells.isEmpty || afterQuote {try appendRow()}
        return rows
    }
    static func number(_ text:String)->Double? {
        let value=(text.applyingTransform(.fullwidthToHalfwidth,reverse:false) ?? text).trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"−",with:"-")
        guard value.count<=80,value.range(of:#"^[+-]?(?:\d{1,3}(?:,\d{3})+|\d+|\d*\.\d+)(?:\.\d*)?(?:[eE][+-]?\d+)?$"#,options:.regularExpression) != nil,
              let n=Double(value.replacingOccurrences(of:",",with:"")),n.isFinite else {return nil};return n
    }
    static func convert(_ table:PCTableDocument,mapping:PCTableMapping,planeSystem:Int,control:PCWorkControl=PCWorkControl())throws->PCTableConversion {
        guard (1...19).contains(planeSystem),[1.0,0.01,0.001,0.3048].contains(mapping.metresPerUnit) else {throw PCControlFailure.reference}
        let columns=[mapping.x,mapping.y]+[mapping.name,mapping.height].compactMap{$0}
        guard Set(columns).count==columns.count,columns.allSatisfy({$0>=0 && $0<maximumColumns}) else {throw PCTableFailure.message("列の重複または範囲を確認してください")}
        var points:[PCKnownPoint]=[],errors:[String]=[],warnings=table.notes,names=Set<String>()
        let rows=mapping.header ? Array(table.rows.dropFirst()):table.rows
        guard rows.count<=5000 else {throw PCTableFailure.message("確定は5,000点までです。表を分割してください")}
        let expected=table.rows.first?.cells.count ?? 0
        for row in rows {
            try control.check()
            func cell(_ i:Int?)->String {guard let i,i<row.cells.count else{return ""};return row.cells[i].trimmingCharacters(in:.whitespacesAndNewlines)}
            var issues=row.rowIssues+columns.compactMap{row.cellIssues[$0]}
            if mapping.header,row.cells.count>expected {issues.append("ヘッダーより列が多いです。桁区切りを含む数値は引用符で囲んでください")}
            guard issues.isEmpty else {errors.append("行\(row.number): "+issues.joined(separator:" / "));continue}
            guard let x=number(cell(mapping.x)),let y=number(cell(mapping.y)) else {errors.append("行\(row.number): X/Yが数値ではありません");continue}
            let hText=cell(mapping.height),h=hText.isEmpty ? nil:number(hText)
            guard hText.isEmpty || h != nil else {errors.append("行\(row.number): 高さを確認してください（欠損は空欄）");continue}
            let name=mapping.name==nil ? "行\(row.number)":cell(mapping.name)
            guard !name.isEmpty else {errors.append("行\(row.number): 点名が空欄です");continue}
            if !names.insert(name).inserted {warnings.append("行\(row.number): 点名「\(name)」が重複しています。由来・座標で区別してください")}
            warnings+=row.notes.map{"行\(row.number): "+$0}
            let north=(mapping.xIsNorth ? x:y)*mapping.metresPerUnit,east=(mapping.xIsNorth ? y:x)*mapping.metresPerUnit
            let point=PCKnownPoint(name:name,north:north,east:east,height:h.map{$0*mapping.metresPerUnit},planeSystem:planeSystem,source:table.source+" / "+table.sheetNames[table.sheetIndex],sourceID:table.hash+"/\(table.sheetIndex)/\(row.number)",originalCells:row.originalCells ?? row.cells,importDetails:"\(table.encoding); row \(row.number); columns name=\(mapping.name.map(String.init) ?? "none"),X=\(mapping.x),Y=\(mapping.y),H=\(mapping.height.map(String.init) ?? "none"); X-is-north=\(mapping.xIsNorth); metres/unit=\(mapping.metresPerUnit)")
            if point.finite {points.append(point)} else {errors.append("行\(row.number): 座標範囲または数値が不正です")}
        }
        return PCTableConversion(points:points,errors:errors,warnings:Array(warnings.prefix(200)))
    }
    private static func spreadsheet(_ data:Data,name:String,sheet:Int,control:PCWorkControl)throws->PCTableDocument {
        let archive=try DEMZIPArchive(data:data)
        guard Set(archive.entries.map(\.name)).count==archive.entries.count,
              archive.entries.allSatisfy({!$0.name.hasPrefix("/") && !$0.name.split(separator:"/").contains("..")}),
              archive.entries.reduce(Int64(0),{$0+Int64($1.uncompressedSize)})<=32*1024*1024 else {throw PCTableFailure.message("xlsxの構造または展開サイズ（32MiB上限）を確認してください")}
        func xml(_ path:String,_ kind:PCSpreadsheetXML.Kind)throws->PCSpreadsheetXML {
            try control.check()
            guard let entry=archive.entries.first(where:{$0.name==path}),entry.uncompressedSize<=8*1024*1024 else {throw PCTableFailure.message("xlsx内の表が見つからないか8MiBを超えています: "+path)}
            return try PCSpreadsheetXML.parse(archive.extract(entry),kind:kind,control:control)
        }
        let book=try xml("xl/workbook.xml",.workbook),relations=try xml("xl/_rels/workbook.xml.rels",.relations)
        guard !book.items.isEmpty,book.items.count<=20,book.items.indices.contains(sheet) else {throw PCTableFailure.message("xlsxは20シートまでです。対象シートを確認してください")}
        let selected=book.items[sheet],relationship=relations.items.first{$0["Id"]==selected["r:id"]}
        guard let target=relationship?["Target"],relationship?["TargetMode"] != "External",!target.contains(":"),!target.split(separator:"/").contains("..") else {throw PCTableFailure.message("外部参照や不正なシートは読み込みません")}
        let path=target.hasPrefix("/xl/") ? String(target.dropFirst()):"xl/"+target
        let strings=archive.entries.contains{$0.name=="xl/sharedStrings.xml"} ? try xml("xl/sharedStrings.xml",.strings).strings:[]
        let styles=archive.entries.contains{$0.name=="xl/styles.xml"} ? try xml("xl/styles.xml",.styles):nil
        let table=try xml(path,.worksheet(strings,styles?.formats ?? [:],styles?.styleIDs ?? []))
        return PCTableDocument(source:name,hash:PCStore.digest(data),encoding:"xlsx XML（端末内・数式は再計算しません）",sheetNames:book.items.map{$0["name"] ?? "シート"},sheetIndex:sheet,rows:table.rows,notes:["数式は保存済み計算値だけを読みます。マクロ・外部リンクは実行しません"])
    }
}

private final class PCSpreadsheetXML:NSObject,XMLParserDelegate {
    enum Kind {case workbook,relations,strings,styles,worksheet([String],[Int:String],[Int])}
    let kind:Kind,control:PCWorkControl
    var items:[[String:String]]=[],strings:[String]=[],formats:[Int:String]=[:],styleIDs:[Int]=[],rows:[PCTableRow]=[]
    private var stack:[String]=[],text="",row=PCTableRow(number:1,cells:[]),column=0,cellType="",style=0,value="",inline="",formula=false,hasValue=false,shared="",problem:String?
    private var seenRows=Set<Int>(),seenColumns=Set<Int>()
    init(_ kind:Kind,_ control:PCWorkControl){self.kind=kind;self.control=control}
    static func parse(_ data:Data,kind:Kind,control:PCWorkControl)throws->PCSpreadsheetXML {
        guard let source=String(data:data,encoding:.utf8),!source.contains("<!DOCTYPE"),!source.contains("<!ENTITY") else {throw PCTableFailure.message("XMLの文字コードまたは外部定義は対応外です")}
        let delegate=PCSpreadsheetXML(kind,control),parser=XMLParser(data:data);parser.shouldResolveExternalEntities=false;parser.delegate=delegate
        guard parser.parse(),delegate.problem==nil else {throw PCTableFailure.message(delegate.problem ?? "xlsxのXMLを解析できません")};return delegate
    }
    private func stop(_ parser:XMLParser,_ text:String){problem=text;parser.abortParsing()}
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        do {try control.check()} catch {stop(parser,"読込を取り消しました／時間上限です");return}
        stack.append(name);text=""
        switch kind {
        case .workbook:if name=="sheet" {items.append(attributes)}
        case .relations:if name=="Relationship" {items.append(attributes)}
        case .strings:if name=="si" {shared=""}
        case .styles:
            if name=="numFmt",let id=attributes["numFmtId"].flatMap(Int.init) {formats[id]=attributes["formatCode"]}
            if name=="xf",stack.contains("cellXfs") {styleIDs.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)}
        case .worksheet:
            if name=="row" {
                row=PCTableRow(number:attributes["r"].flatMap(Int.init) ?? rows.count+1,cells:[]);seenColumns=[]
                if row.number<1 || row.number>PCTableReader.maximumRows || rows.count>=PCTableReader.maximumRows || !seenRows.insert(row.number).inserted {stop(parser,"xlsxの行番号が重複・範囲外です（10,000行まで）")}
            }
            if name=="c" {
                let ref=attributes["r"] ?? "",bytes=Array(ref.utf8),letters=bytes.prefix{(65...90).contains($0)}
                let digits=bytes.dropFirst(letters.count)
                guard !letters.isEmpty,letters.count<=3,!digits.isEmpty,digits.allSatisfy({(48...57).contains($0)}) else {stop(parser,"xlsxのセル参照が不正です");return}
                column=letters.reduce(0){$0*26+Int($1)-64}-1
                guard column>=0,column<PCTableReader.maximumColumns,Int(ref.dropFirst(letters.count))==row.number,seenColumns.insert(column).inserted else {stop(parser,"xlsxのセル位置・重複・列数（64列上限）が不正です");return}
                cellType=attributes["t"] ?? "n";style=attributes["s"].flatMap(Int.init) ?? 0;value="";inline="";formula=false;hasValue=false
            }
            if name=="f" {formula=true}
        }
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) {
        text+=string;if text.utf8.count>PCTableReader.maximumCell {stop(parser,"xlsxのセルが長すぎます")}
    }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
        defer {if !stack.isEmpty{stack.removeLast()};text=""}
        switch kind {
        case .strings:
            if name=="t",!stack.contains("rPh") {shared+=text}
            if name=="si" {if shared.utf8.count>PCTableReader.maximumCell || strings.count>=50_000 {stop(parser,"xlsxの共有文字列が上限を超えています")} else {strings.append(shared)}}
        case .worksheet(let strings,let formats,let styles):
            if name=="v" {value=text;hasValue = !text.isEmpty}
            if name=="t",stack.contains("is"),!stack.contains("rPh") {inline+=text}
            if name=="c" {
                guard column>=0,column<PCTableReader.maximumColumns else {return}
                while row.cells.count<=column {row.cells.append("")}
                var result=value,issue:String?
                if cellType=="s" {if let i=Int(value),strings.indices.contains(i) {result=strings[i]} else {issue="共有文字列を確認できません"}}
                else if cellType=="inlineStr" {result=inline}
                else if !["n","str"].contains(cellType) {issue="エラー／日付／真偽値などのセルは座標に使えません"}
                if formula {if !hasValue {issue="数式の保存済み計算値がありません。表計算側で確認してください"} else {row.notes.append("数式は保存済み計算値を使用（再計算なし）")}}
                if cellType=="n",styles.indices.contains(style) {
                    let id=styles[style],format=formats[id] ?? ""
                    if (14...22).contains(id) || (45...47).contains(id) || format.range(of:"[ymdhs]",options:.caseInsensitive) != nil {issue="日付・時刻形式は座標値として扱いません"}
                    else if !format.isEmpty,format.allSatisfy({$0=="0"}),format.count<=20,let n=Double(value),n.isFinite,n>=0,n<1e15,n.rounded()==n {result=String(format:"%0*.0f",format.count,n)}
                }
                guard result.utf8.count<=PCTableReader.maximumCell else {stop(parser,"xlsxのセルが長すぎます");return}
                row.cells[column]=result;if let issue {row.cellIssues[column]=issue}
            }
            if name=="row",!row.cells.isEmpty {rows.append(row)}
        default:break
        }
    }
}
