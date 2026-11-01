import Foundation
import ImageIO
import simd

struct ScanSurfacePart:Codable {
    var segmentID:UUID
    var epoch:GCPEpoch
    var frame:ScanFrameInfo
    var rawFile:String
    var correctedFile:String
    var materialFile:String
    var imageFile:String?
    var imageIssue:String?
    var offset:GCPVector
    var vertices:Int
    var normals:Int
    var faces:Int
    var textured:Int
    var untextured:Int
    var reasons:[String:Int]
    var missingNormalMeshes:Int
    var omittedDegenerateFaces:Int
}
struct ScanSurfaceDocument:Codable {
    var schema=1
    var sessionID:UUID
    var units="metres"
    var coordinates="ARKit local right-handed Y-up; unregistered submaps remain separate"
    var method="original triangles; affine UV; scene-depth visibility; raw and translation-corrected OBJ"
    var coordinatePrecisionMetres=0.000001
    var parts:[ScanSurfacePart]
    var limitations:[String]
    var emptySegments:[UUID]=[]
}

/// Compact interchange. Original packet/image/mesh data remains in the archive, not duplicated in JSON.
enum ScanSurfaceExport {
    static func make(archive:ScanArchive,id:UUID,root:URL?=nil,control:ScanExportControl=ScanExportControl()) throws -> ScanTextureResult {
        struct Source {var frame:ScanFrameInfo;var epoch:GCPEpoch;var meshes:[UUID:ScanMesh];var depth:ScanDepthMap?;var directory:URL}
        guard archive.freeBytes()>=Int64(archive.limits.minimumFreeBytes) else {throw ScanFailure.lowSpace}
        var sources:[UUID:Source]=[:],active:[UUID:ScanMesh]=[:],segment:UUID?,epoch:GCPEpoch?
        let last=try archive.visit(id,control:control) {p,url in
            guard p.hasImage,let frame=p.frame else {return}
            if segment != p.segmentID || epoch != p.epoch {active=[:];segment=p.segmentID;epoch=p.epoch}
            for m in p.meshes {active[m.anchorID]=m.mesh}
            sources[p.segmentID]=Source(frame:frame,epoch:p.epoch,meshes:active,depth:p.depthMap,directory:url)
            guard sources.count<=16,sources.values.reduce(0,{$0+$1.meshes.values.reduce(0,{$0+$1.vertices.count})})<=12*262144 else {throw ScanExportFailure.limit("最大16区間・合計262144原頂点")}
        }
        guard !sources.isEmpty else {throw ScanFailure.incomplete}
        let state=last.corrections ?? ScanCorrection.empty(id);try ScanCorrection.validate(state,raw:last.raw)
        var files:[String:Data]=[:],parts:[ScanSurfacePart]=[],textured=0,untextured=0,emptySegments:[UUID]=[]
        for (index,item) in sources.sorted(by:{$0.key.uuidString<$1.key.uuidString}).enumerated() {
            let (segment,source)=item
            let label="区間 \(index+1)/\(sources.count)"
            try control.check(label+"・形状",fraction:0.25+0.45*Double(index)/Double(sources.count))
            let raw=try ScanShape.make(meshes:Array(source.meshes.values),frame:source.frame,segmentID:segment,epoch:source.epoch,state:ScanCorrection.empty(id),raw:last.raw,limits:archive.limits)
            if raw.meshes.allSatisfy({$0.indices.isEmpty}) {emptySegments.append(segment);continue}
            let offset=try ScanCorrection.offset(state,raw:last.raw,segmentID:segment,epoch:source.epoch,time:source.frame.time)
            var png:Data?,issue:String?
            try control.check(label+"・画像")
            if let info=source.frame.imageInfo {
                do {png=try ScanImageCodec.png(original:Data(contentsOf:source.directory.appendingPathComponent("image.nv12")),info:info,limits:archive.limits)}
                catch {issue=ScanErrorMessage.text(error)}
            } else {issue="原画像の形式情報なし"}
            try control.check(label+"・画像との対応")
            let projection=ScanTextureProjector.project(raw,frame:source.frame,depth:source.depth,imageAvailable:png != nil,surface:true,checkpoint:{control.shouldContinue})
            try control.check(label+"・OBJ生成")
            let image=projection.textured>0 ? "texture-"+source.frame.frameID.uuidString+".png":nil
            let material="materials-"+segment.uuidString+".mtl",rawName="raw-"+segment.uuidString+".obj"
            let correctedName=offset==GCPVector() ? rawName:"corrected-"+segment.uuidString+".obj"
            if let image,let png {files[image]=png}
            files[material]=Data(ScanTextureExport.mtl(image:image).utf8)
            let encoded=try obj(raw,projection:projection,material:material,offset:GCPVector(),control:control)
            files[rawName]=encoded.data
            if correctedName != rawName {files[correctedName]=try obj(raw,projection:projection,material:material,offset:offset,control:control).data}
            let normals=raw.meshes.compactMap(\.normalDerivation)
            parts.append(ScanSurfacePart(segmentID:segment,epoch:source.epoch,frame:source.frame,rawFile:rawName,correctedFile:correctedName,materialFile:material,imageFile:image,imageIssue:issue,offset:offset,vertices:encoded.vertices,normals:encoded.normals,faces:projection.textured+projection.untextured,textured:projection.textured,untextured:projection.untextured,reasons:projection.reasons,missingNormalMeshes:normals.count,omittedDegenerateFaces:normals.reduce(0,{$0+$1.omittedDegenerateFaces})))
            textured+=projection.textured;untextured+=projection.untextured
            guard files.values.reduce(0,{$0+$1.count})<=ScanShapeExport.maximumBytes else {throw ScanExportFailure.limit("OBJと画像の合計64MiB")}
        }
        guard textured>0 else {throw ScanExportFailure.noTexture}
        let limits=["PARTIAL TEXTURE: gray faces are untextured; holes and unobserved regions are not filled", "Latest simultaneous keyframe per submap only; no multi-view atlas or cross-epoch registration", "Affine UV on original triangles; no 0.5-pixel projective error guarantee", "Near-plane crossing faces are not projected. Their occlusion is checked against same-frame sceneDepth; thin/subpixel occluders remain unverified", "Requires high-confidence depth and stable 3x3 neighbourhood at every covered depth sample and triangle vertex", "Corrected OBJ adds one rigid snapshot translation; fused vertex capture times are unknown", "Zero correction reuses the raw OBJ filename; normals and UVs remain identical", "OBJ coordinates rounded to one micrometre; original sensor geometry and images remain in the source record", "Missing normals derive from source face winding; no outward-orientation guarantee; degenerate faces omitted only from derived output"]
        let document=ScanSurfaceDocument(sessionID:id,parts:parts,limitations:limits+["Empty/degenerate submaps omitted from OBJ: \(emptySegments.count); IDs in emptySegments; originals retained"],emptySegments:emptySegments),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        files["surface.json"]=try encoder.encode(document);files["gcp.json"]=try encoder.encode(ScanGCPDocument(raw:last.raw,corrections:state));files["gcp.csv"]=ScanShapeExport.csv(last.raw)
        try control.check("出力ファイルを保存",fraction:0.75)
        let url=try ScanOutput.write(files:files,root:root ?? archive.root.deletingLastPathComponent().appendingPathComponent("LiDARScanSurfaceExports",isDirectory:true),freeBytes:archive.freeBytes,minimumFree:archive.limits.minimumFreeBytes,textureStatus:"affine UV; \(textured) textured / \(untextured) gray faces",hook:{_ in try control.check()})
        try control.check("出力を照合",fraction:0.8);_=try read(url,control:control)
        return ScanTextureResult(url:url,textured:textured,untextured:untextured)
    }
    struct EncodedOBJ {var data:Data;var vertices:Int;var normals:Int}
    static func obj(_ shape:ScanDerivedSnapshot,projection:ScanTextureProjection,material:String,offset:GCPVector,control:ScanExportControl) throws -> EncodedOBJ {
        try shape.validateMeshes()
        var data=Data(),chunk="# units metres; ARKit local Y-up; affine UV on original triangles\n# translation applied once; partial texture; see surface.json\nmtllib \(material)\n",base=1,normalBase=1,uvBase=1
        func number(_ x:Double)->String {String((x*1_000_000).rounded()/1_000_000)}
        func vector(_ prefix:String,_ v:SIMD3<Double>)->String {"\(prefix) \(number(v.x)) \(number(v.y)) \(number(v.z))\n"}
        func flush() throws {
            try control.check();let next=Data(chunk.utf8)
            guard next.count<=ScanShapeExport.maximumBytes-data.count else {throw ScanFailure.capacity}
            data.append(next);chunk=""
        }
        for (mi,mesh) in shape.meshes.enumerated() {
            chunk+="o anchor_"+mesh.anchorID.uuidString+"\n"
            let count=mesh.worldVertices.count/24
            var vertices:[SIMD3<Double>:Int]=[:],normals:[SIMD3<Double>:Int]=[:],vertexMap:[Int]=[],normalMap:[Int]=[]
            for i in 0..<count {
                let v=ScanShape.vector(mesh.worldVertices,i),n=ScanShape.vector(mesh.worldNormals,i)
                if let existing=vertices[v] {vertexMap.append(existing)} else {let index=base+vertices.count;vertices[v]=index;vertexMap.append(index);chunk+=vector("v",v+offset.v)}
                if let existing=normals[n] {normalMap.append(existing)} else {let index=normalBase+normals.count;normals[n]=index;normalMap.append(index);chunk+=vector("vn",n)}
                if i%512==511 {try flush()}
            }
            var lastMaterial=""
            for (fi,face) in projection.faces[mi].enumerated() {
                let current=face.uv==nil ? "untextured":"captured_image"
                if current != lastMaterial {chunk+="usemtl \(current)\n";lastMaterial=current}
                if let uv=face.uv {
                    for p in uv {chunk+="vt \(String(p.u)) \(String(p.v))\n"}
                    chunk+="f "+face.indices.enumerated().map {"\(vertexMap[$0.element])/\($0.offset+uvBase)/\(normalMap[$0.element])"}.joined(separator:" ")+"\n";uvBase+=3
                } else {chunk+="f "+face.indices.map {"\(vertexMap[$0])//\(normalMap[$0])"}.joined(separator:" ")+"\n"}
                if fi%256==255 {try flush()}
            }
            base+=vertices.count;normalBase+=normals.count
        }
        try flush();return EncodedOBJ(data:data,vertices:base-1,normals:normalBase-1)
    }

