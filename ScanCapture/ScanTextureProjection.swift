import Foundation
import simd

struct ScanUV:Codable,Equatable {var u:Double;var v:Double}
struct ScanTextureFace:Codable,Equatable {var indices:[Int];var uv:[ScanUV]?;var reason:String?}
struct ScanTextureProjection:Codable,Equatable {var faces:[[ScanTextureFace]];var textured:Int;var untextured:Int;var reasons:[String:Int]}
enum ScanTextureProjector {
    struct PatchVertex {var weights:SIMD3<Double>;var uv:ScanUV;var z:Double}
    /// OBJ has affine UVs on each face, whereas a sensor image is projective.
    /// Bound their difference in both image axes by 0.5 pixel using
    /// |cov(z,uv)| / E[z] <= range(z)*range(uv)/(4*min(z)).
    /// Midpoint subdivision changes only the derived export, never the sensor mesh.
    static func patches(uv:[ScanUV],z:[Double],width:Int,height:Int,maximum:Int=4096)->[[PatchVertex]]? {
        guard uv.count==3,z.count==3,z.allSatisfy({$0.isFinite && $0>0}),maximum>0 else {return nil}
        var result:[[PatchVertex]]=[]
        func midpoint(_ a:PatchVertex,_ b:PatchVertex)->PatchVertex {
            let sum=a.z+b.z
            return PatchVertex(weights:(a.weights+b.weights)/2,uv:ScanUV(u:(a.uv.u*a.z+b.uv.u*b.z)/sum,v:(a.uv.v*a.z+b.uv.v*b.z)/sum),z:sum/2)
        }
        func split(_ v:[PatchVertex],_ level:Int)->Bool {
            let zs=v.map(\.z),us=v.map { $0.uv.u },vs=v.map { $0.uv.v }
            let scale=(zs.max()!-zs.min()!)/(4*zs.min()!)
            if max((us.max()!-us.min()!)*Double(width),(vs.max()!-vs.min()!)*Double(height))*scale<=0.5 {
                guard result.count<maximum else {return false};result.append(v);return true
            }
            guard level<8 else {return false}
            let ab=midpoint(v[0],v[1]),bc=midpoint(v[1],v[2]),ca=midpoint(v[2],v[0])
            return split([v[0],ab,ca],level+1) && split([ab,v[1],bc],level+1) && split([ca,bc,v[2]],level+1) && split([ab,bc,ca],level+1)
        }
        let basis=[SIMD3<Double>(1,0,0),SIMD3<Double>(0,1,0),SIMD3<Double>(0,0,1)]
        return split((0..<3).map {PatchVertex(weights:basis[$0],uv:uv[$0],z:z[$0])},0) ? result:nil
    }
    private struct Vertex {var pixel:SIMD2<Double>;var grid:SIMD2<Double>;var z:Double;var uv:ScanUV}
    private struct Triangle {var mesh:Int;var face:Int;var indices:[Int];var vertices:[Vertex]?;var front:Bool}
    private enum Budget:Error {case exceeded}
    static func project(_ shape:ScanDerivedSnapshot,frame:ScanFrameInfo,depth:ScanDepthMap?,imageAvailable:Bool,maximumSamples:Int=5_000_000,surface:Bool=false,checkpoint:(()->Bool)?=nil)->ScanTextureProjection {
        let total=shape.meshes.reduce(0){$0+$1.indices.count/12}
        func rejectAll(_ reason:String)->ScanTextureProjection {
            let faces=shape.meshes.map {mesh in stride(from:0,to:mesh.indices.count,by:12).map {i in ScanTextureFace(indices:(0..<3).map {Int(ScanMesh.word(mesh.indices,i+$0*4))},uv:nil,reason:reason)}}
            return ScanTextureProjection(faces:faces,textured:0,untextured:total,reasons:[reason:total])
        }
        guard imageAvailable else {return rejectAll("missing_or_unsupported_image")}
        guard let depth else {return rejectAll("missing_saved_scene_depth")}
        guard (try? depth.validate(frame)) != nil,(try? frame.validate()) != nil,shape.frameID==frame.frameID,shape.time==frame.time,shape.camera.count==16,(try? GCPCaptureEvidence.pose(shape.camera)) != nil,abs(frame.intrinsics[1])+abs(frame.intrinsics[2])+abs(frame.intrinsics[3])+abs(frame.intrinsics[5])+abs(frame.intrinsics[8]-1)<1e-6 else {return rejectAll("mixed_frame_evidence")}
        guard total<=(surface ? 262144:32768) else {return rejectAll("visibility_budget_exceeded")}
        let camera=simd_double4x4((0..<4).map {c in SIMD4((0..<4).map {shape.camera[c*4+$0]})}),inverse=simd_inverse(camera)
        let origin=SIMD3(shape.camera[12],shape.camera[13],shape.camera[14]),k=frame.intrinsics
        var triangles:[Triangle]=[],nearCrossing=false
        for (mi,mesh) in shape.meshes.enumerated() {
            let world=(0..<(mesh.worldVertices.count/24)).map {ScanShape.vector(mesh.worldVertices,$0)}
            let cameras=world.map {v -> SIMD3<Double> in let p=inverse*SIMD4(v,1);return SIMD3(p.x,p.y,p.z)}
            for i in stride(from:0,to:mesh.indices.count,by:12) {
                let indices=(0..<3).map {Int(ScanMesh.word(mesh.indices,i+$0*4))}
                guard indices.allSatisfy({$0<world.count}) else {return rejectAll("invalid_geometry")}
                let a=world[indices[0]],b=world[indices[1]],c=world[indices[2]],normal=simd_cross(b-a,c-a)
                let front=simd_length(normal)>1e-10 && simd_dot(normal,origin-(a+b+c)/3)>1e-10
                let zs=indices.map {-cameras[$0].z}
                if zs.contains(where:{$0>0.05}) && zs.contains(where:{$0<=0.05}) {nearCrossing=true}
                var projected:[Vertex]=[]
                for index in indices {
                    let p=cameras[index],z = -p.z
                    guard z>0.05,z.isFinite else {break}
                    let x=k[0]*p.x/z+k[6],y=k[7]-k[4]*p.y/z
                    guard x.isFinite,y.isFinite else {break}
                    projected.append(Vertex(pixel:SIMD2(x,y),grid:SIMD2(x/Double(frame.width)*Double(depth.width),y/Double(frame.height)*Double(depth.height)),z:z,uv:ScanUV(u:x/Double(frame.width),v:1-y/Double(frame.height))))
                }
                triangles.append(Triangle(mesh:mi,face:i/12,indices:indices,vertices:projected.count==3 ? projected:nil,front:front))
            }
        }
        guard surface || !nearCrossing else {return rejectAll("near_plane_occluder_uncertain")}
        var work=0,zbuffer=Array(repeating:Double.infinity,count:depth.width*depth.height)
        func visit(_ vertices:[Vertex],_ body:(Int,Int,Double)throws->Void) throws -> Int {
            let a=vertices[0].grid,b=vertices[1].grid,c=vertices[2].grid
            func cross(_ u:SIMD2<Double>,_ v:SIMD2<Double>)->Double {u.x*v.y-u.y*v.x}
            let area=cross(b-a,c-a);guard abs(area)>1e-8 else {return 0}
            let left=max(0,Int(max(0,min(Double(depth.width),floor(min(a.x,b.x,c.x)))))),right=min(depth.width-1,Int(max(-1,min(Double(depth.width-1),ceil(max(a.x,b.x,c.x))))))
            let top=max(0,Int(max(0,min(Double(depth.height),floor(min(a.y,b.y,c.y)))))),bottom=min(depth.height-1,Int(max(-1,min(Double(depth.height-1),ceil(max(a.y,b.y,c.y))))))
            guard left<=right,top<=bottom else {return 0}
            var count=0
            for y in top...bottom {for x in left...right {
                work+=1;if work%4096==0,checkpoint?()==false {throw Budget.exceeded};if work>maximumSamples {throw Budget.exceeded}
                let p=SIMD2(Double(x)+0.5,Double(y)+0.5),b0=cross(b-p,c-p)/area,b1=cross(c-p,a-p)/area,b2=1-b0-b1
                if b0>=(-1e-8),b1>=(-1e-8),b2>=(-1e-8) {
                    let z=1/(b0/vertices[0].z+b1/vertices[1].z+b2/vertices[2].z)
                    if z.isFinite,z>0 {try body(x,y,z);count+=1}
                }
            }}
            return count
        }
        // All triangles, including back faces, are potential occluders. Incomplete rasterization rejects every texture.
        do {for t in triangles {if let v=t.vertices {_=try visit(v) {x,y,z in zbuffer[y*depth.width+x]=min(zbuffer[y*depth.width+x],z)}}}} catch {return rejectAll("visibility_budget_exceeded")}
        func depthIssue(_ x:Int,_ y:Int,_ predicted:Double)->String? {
            guard x>0,y>0,x<depth.width-1,y<depth.height-1 else {return "depth_boundary_unknown"}
            let z=depth.z(x,y)
            guard z.isFinite,z>0.1,z<=8,depth.confidence[y*depth.width+x]==2 else {return "invalid_or_low_confidence_depth"}
            for yy in (y-1)...(y+1) {for xx in (x-1)...(x+1) {
                let value=depth.z(xx,yy)
                guard depth.confidence[yy*depth.width+xx]==2,value.isFinite,value>0.1,abs(value-z)<=max(0.03,z*0.015) else {return "depth_edge_or_uncertain_neighbourhood"}
            }}
            let px=(Double(x)+0.5)/Double(depth.width)*Double(frame.width),py=(Double(y)+0.5)/Double(depth.height)*Double(frame.height)
            let range=z*sqrt(1+pow((px-k[6])/k[0],2)+pow((py-k[7])/k[4],2))
            guard range<=8 else {return "depth_range_unverified"}
            let tolerance=max(0.03,0.02*z)
            if predicted>z+tolerance {return "occluded_by_measured_depth"}
            if predicted<z-tolerance {return "mesh_depth_disagreement"}
            if predicted>zbuffer[y*depth.width+x]+0.005 {return "occluded_by_mesh"}
            return nil
        }
        var faces=shape.meshes.map {_ in [ScanTextureFace]()},textured=0,reasons:[String:Int]=[:],exportFaces=0
        do {
            for t in triangles {
                if checkpoint?()==false {throw Budget.exceeded}
                var reason:String?,uv:[ScanUV]?
                if t.vertices==nil {reason="behind_camera"}
                else if !t.front {reason="back_facing_or_degenerate"}
                else if let v=t.vertices {
                    if v.contains(where:{$0.uv.u<0 || $0.uv.u>=1 || $0.uv.v<=0 || $0.uv.v>1}) {reason="outside_image"}
                    else {
                        let count=try visit(v) {x,y,z in if reason==nil {reason=depthIssue(x,y,z)}}
                        if reason==nil {
                            for p in v {if let issue=depthIssue(Int(p.grid.x),Int(p.grid.y),p.z) {reason=issue;break}}
                        }
                        // Preserve an observed depth/occlusion failure; sparse sampling must not hide it.
                        if reason==nil,count<3 {reason="subpixel_visibility_unknown"}
                        if reason==nil {
                            if surface {uv=v.map(\.uv)}
                            else if let patches=patches(uv:v.map(\.uv),z:v.map(\.z),width:frame.width,height:frame.height,maximum:min(4096,262144-exportFaces)) {
                                uv=v.map(\.uv);exportFaces+=patches.count
                            } else {reason="projective_uv_budget_exceeded"}
                        }
                    }
                } else {reason="behind_camera"}
                if let reason {reasons[reason,default:0]+=1} else {textured+=1}
                faces[t.mesh].append(ScanTextureFace(indices:t.indices,uv:uv,reason:reason))
            }
        } catch {return rejectAll("visibility_budget_exceeded")}
        return ScanTextureProjection(faces:faces,textured:textured,untextured:total-textured,reasons:reasons)
    }
}
