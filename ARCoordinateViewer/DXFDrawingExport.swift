import Foundation
import simd

/// Confirmed points already live in the diagram's local ENU frame: capture applied
/// inverse(root) once. Export must not apply the current display pan/rotation again.
enum DXFDrawingExport {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    static func rebase(_ drawing:DrawingState,from oldOrigin:GeoCoordinate,to newOrigin:GeoCoordinate) throws -> DrawingState {
        try drawing.mappingPoints { point in
            guard point.y.isFinite else { throw Failure(message:"作図の高さが不正です") }
            let geo=try coordinate(east:Double(point.x),north:-Double(point.z),origin:oldOrigin)
            let next=CoordinateConverter.enuMeters(from:geo,origin:newOrigin)
            guard next.east.isFinite,next.north.isFinite,hypot(next.east,next.north)<100_000 else {
                throw Failure(message:"作図から離れすぎています。立ち位置を確認してください")
            }
            return SIMD3(Float(next.east),point.y,-Float(next.north))
        }
    }
    static func coordinate(east:Double,north:Double,origin:GeoCoordinate) throws -> GeoCoordinate {
        guard east.isFinite, north.isFinite, hypot(east,north) < 100_000,
              origin.latitude.isFinite, origin.longitude.isFinite,
              abs(origin.latitude) < 85, abs(origin.longitude) <= 180 else {
            throw Failure(message:"原点または作図座標を確認してください")
        }
        var result = CoordinateConverter.coordinate(fromEast:east,north:north,origin:origin)
        // Invert the production ECEF->ENU XY projection, rather than treating its
        // tangent-plane metres as projected CAD metres or using the linear estimate.
        for _ in 0..<8 {
            let v = CoordinateConverter.enuMeters(from:result,origin:origin)
            let de = east-v.east, dn = north-v.north
            if hypot(de,dn) < 0.00001 { return result }
            let step = 0.000001
            var lat = result, lon = result
            lat.latitude += step; lon.longitude += step
            let a = CoordinateConverter.enuMeters(from:lat,origin:origin)
            let b = CoordinateConverter.enuMeters(from:lon,origin:origin)
            let aE=(a.east-v.east)/step, aN=(a.north-v.north)/step
            let bE=(b.east-v.east)/step, bN=(b.north-v.north)/step
            let determinant=aE*bN-bE*aN
            guard determinant.isFinite, abs(determinant)>1 else { break }
            result.latitude += (de*bN-bE*dn)/determinant
            result.longitude += (aE*dn-de*aN)/determinant
        }
        throw Failure(message:"作図座標を元図面へ変換できません")
    }
    static func encode(paths:[DrawingPath],origin:GeoCoordinate,reference:DXFCoordinateReference,heightDatum:Double?,planar:Bool) throws -> Data {
        guard (1...19).contains(reference.planeSystem), reference.metersPerUnit.isFinite,
              reference.metersPerUnit > 0, reference.insertionUnits.map({ (0...24).contains($0) }) ?? true else { throw Failure(message:"元DXFの座標系・単位を指定してください") }
        guard heightDatum == nil || heightDatum?.isFinite == true else { throw Failure(message:"基準点の標高を確認してください") }
        let paths=paths.filter { !$0.points.isEmpty }.flatMap { path -> [DrawingPath] in
            if !path.isPointCollection { return [path] }
            return path.points.indices.map { index in
                let info=path.vertices.flatMap { $0.indices.contains(index) ? [$0[index]] : nil }
                return DrawingPath(points:[path.points[index]],kind:.points,vertices:info)
            }
        }
        guard !paths.isEmpty else { throw Failure(message:"書き出す作図点がありません") }
        var output=""
        func pair(_ code:Int,_ value:String) { output += "\(code)\n\(value)\n" }
        func number(_ value:Double) throws -> String {
            guard value.isFinite, abs(value)<1e12 else { throw Failure(message:"DXF座標の範囲を確認してください") }
            return String(format:"%.9f",locale:Locale(identifier:"en_US_POSIX"),value)
        }
        func vertex(_ point:SIMD3<Float>,elevation:Double?) throws {
            guard point.y.isFinite else { throw Failure(message:"作図の高さが不正です") }
            let geo=try coordinate(east:Double(point.x),north:-Double(point.z),origin:origin)
            let projected=try JapanesePlaneRectangularSystem.fromGeodetic(system:reference.planeSystem,latitude:geo.latitude,longitude:geo.longitude)
            let x=reference.xIsEasting ? projected.y : projected.x
            let y=reference.xIsEasting ? projected.x : projected.y
            pair(10,try number(x/reference.metersPerUnit))
            pair(20,try number(y/reference.metersPerUnit))
            let height=planar ? 0 : (elevation ?? heightDatum.map { $0+Double(point.y) })
            guard let height else { throw Failure(message:"標高が不明な点があります。高さの扱いを選んでください") }
            pair(30,try number(height/reference.metersPerUnit))
        }
        pair(0,"SECTION"); pair(2,"HEADER")
        pair(9,"$ACADVER"); pair(1,"AC1015")
        let entityCount=paths.reduce(0) { $0 + ($1.points.count==1 ? 1 : $1.points.count+2) }
        pair(9,"$HANDSEED"); pair(5,String(0x100+entityCount,radix:16).uppercased())
        pair(9,"$INSUNITS"); pair(70,reference.insertionUnits.map(String.init) ?? (reference.metersPerUnit == 1 ? "6" : (reference.metersPerUnit == 0.001 ? "4" : "0")))
        pair(9,"$INSBASE"); pair(10,"0"); pair(20,"0"); pair(30,"0")
        pair(999,"Japanese plane system \(reference.planeSystem); metres/unit \(reference.metersPerUnit); CAD X \(reference.xIsEasting ? "east" : "north")")
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        pair(999,DXFParser.drawingReferencePrefix+String(decoding:try encoder.encode(reference),as:UTF8.self))
        pair(0,"ENDSEC")
        pair(0,"SECTION"); pair(2,"TABLES")
        func table(_ name:String,_ handle:String,_ count:Int) {
            pair(0,"TABLE"); pair(2,name); pair(5,handle); pair(330,"0"); pair(100,"AcDbSymbolTable"); pair(70,String(count))
        }
        table("LTYPE","1",1)
        pair(0,"LTYPE"); pair(5,"2"); pair(330,"1"); pair(100,"AcDbSymbolTableRecord"); pair(100,"AcDbLinetypeTableRecord")
        pair(2,"CONTINUOUS"); pair(70,"0"); pair(3,"Solid line"); pair(72,"65"); pair(73,"0"); pair(40,"0")
        pair(0,"ENDTAB")
        table("LAYER","3",2)
        for (name,handle,color) in [("0","4","7"),("AR_DRAWING","5","30")] {
            pair(0,"LAYER"); pair(5,handle); pair(330,"3"); pair(100,"AcDbSymbolTableRecord"); pair(100,"AcDbLayerTableRecord")
            pair(2,name); pair(70,"0"); pair(62,color); pair(6,"CONTINUOUS")
        }
        pair(0,"ENDTAB")
        table("BLOCK_RECORD","6",2)
        for (name,handle) in [("*Model_Space","7"),("*Paper_Space","8")] {
            pair(0,"BLOCK_RECORD"); pair(5,handle); pair(330,"6"); pair(100,"AcDbSymbolTableRecord"); pair(100,"AcDbBlockTableRecord"); pair(2,name)
        }
        pair(0,"ENDTAB"); pair(0,"ENDSEC")
        pair(0,"SECTION"); pair(2,"BLOCKS")
        for (name,owner,begin,end) in [("*Model_Space","7","9","A"),("*Paper_Space","8","B","C")] {
            pair(0,"BLOCK"); pair(5,begin); pair(330,owner); pair(100,"AcDbEntity"); pair(8,"0"); pair(100,"AcDbBlockBegin")
            pair(2,name); pair(70,"0"); pair(10,"0"); pair(20,"0"); pair(30,"0"); pair(3,name); pair(1,"")
            pair(0,"ENDBLK"); pair(5,end); pair(330,owner); pair(100,"AcDbEntity"); pair(8,"0"); pair(100,"AcDbBlockEnd")
        }
        pair(0,"ENDSEC")
        pair(0,"SECTION"); pair(2,"ENTITIES")
        var nextHandle=0x100
        func entity(_ type:String,owner:String="7") -> String {
            let handle=String(nextHandle,radix:16).uppercased(); nextHandle+=1
            pair(0,type); pair(5,handle); pair(330,owner); pair(100,"AcDbEntity"); pair(8,"AR_DRAWING")
            return handle
        }
        for path in paths {
            func elevation(_ index:Int) -> Double? {
                path.vertices.flatMap { $0.indices.contains(index) ? $0[index].elevation : nil }
            }
            if path.points.count == 1 {
                _=entity("POINT"); pair(100,"AcDbPoint")
                try vertex(path.points[0],elevation:elevation(0))
            } else {
                let polylineHandle=entity("POLYLINE")
                pair(100,"AcDb3dPolyline"); pair(66,"1"); pair(70,"8")
                pair(10,"0"); pair(20,"0"); pair(30,"0")
                for (index,point) in path.points.enumerated() {
                    _=entity("VERTEX",owner:polylineHandle)
                    pair(100,"AcDbVertex"); pair(100,"AcDb3dPolylineVertex"); pair(70,"32")
                    try vertex(point,elevation:elevation(index))
                }
                _=entity("SEQEND",owner:polylineHandle)
            }
        }
        pair(0,"ENDSEC"); pair(0,"EOF")
        return Data(output.utf8)
    }
}