    static func read(_ url:URL,control:ScanExportControl?=nil) throws -> ScanSurfaceDocument {
        func safe(_ path:URL) throws {guard path.standardizedFileURL==path.resolvingSymlinksInPath().standardizedFileURL else {throw ScanFailure.foreignPath}}
        try safe(url);let manifestURL=url.appendingPathComponent("manifest.json");try safe(manifestURL)
        guard ((try manifestURL.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max)<65536 else {throw ScanFailure.capacity}
        let manifest=try JSONDecoder().decode(ScanOutput.Manifest.self,from:Data(contentsOf:manifestURL))
        guard manifest.schema==1,manifest.files.count<=100,Set(manifest.files.map(\.name)).count==manifest.files.count else {throw ScanFailure.corrupt}
        var values:[String:Data]=[:],total=0
        for entry in manifest.files {
            try control?.check();guard !entry.name.contains("/"),!entry.name.hasPrefix("."),entry.bytes>0,entry.bytes<=ScanShapeExport.maximumBytes-total else {throw ScanFailure.foreignPath}
            let path=url.appendingPathComponent(entry.name);try safe(path)
            guard (try path.resourceValues(forKeys:[.fileSizeKey])).fileSize==entry.bytes else {throw ScanFailure.incomplete}
            let data=try Data(contentsOf:path);guard data.count==entry.bytes,GCPStore.checksum(data)==entry.checksum else {throw ScanFailure.corrupt};values[entry.name]=data;total+=data.count
        }
        guard let metadata=values["surface.json"],let reference=values["gcp.json"] else {throw ScanFailure.incomplete}
        let doc=try JSONDecoder().decode(ScanSurfaceDocument.self,from:metadata),gcp=try JSONDecoder().decode(ScanGCPDocument.self,from:reference)
        guard doc.schema==1,doc.units=="metres",doc.sessionID==gcp.raw.id,!doc.parts.isEmpty,doc.parts.count<=16,Set(doc.parts.map(\.segmentID)).count==doc.parts.count else {throw ScanFailure.corrupt}
        try ScanCorrection.validate(gcp.corrections,raw:gcp.raw)
        guard doc.coordinatePrecisionMetres==0.000001,doc.parts.count+doc.emptySegments.count<=16,Set(doc.emptySegments).count==doc.emptySegments.count,Set(doc.emptySegments).isDisjoint(with:Set(doc.parts.map(\.segmentID))) else {throw ScanFailure.corrupt}
        for part in doc.parts {
            try control?.check();try part.frame.validate()
            guard part.vertices>0,part.vertices<=262144,part.normals>0,part.normals<=262144,part.faces>0,part.faces<=262144,part.textured>=0,part.untextured>=0,part.textured<=part.faces,part.untextured==part.faces-part.textured,part.reasons.values.allSatisfy({$0>=0 && $0<=part.faces}),part.reasons.values.reduce(0,+)==part.untextured else {throw ScanFailure.corrupt}
            let offset=try ScanCorrection.offset(gcp.corrections,raw:gcp.raw,segmentID:part.segmentID,epoch:part.epoch,time:part.frame.time)
            guard offset==part.offset else {throw GCPFailure.doubleCorrection}
            let id=part.segmentID.uuidString
            guard part.rawFile=="raw-\(id).obj",part.correctedFile==(offset==GCPVector() ? part.rawFile:"corrected-\(id).obj"),part.materialFile=="materials-\(id).mtl",let material=values[part.materialFile],String(data:material,encoding:.utf8)==ScanTextureExport.mtl(image:part.imageFile) else {throw ScanFailure.corrupt}
            if let image=part.imageFile {
                guard part.textured>0,image=="texture-"+part.frame.frameID.uuidString+".png",let data=values[image],let source=CGImageSourceCreateWithData(data as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],props[kCGImagePropertyPixelWidth] as? Int==part.frame.width,props[kCGImagePropertyPixelHeight] as? Int==part.frame.height else {throw ScanFailure.incomplete}
            } else {guard part.textured==0 else {throw ScanFailure.incomplete}}
            var objects:[String:ParsedOBJ]=[:]
            for name in Set([part.rawFile,part.correctedFile]) {guard let data=values[name] else {throw ScanFailure.incomplete};objects[name]=try validateOBJ(data,part:part,control:control)}
            if part.rawFile != part.correctedFile,let a=objects[part.rawFile],let b=objects[part.correctedFile] {
                guard a.attributes==b.attributes,a.vertices.count==b.vertices.count else {throw ScanFailure.mixedFrame}
                for (index,pair) in zip(a.vertices,b.vertices).enumerated() {
                    if index%512==0 {try control?.check()}
                    guard simd_length(pair.1-pair.0-offset.v)<=0.000002 else {throw GCPFailure.doubleCorrection}
                }
            }
        }
        guard doc.parts.reduce(0,{$0+$1.textured})>0 else {throw ScanExportFailure.noTexture}
        let expected=Set(["surface.json","gcp.json","gcp.csv"]+doc.parts.flatMap {[$0.rawFile,$0.correctedFile,$0.materialFile]+($0.imageFile.map {[$0]} ?? [])})
        guard Set(values.keys)==expected else {throw ScanFailure.corrupt}
        return doc
    }
    private struct ParsedOBJ {var vertices:[SIMD3<Double>]=[];var attributes:[String]=[]}
    private static func validateOBJ(_ data:Data,part:ScanSurfacePart,control:ScanExportControl?) throws -> ParsedOBJ {
        guard let text=String(data:data,encoding:.utf8) else {throw ScanFailure.corrupt}
        var result=ParsedOBJ(),v=0,n=0,uv=0,faces=0,textured=0,material="",libraries:[String]=[]
        for (i,line) in text.split(separator:"\n").enumerated() {
            if i%512==0 {try control?.check()}
            let items=line.split(separator:" ");guard let key=items.first else {continue}
            if key != "v",!key.hasPrefix("#") {result.attributes.append(String(line))}
            if ["v","vn","vt"].contains(key) {
                let count=key=="vt" ? 2:3,values=items.dropFirst().compactMap {Double($0)}
                guard values.count==count,values.allSatisfy(\.isFinite) else {throw ScanFailure.corrupt}
                if key=="v" {v+=1;result.vertices.append(SIMD3(values[0],values[1],values[2]))} else if key=="vn" {n+=1} else {guard values.allSatisfy({$0>=0 && $0<=1}) else {throw ScanFailure.corrupt};uv+=1}
            } else if key=="usemtl" {guard items.count==2,["captured_image","untextured"].contains(items[1]) else {throw ScanFailure.corrupt};material=String(items[1])}
            else if key=="mtllib" {guard items.count==2 else {throw ScanFailure.corrupt};libraries.append(String(items[1]))}
            else if key=="f" {
                guard items.count==4,!material.isEmpty else {throw ScanFailure.corrupt}
                for item in items.dropFirst() {
                    let fields=item.split(separator:"/",omittingEmptySubsequences:false)
                    guard fields.count==3,let a=Int(fields[0]),a>0,a<=v,let c=Int(fields[2]),c>0,c<=n else {throw ScanFailure.corrupt}
                    if material=="captured_image" {guard let b=Int(fields[1]),b>0,b<=uv else {throw ScanFailure.corrupt}}
                    else {guard fields[1].isEmpty else {throw ScanFailure.corrupt}}
                }
                faces+=1;if material=="captured_image" {textured+=1}
            }
        }
        guard v==part.vertices,n==part.normals,faces==part.faces,textured==part.textured,libraries==[part.materialFile] else {throw ScanFailure.corrupt}
        return result
    }
}
