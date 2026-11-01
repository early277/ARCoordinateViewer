import Foundation
import simd

/// Disposable display of committed originals. No inferred surfaces or persistent edits.
struct ScanPreviewGeometry {
    var positions:[SIMD3<Float>]=[]
    var normals:[SIMD3<Float>]=[]
    var indices:[UInt32]=[]
    var sourceFaces=0
    var omittedFaces=0
}
struct ScanPreviewPoint:Equatable {
    var id:UUID
    var number:Int
    var position:SIMD3<Float>
}
struct ScanPreviewState {
    static let maximumFaces=12_000
    static let maximumPoints=64
    let token:UUID
    let epoch:GCPEpoch
    let segmentID:UUID
    private(set) var sequence=0
    private(set) var meshes:[UUID:ScanMesh]=[:]
    private(set) var geometry=ScanPreviewGeometry()
    private(set) var points:[ScanPreviewPoint]=[]
    private(set) var totalPoints=0
    private(set) var geometryRevision=0

    /// Called on the serial save worker, after append/fsync has succeeded.
    mutating func accept(_ packet:ScanPacket) throws {
        guard packet.epoch==epoch,packet.segmentID==segmentID,packet.sequence>sequence else {return}
        if !packet.meshes.isEmpty {
            var next=meshes
            for change in packet.meshes {next[change.anchorID]=change.mesh}
            let built=try Self.geometry(Array(next.values))
            meshes=next;geometry=built;geometryRevision+=1
        }
        let matching=packet.raw.points.enumerated().filter {$0.element.epoch==epoch}
        totalPoints=matching.count
        let offset=try packet.corrections.map {try ScanCorrection.offset($0,raw:packet.raw,segmentID:segmentID,epoch:epoch,time:packet.time)} ?? GCPVector()
        points=matching.prefix(Self.maximumPoints).map {index,point in
            // Same target as automatic matching: reference point back into current raw AR space.
            ScanPreviewPoint(id:point.id,number:index+1,position:SIMD3<Float>(point.position.v-offset.v))
        }
        guard points.allSatisfy({$0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite}) else {throw ScanFailure.invalidGeometry}
        sequence=packet.sequence
    }

    static func geometry(_ meshes:[ScanMesh],maximumFaces:Int=Self.maximumFaces) throws -> ScanPreviewGeometry {
        guard maximumFaces>0,maximumFaces<=Self.maximumFaces,meshes.count<=ScanLimits().maximumAnchors else {throw ScanFailure.capacity}
        var output=ScanPreviewGeometry()
        let sorted=meshes.sorted {$0.anchorID.uuidString<$1.anchorID.uuidString}
        var vertices=0,indices=0
        for mesh in sorted {
            try mesh.validate(ScanLimits());vertices+=mesh.vertices.count/12;indices+=mesh.indices.count/4
            guard vertices<=ScanLimits().maximumVertices,indices<=ScanLimits().maximumIndices else {throw ScanFailure.capacity}
            output.sourceFaces+=mesh.indices.count/12
        }
        // Select existing faces evenly; never bridge gaps or create a larger triangle.
        let strideBy=max(1,Int(ceil(Double(output.sourceFaces)/Double(maximumFaces))))
        var ordinal=0
        for mesh in sorted {
            let m=mesh.transform
            func world(_ index:UInt32)->SIMD3<Double> {
                let p=Int(index)*12
                let x=Double(Float(bitPattern:ScanMesh.word(mesh.vertices,p)))
                let y=Double(Float(bitPattern:ScanMesh.word(mesh.vertices,p+4)))
                let z=Double(Float(bitPattern:ScanMesh.word(mesh.vertices,p+8)))
                return SIMD3(m[0]*x+m[4]*y+m[8]*z+m[12],m[1]*x+m[5]*y+m[9]*z+m[13],m[2]*x+m[6]*y+m[10]*z+m[14])
            }
            for face in 0..<(mesh.indices.count/12) {
                defer {ordinal+=1}
                guard ordinal%strideBy==0 else {continue}
                let a=world(ScanMesh.word(mesh.indices,face*12)),b=world(ScanMesh.word(mesh.indices,face*12+4)),c=world(ScanMesh.word(mesh.indices,face*12+8))
                guard [a,b,c].allSatisfy({p in [p.x,p.y,p.z].allSatisfy {Float($0).isFinite}}) else {throw ScanFailure.invalidGeometry}
                let normal=simd_cross(b-a,c-a),length=simd_length(normal)
                guard length.isFinite,length>max(1e-12,max(simd_length_squared(b-a),simd_length_squared(c-a))*1e-10) else {continue}
                let start=UInt32(output.positions.count)
                output.positions += [SIMD3<Float>(a),SIMD3<Float>(b),SIMD3<Float>(c)]
                output.normals += Array(repeating:SIMD3<Float>(normal/length),count:3)
                output.indices += [start,start+1,start+2]
            }
        }
        output.omittedFaces=output.sourceFaces-output.indices.count/3
        return output
    }
}
