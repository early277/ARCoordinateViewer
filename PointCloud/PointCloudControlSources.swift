import Foundation

/// A copied catalogue, not a live reference to the imported layer. AR slide/yaw
/// display adjustments are deliberately excluded from the coordinate source.
struct PCExistingCoordinate:Identifiable {
    var id:String
    var name:String
    var source:String
    var latitude:Double
    var longitude:Double
    var north:Double?
    var east:Double?
    var planeSystem:Int?
    var height:Double?
    var note:String
    static func catalogue(_ layers:[ImportedDataLayer])->[PCExistingCoordinate] {
        var result:[PCExistingCoordinate]=[]
        for layer in layers {for (i,p) in layer.points.enumerated() {
            if result.count>=5000 {return result}
            let ambiguousDXFZero=p.dxfAltitude==0
            let height=ambiguousDXFZero ? nil:p.drawingSourceAltitude
            result.append(PCExistingCoordinate(id:layer.documentID.uuidString+"/"+p.id.uuidString,name:p.name ?? "点\(i+1)",source:layer.name,latitude:p.latitude,longitude:p.longitude,north:p.planeNorth,east:p.planeEast,planeSystem:p.planeSystem,height:height,note:ambiguousDXFZero ? "DXFの0高は明示値か判別できないため高さ未指定":"元ファイルの高さ基準は要確認"))
        }}
        return result
    }
    func point(reference:PCControlReference)throws->PCKnownPoint {
        guard reference.valid else {throw PCControlFailure.reference}
        let n:Double,e:Double,method:String
        if let north,let east,let planeSystem {
            guard planeSystem==reference.planeSystem else {throw PCControlFailure.reference}
            n=north;e=east;method="元の平面直角座標"
        } else {
            guard reference.datum != "任意座標" else {throw PCControlFailure.reference}
            let q=try JapanesePlaneRectangularSystem.fromGeodetic(system:reference.planeSystem,latitude:latitude,longitude:longitude)
            n=q.x;e=q.y;method="既存緯度経度からGRS80投影。測地系・元データ基準は本人確認。測地系変換は未実施"
        }
        let point=PCKnownPoint(name:name,north:n,east:e,height:height,planeSystem:reference.planeSystem,source:source,sourceID:id,originalCells:[name,String(latitude),String(longitude),north.map{String($0)} ?? "",east.map{String($0)} ?? "",height.map{String($0)} ?? ""],importDetails:method+"; "+note)
        guard point.finite else {throw PCControlFailure.invalid};return point
    }
}
