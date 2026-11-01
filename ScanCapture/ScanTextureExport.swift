import Foundation
import ImageIO
import simd

struct ScanTextureDepthEvidence:Codable,Equatable {var width:Int;var height:Int;var cameraZChecksum:UInt64;var confidenceChecksum:UInt64}
struct ScanTexturedSnapshot:Codable,Equatable {
    var sourceFrame:ScanFrameInfo
    var depthEvidence:ScanTextureDepthEvidence?
    var raw:ScanDerivedSnapshot
    var corrected:ScanDerivedSnapshot
    var projection:ScanTextureProjection
    var imageFile:String?
    var imageIssue:String?
}
struct ScanTextureDocument:Codable,Equatable {
    var schema=1
    var sessionID:UUID
    var units="metres"
    var coordinates="ARKit local right-handed Y-up; separate unregistered submaps"
    var sourcePolicy="latest keyframe per submap; original sensor image, unrotated; OBJ v=1-imageY/imageHeight"
    var snapshots:[ScanTexturedSnapshot]
    var limitations:[String]
}
struct ScanTextureResult {var url:URL;var textured:Int;var untextured:Int}
enum ScanTextureExport {
    static func make(archive:ScanArchive,id:UUID,root:URL?=nil,hook:((String)throws->Void)?=nil) throws -> ScanTextureResult {
        guard archive.freeBytes()>=Int64(archive.limits.minimumFreeBytes) else {throw ScanFailure.lowSpace}
        struct Source {var frame:ScanFrameInfo;var epoch:GCPEpoch;var meshes:[UUID:ScanMesh];var depth:ScanDepthMap?;var directory:URL}
        var sources:[UUID:Source]=[:],active:[UUID:ScanMesh]=[:],segment:UUID?,epoch:GCPEpoch?
        let last=try archive.visit(id) {p,url in
            guard p.hasImage,let frame=p.frame else {return}
            if segment != p.segmentID || epoch != p.epoch {active=[:];segment=p.segmentID;epoch=p.epoch}
            for m in p.meshes {if let mesh=m.mesh {active[m.anchorID]=mesh} else {active.removeValue(forKey:m.anchorID)}}
            sources[p.segmentID]=Source(frame:frame,epoch:p.epoch,meshes:active,depth:p.depthMap,directory:url)
            guard sources.count<=16,sources.values.reduce(0,{$0+$1.meshes.values.reduce(0,{$0+$1.vertices.count})})<=12*262144 else {throw ScanFailure.capacity}
        }
        guard !sources.isEmpty else {throw ScanFailure.incomplete}
        let state=last.corrections ?? ScanCorrection.empty(id);try ScanCorrection.validate(state,raw:last.raw)
        let (geometry,_)=try ScanShapeExport.build(archive:archive,id:id)
        var files:[String:Data]=[:],snapshots:[ScanTexturedSnapshot]=[],textured=0,untextured=0
        for (segment,source) in sources.sorted(by:{$0.key.uuidString<$1.key.uuidString}) {
            let meshes=Array(source.meshes.values)
            let raw=try ScanShape.make(meshes:meshes,frame:source.frame,segmentID:segment,epoch:source.epoch,state:ScanCorrection.empty(id),raw:last.raw,limits:archive.limits)
            let corrected=try ScanShape.make(meshes:meshes,frame:source.frame,segmentID:segment,epoch:source.epoch,state:state,raw:last.raw,limits:archive.limits)
            let imageName="texture-"+source.frame.frameID.uuidString+".png"
            var png:Data?,imageIssue:String?
            if let info=source.frame.imageInfo {
                do {png=try ScanImageCodec.png(original:Data(contentsOf:source.directory.appendingPathComponent("image.nv12")),info:info,limits:archive.limits)}
                catch {imageIssue="Original pixels retained but PNG conversion unsupported: "+ScanErrorMessage.text(error)}
            } else {imageIssue="Original image layout missing"}
            var projection=ScanTextureProjector.project(raw,frame:source.frame,depth:source.depth,imageAvailable:png != nil)
            let correctedProjection=ScanTextureProjector.project(corrected,frame:source.frame,depth:source.depth,imageAvailable:png != nil)
            // Both variants must agree. A numerical boundary disagreement stays explicitly untextured.
            for mi in projection.faces.indices {for fi in projection.faces[mi].indices {
                if let a=projection.faces[mi][fi].uv {
                    let b=correctedProjection.faces[mi][fi].uv
                    if b==nil || !zip(a,b!).allSatisfy({abs($0.u-$1.u)<1e-8 && abs($0.v-$1.v)<1e-8}) {
                        projection.faces[mi][fi].uv=nil;projection.faces[mi][fi].reason="correction_projection_disagreement"
                        projection.textured-=1;projection.untextured+=1;projection.reasons["correction_projection_disagreement",default:0]+=1
                    }
                }
            }}
            let usedImage=projection.textured>0 ? imageName:nil
            if let usedImage,let png {files[usedImage]=png}
            let material="materials-"+segment.uuidString+".mtl"
            files[material]=Data(mtl(image:usedImage).utf8)
            files["raw-"+segment.uuidString+".obj"]=try obj(raw,projection:projection,material:material,frame:source.frame)
            files["corrected-"+segment.uuidString+".obj"]=try obj(corrected,projection:projection,material:material,frame:source.frame)
            snapshots.append(ScanTexturedSnapshot(sourceFrame:source.frame,depthEvidence:source.depth.map {ScanTextureDepthEvidence(width:$0.width,height:$0.height,cameraZChecksum:GCPStore.checksum($0.cameraZBits),confidenceChecksum:GCPStore.checksum($0.confidence))},raw:raw,corrected:corrected,projection:projection,imageFile:usedImage,imageIssue:imageIssue))
            textured+=projection.textured;untextured+=projection.untextured
            guard files.values.reduce(0,{$0+$1.count})<=ScanShapeExport.maximumBytes else {throw ScanFailure.capacity}
        }
        let limits=geometry.limitations+["Texture is visibility-tested at saved sceneDepth resolution only; subpixel/thin occluders remain unverified", "Requires same-frame full sceneDepth and high-confidence stable neighbourhoods; older missing depth is never invented", "One simultaneous image per latest submap snapshot; no multi-view atlas or nonrigid fused-vertex correction", "Derived OBJ faces are subdivided to bound affine UV error to 0.5 source pixel per axis; capped at 4096 patches per face and 262144 textured patches per snapshot", "Gray material explicitly marks back/outside/occluded/missing/uncertain/budget-rejected faces"]
        let document=ScanTextureDocument(sessionID:id,snapshots:snapshots,limitations:limits),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        files["texture.json"]=try encoder.encode(document);files["gcp.json"]=try encoder.encode(ScanGCPDocument(raw:last.raw,corrections:state));files["gcp.csv"]=ScanShapeExport.csv(last.raw)
        let url=try ScanOutput.write(files:files,root:root ?? archive.root.deletingLastPathComponent().appendingPathComponent("LiDARScanTextureExports",isDirectory:true),freeBytes:archive.freeBytes,minimumFree:archive.limits.minimumFreeBytes,textureStatus:"snapshot projective PNG; \(textured) textured, \(untextured) untextured faces",hook:hook)
        return ScanTextureResult(url:url,textured:textured,untextured:untextured)
    }
    static func mtl(image:String?)->String {
        var text="# Untextured faces are deliberate, not successful image projection\nnewmtl untextured\nKd 0.55 0.55 0.55\nKa 0.55 0.55 0.55\nKs 0 0 0\nillum 0\n"
        if let image {text+="newmtl captured_image\nKd 1 1 1\nKa 1 1 1\nKs 0 0 0\nillum 0\nmap_Kd \(image)\n"};return text
    }
    static func obj(_ shape:ScanDerivedSnapshot,projection:ScanTextureProjection,material:String,frame:ScanFrameInfo) throws -> Data {
        try shape.validateMeshes()
        var text="# units metres; ARKit local Y-up; independent submap \(shape.segmentID.uuidString)\n# rigid snapshot approximation; corrected geometry already shifted once\n# UV subdivision bounds image error to 0.5 source pixel per axis\nmtllib \(material)\n",base=1,uvBase=1,exportFaces=0
        let camera=simd_double4x4((0..<4).map {c in SIMD4((0..<4).map {shape.camera[c*4+$0]})}),inverse=simd_inverse(camera)
        func number(_ x:Double)->String {String(format:"%.9f",locale:Locale(identifier:"en_US_POSIX"),x)}
        func vector(_ prefix:String,_ v:SIMD3<Double>)->String {"\(prefix) \(number(v.x)) \(number(v.y)) \(number(v.z))\n"}
        for (mi,mesh) in shape.meshes.enumerated() {
            text+="o anchor_"+mesh.anchorID.uuidString+"\n"
            if let d=mesh.normalDerivation {text+="# missing source normals; flat face winding normals; no outward guarantee; omitted degenerate faces \(d.omittedDegenerateFaces); see texture.json sourceFaceIDs\n"}
            let vertices=(0..<(mesh.worldVertices.count/24)).map {ScanShape.vector(mesh.worldVertices,$0)}
            let normals=(0..<(mesh.worldNormals.count/24)).map {ScanShape.vector(mesh.worldNormals,$0)}
            for v in vertices {text+=vector("v",v)}
            for n in normals {text+=vector("vn",n)}
            var added=0
            for face in projection.faces[mi] {
                if let uv=face.uv {
                    let world=face.indices.map {vertices[$0]},normal=face.indices.map {normals[$0]}
                    let zs=world.map {-(inverse*SIMD4($0,1)).z}
                    guard let patches=ScanTextureProjector.patches(uv:uv,z:zs,width:frame.width,height:frame.height,maximum:min(4096,262144-exportFaces)) else {throw ScanFailure.capacity}
                    exportFaces+=patches.count
                    for patch in patches {
                        let indices:[Int]
                        if patches.count==1 {indices=face.indices.map {$0+base}}
                        else {
                            indices=(0..<3).map {base+vertices.count+added+$0};added+=3
                            for p in patch {text+=vector("v",world[0]*p.weights.x+world[1]*p.weights.y+world[2]*p.weights.z)}
                            for p in patch {let n=normal[0]*p.weights.x+normal[1]*p.weights.y+normal[2]*p.weights.z;text+=vector("vn",simd_length(n)>1e-12 ? simd_normalize(n):normal[0])}
                        }
                        for p in patch {text+="vt \(number(p.uv.u)) \(number(p.uv.v))\n"}
                        text+="usemtl captured_image\nf "+indices.enumerated().map {"\($0.element)/\($0.offset+uvBase)/\($0.element)"}.joined(separator:" ")+"\n";uvBase+=3
                    }
                } else {text+="# untextured: \(face.reason ?? "unknown")\nusemtl untextured\nf "+face.indices.map {"\($0+base)//\($0+base)"}.joined(separator:" ")+"\n"}
                guard text.utf8.count<=ScanShapeExport.maximumBytes else {throw ScanFailure.capacity}
            }
            base+=vertices.count+added
        }
        return Data(text.utf8)
    }
    static func read(_ url:URL) throws -> ScanTextureDocument {
        func safe(_ u:URL) throws {guard u.standardizedFileURL.path==u.resolvingSymlinksInPath().standardizedFileURL.path else {throw ScanFailure.foreignPath}}
        try safe(url)
        let manifestURL=url.appendingPathComponent("manifest.json");try safe(manifestURL)
        guard ((try manifestURL.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max)<65536 else {throw ScanFailure.capacity}
        let manifest=try JSONDecoder().decode(ScanOutput.Manifest.self,from:Data(contentsOf:manifestURL))
        guard manifest.schema==1,manifest.files.count<=100,Set(manifest.files.map(\.name)).count==manifest.files.count else {throw ScanFailure.corrupt}
        var values:[String:Data]=[:],total=0
        for entry in manifest.files {
            guard !entry.name.contains("/"),!entry.name.hasPrefix("."),entry.bytes>0,entry.bytes<=ScanShapeExport.maximumBytes-total else {throw ScanFailure.foreignPath}
            let path=url.appendingPathComponent(entry.name);try safe(path)
            guard (try path.resourceValues(forKeys:[.fileSizeKey])).fileSize==entry.bytes else {throw ScanFailure.incomplete}
            let data=try Data(contentsOf:path);guard GCPStore.checksum(data)==entry.checksum else {throw ScanFailure.corrupt};values[entry.name]=data;total+=data.count
        }
        guard let metadata=values["texture.json"],let reference=values["gcp.json"] else {throw ScanFailure.incomplete}
        let doc=try JSONDecoder().decode(ScanTextureDocument.self,from:metadata),gcp=try JSONDecoder().decode(ScanGCPDocument.self,from:reference)
        guard doc.schema==1,doc.units=="metres",doc.sessionID==gcp.raw.id else {throw ScanFailure.corrupt};try ScanCorrection.validate(gcp.corrections,raw:gcp.raw)
        guard doc.snapshots.count>0,doc.snapshots.count<=16 else {throw ScanFailure.capacity}
        guard doc.snapshots.contains(where:{$0.raw.meshes.contains(where:{!$0.indices.isEmpty})}) else {throw ScanFailure.noSurface}
        for snapshot in doc.snapshots {
            try snapshot.raw.validateMeshes();try snapshot.corrected.validateMeshes()
            try snapshot.sourceFrame.validate()
            let source=snapshot.sourceFrame
            guard snapshot.raw.frameID==source.frameID,snapshot.raw.time==source.time,snapshot.raw.camera==source.camera,snapshot.raw.offset==GCPVector(),snapshot.raw.meshes.count==snapshot.corrected.meshes.count,snapshot.projection.faces.count==snapshot.raw.meshes.count else {throw ScanFailure.mixedFrame}
            let expected=try ScanCorrection.offset(gcp.corrections,raw:gcp.raw,segmentID:snapshot.raw.segmentID,epoch:snapshot.raw.epoch,time:snapshot.raw.time)
            guard simd_length(expected.v-snapshot.corrected.offset.v)<1e-8 else {throw GCPFailure.doubleCorrection}
            var accepted=0,rejected=0,reasons:[String:Int]=[:]
            for (mi,mesh) in snapshot.raw.meshes.enumerated() {
                let corrected=snapshot.corrected.meshes[mi]
                guard mesh.normalDerivation==corrected.normalDerivation else {throw ScanFailure.invalidGeometry}
                guard mesh.anchorID==corrected.anchorID,mesh.indices==corrected.indices,mesh.worldNormals==corrected.worldNormals,mesh.worldVertices.count==corrected.worldVertices.count,mesh.worldVertices.count%24==0,mesh.indices.count%12==0,snapshot.projection.faces[mi].count==mesh.indices.count/12 else {throw ScanFailure.invalidGeometry}
                for i in 0..<(mesh.worldVertices.count/24) {guard simd_length(ScanShape.vector(corrected.worldVertices,i)-ScanShape.vector(mesh.worldVertices,i)-expected.v)<1e-8 else {throw GCPFailure.doubleCorrection}}
                for (fi,face) in snapshot.projection.faces[mi].enumerated() {
                    guard face.indices==(0..<3).map({Int(ScanMesh.word(mesh.indices,fi*12+$0*4))}),face.indices.allSatisfy({$0>=0 && $0<mesh.worldVertices.count/24}) else {throw ScanFailure.invalidGeometry}
                    if let uv=face.uv {guard uv.count==3,face.reason==nil,uv.allSatisfy({$0.u.isFinite && $0.v.isFinite && $0.u>=0 && $0.u<=1 && $0.v>=0 && $0.v<=1}),snapshot.depthEvidence != nil else {throw ScanFailure.corrupt};accepted+=1}
                    else {guard let reason=face.reason else {throw ScanFailure.corrupt};reasons[reason,default:0]+=1;rejected+=1}
                }
            }
            guard accepted==snapshot.projection.textured,rejected==snapshot.projection.untextured,reasons==snapshot.projection.reasons else {throw ScanFailure.corrupt}
            var expectedCamera=source.camera;expectedCamera[12]+=expected.x;expectedCamera[13]+=expected.y;expectedCamera[14]+=expected.z
            guard snapshot.corrected.camera.count==expectedCamera.count && zip(snapshot.corrected.camera,expectedCamera).allSatisfy({abs($0-$1)<1e-8}) else {throw ScanFailure.mixedFrame}
            guard snapshot.raw.frameID==snapshot.corrected.frameID,snapshot.raw.epoch==snapshot.corrected.epoch,snapshot.raw.segmentID==snapshot.corrected.segmentID else {throw ScanFailure.mixedFrame}
            let segment=snapshot.raw.segmentID.uuidString
            guard let material=values["materials-"+segment+".mtl"],let materialText=String(data:material,encoding:.utf8) else {throw ScanFailure.incomplete}
            for name in ["raw-"+segment+".obj","corrected-"+segment+".obj"] {
                guard let data=values[name],let text=String(data:data,encoding:.utf8),text.components(separatedBy:"\n").filter({$0.hasPrefix("mtllib ")})==["mtllib materials-"+segment+".mtl"] else {throw ScanFailure.incomplete}
            }
            let maps=materialText.components(separatedBy:"\n").filter {$0.hasPrefix("map_")}
            guard maps.count==(accepted>0 ? 1:0),maps.allSatisfy({$0.hasPrefix("map_Kd ")}) else {throw ScanFailure.incomplete}
            for line in maps {
                let file=String(line.dropFirst(7));guard file==snapshot.imageFile,let data=values[file],let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width==snapshot.sourceFrame.width,image.height==snapshot.sourceFrame.height else {throw ScanFailure.incomplete}
            }
            if snapshot.projection.textured>0 {guard snapshot.imageFile != nil,materialText.contains("map_Kd ") else {throw ScanFailure.incomplete}}
        }
        return doc
    }
}
