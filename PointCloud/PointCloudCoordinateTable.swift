import Foundation

struct PCReviewRow:Identifiable,Equatable {
    var id=UUID()
    var line:Int
    var cells:[String] // name, X, Y, Z in the displayed input unit/axis order
    var initial:[String]
    var cellIssues:[Int:String]=[:]
    var lockedIssues:[String]=[]
    var originalCells:[String]
    var source:String
    var sourceID:String
    var details:String
    var existing:PCKnownPoint?
}
struct PCReviewTable:Identifiable {
    var id=UUID()
    var rows:[PCReviewRow]
    var xIsNorth=true
    var metresPerUnit=1.0
    var planeSystem:Int
    static func points(_ points:[PCKnownPoint],planeSystem:Int)->PCReviewTable {
        PCReviewTable(rows:points.enumerated().map{i,p in
            let cells=[p.name,String(p.north),String(p.east),p.height.map{String($0)} ?? ""]
            return PCReviewRow(id:p.id,line:i+1,cells:cells,initial:cells,lockedIssues:p.planeSystem==planeSystem ? []:["この点は\(p.planeSystem)系です。現在の\(planeSystem)系へは自動変換しません。元の基準を確認して再取込してください"],originalCells:p.originalCells,source:p.source,sourceID:p.sourceID,details:p.importDetails,existing:p)
        },planeSystem:planeSystem)
    }
    static func source(_ doc:PCTableDocument,mapping:PCTableMapping,planeSystem:Int)throws->PCReviewTable {
        let indices=[mapping.name,Optional(mapping.x),Optional(mapping.y),mapping.height]
        let used=indices.compactMap{$0}
        guard Set(used).count==used.count,used.allSatisfy({$0>=0 && $0<64}) else {throw PCTableFailure.message("列の割当が重複・範囲外です")}
        let data=mapping.header ? Array(doc.rows.dropFirst()):doc.rows
        guard data.count<=5000 else {throw PCTableFailure.message("編集は5,000点までです。表を分割してください")}
        let rows=data.map{row -> PCReviewRow in
            let cells=indices.enumerated().map {i,col -> String in
                guard let col else{return i==0 ? "行\(row.number)":""};return row.cells.indices.contains(col) ? row.cells[col]:""
            }
            var issues:[Int:String]=[:]
            for (i,col) in indices.enumerated(){if let col,let issue=row.cellIssues[col]{issues[i]=issue}}
            var locked=row.rowIssues
            if mapping.header,row.cells.count>(doc.rows.first?.cells.count ?? 0){locked.append("ヘッダーより列が多いため、区切りを確認して再読込してください")}
            return PCReviewRow(line:row.number,cells:cells,initial:cells,cellIssues:issues,lockedIssues:locked,originalCells:row.originalCells ?? row.cells,source:doc.source+" / "+doc.sheetNames[doc.sheetIndex],sourceID:doc.hash+"/\(doc.sheetIndex)/\(row.number)",details:"\(doc.encoding); row \(row.number); columns name=\(mapping.name.map{String($0)} ?? "none"),X=\(mapping.x),Y=\(mapping.y),H=\(mapping.height.map{String($0)} ?? "none"); X-is-north=\(mapping.xIsNorth); metres/unit=\(mapping.metresPerUnit)")
        }
        return PCReviewTable(rows:rows,xIsNorth:mapping.xIsNorth,metresPerUnit:mapping.metresPerUnit,planeSystem:planeSystem)
    }
    func validate(control:PCWorkControl=PCWorkControl())throws->(points:[PCKnownPoint],errors:[UUID:String],warnings:[String]) {
        guard rows.count<=5000,(1...19).contains(planeSystem),[1.0,0.01,0.001,0.3048].contains(metresPerUnit) else {throw PCControlFailure.invalid}
        var points:[PCKnownPoint]=[],errors:[UUID:String]=[:],names=Set<String>(),sources=Set<String>(),warnings:[String]=[]
        for row in rows {
            try control.check()
            guard row.cells.count==4,row.cells.allSatisfy({$0.utf8.count<=4096}) else {errors[row.id]="セル長または列数が不正です";continue}
            let issues=row.lockedIssues+row.cellIssues.compactMap{i,error in row.cells[i]==row.initial[i] ? error:nil}
            guard issues.isEmpty else {errors[row.id]=issues.joined(separator:" / ");continue}
            let cells=row.cells.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
            guard !cells[0].isEmpty,let x=PCTableReader.number(cells[1]),let y=PCTableReader.number(cells[2]) else {errors[row.id]="点名・X・Yを確認してください";continue}
            let h=PCTableReader.number(cells[3])
            guard cells[3].isEmpty || h != nil else{errors[row.id]="高さは数値または空欄です";continue}
            guard sources.insert(row.sourceID).inserted else{errors[row.id]="元データのIDが重複しています";continue}
            if !names.insert(cells[0]).inserted {warnings.append("行\(row.line): 点名「\(cells[0])」が重複しています")}
            var p=row.existing ?? PCKnownPoint(id:row.id,name:cells[0],north:0,east:0,height:nil,planeSystem:planeSystem,source:row.source,sourceID:row.sourceID,originalCells:row.originalCells,importDetails:row.details)
            p.name=cells[0];p.north=(xIsNorth ? x:y)*metresPerUnit;p.east=(xIsNorth ? y:x)*metresPerUnit;p.height=h.map{$0*metresPerUnit}
            if row.cells != row.initial {
                p.reviewedCells=row.cells
                p.reviewDetails="Explicit table edit; X-is-north=\(xIsNorth); metres/unit=\(metresPerUnit); plane=\(p.planeSystem). Original import mapping retained separately."
            }
            guard p.finite else{errors[row.id]="座標の範囲を確認してください";continue}
            points.append(p)
        }
        return(points,errors,Array(warnings.prefix(100)))
    }
}
