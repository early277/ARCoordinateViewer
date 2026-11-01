import Foundation
import simd

struct DrawingExportDocument:Identifiable {
    var id:String
    var name:String
    var reference:DXFCoordinateReference?
    var planar:Bool
}
struct DrawingExportAnchor:Identifiable {
    var id:UUID
    var name:String
    var position:SIMD3<Float>
    var info:DrawingVertexInfo
}
struct DrawingExportSnapshot {
    var paths:[DrawingPath]
    var origin:GeoCoordinate
    var reference:DXFCoordinateReference
    var datum:Double?
    var planar:Bool
    func encode() throws -> Data {
        try DXFDrawingExport.encode(paths:paths,origin:origin,reference:reference,heightDatum:datum,planar:planar)
    }
}

extension AppModel {
    var drawingExportDocuments:[DrawingExportDocument] {
        var seen=Set<UUID>()
        let roots=layers.filter { seen.insert($0.documentID).inserted }
        if roots.isEmpty { return [DrawingExportDocument(id:"work",name:"現在の作図",reference:nil,planar:false)] }
        return roots.enumerated().map { index, layer in
            let name=layer.name.components(separatedBy:" / ").first ?? layer.name
            let duplicate=roots.filter { $0.name.components(separatedBy:" / ").first == name }.count > 1
            let group=layers.filter { $0.documentID==layer.documentID }
            return DrawingExportDocument(id:layer.documentID.uuidString,name:duplicate ? "\(name)（\(index+1)）" : name,
                reference:layer.dxfReference,planar:group.allSatisfy { $0.dxfReference != nil && $0.constantDXFAltitude == 0 })
        }
    }
    var drawingExportAnchors:[DrawingExportAnchor] {
        (drawing.completed+[drawing.draft]).enumerated().flatMap { pathIndex,path in
            path.points.indices.compactMap { index in
                guard let vertices=path.vertices, vertices.indices.contains(index) else { return nil }
                let name=path.points.count==1 ? "点 \(pathIndex+1)" : "\(path.isPointCollection ? "点群" : "線") \(pathIndex+1)・\(index+1)点目"
                return DrawingExportAnchor(id:vertices[index].id,name:name,position:path.points[index],info:vertices[index])
            }
        }
    }
    func drawingExportProfile(for document:DrawingExportDocument) -> DrawingExportProfile {
        drawingExportProfiles[document.id] ?? DrawingExportProfile(reference:document.reference)
    }
    func makeDrawingExportSnapshot(document:DrawingExportDocument,profile:DrawingExportProfile) throws -> DrawingExportSnapshot {
        guard canEditWork, let origin else { throw DXFDrawingExport.Failure(message:"立ち位置を設定してください") }
        guard drawingExportDocuments.contains(where:{ $0.id==document.id }), let reference=profile.reference else {
            throw DXFDrawingExport.Failure(message:"元図面の座標設定を確認してください")
        }
        let paths=drawing.completed+[drawing.draft]
        let planar=profile.heightMode == .planar || (profile.heightMode == .automatic && document.planar)
        var datum:Double?
        if profile.heightMode == .referencePoint {
            guard let anchor=drawingExportAnchors.first(where:{ $0.id==profile.anchorID }) else {
                throw DXFDrawingExport.Failure(message:"標高の基準にする作図点を選んでください")
            }
            let elevation=anchor.info.elevationSource == .sourceDrawing ? anchor.info.elevation : profile.anchorAltitude
            guard let elevation, elevation.isFinite else { throw DXFDrawingExport.Failure(message:"基準点の標高を入力してください") }
            datum=elevation-Double(anchor.position.y)
        }
        if !planar && datum == nil {
            for path in paths { for index in path.points.indices {
                guard let vertices=path.vertices, vertices.indices.contains(index),
                      let height=vertices[index].elevation, height.isFinite else {
                    throw DXFDrawingExport.Failure(message:"観測点の標高基準が不明です。高さの扱いを選んでください")
                }
            } }
        }
        return DrawingExportSnapshot(paths:paths,origin:origin,reference:reference,datum:datum,planar:planar)
    }
}
