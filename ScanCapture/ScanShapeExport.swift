import Foundation
import simd
import Darwin

struct ScanShapeDocument:Codable,Equatable {
    var schema=1
    var sessionID:UUID
    var units="metres"
    var coordinates="ARKit local right-handed Y-up; no external known coordinates; epochs are separate, not stitched"
    var geometryState="derived once from raw; do not reapply journal to these vertices"
    var correctionState:ScanCorrectionState
    var snapshots:[ScanDerivedSnapshot]
    var originalImages:Int
    var missingJPEG:Int
    var removedAnchors:Int
    var limitations:[String]
}
struct ScanGCPDocument:Codable {var units="metres";var raw:GCPRawSession;var corrections:ScanCorrectionState}
/// Local untextured interchange only. Originals are read, never changed or moved.
enum ScanShapeExport {
    static let maximumBytes=64*1024*1024
    static func build(archive:ScanArchive,id:UUID,control:ScanExportControl?=nil) throws -> (ScanShapeDocument,GCPRawSession) {
        struct Source {var frame:ScanFrameInfo;var epoch:GCPEpoch;var meshes:[UUID:ScanMesh];var start:Double;var intervals:[UUID:ScanMeshTimeEvidence]}
        var sources:[UUID:Source]=[:],active:[UUID:ScanMesh]=[:],segment:UUID?,epoch:GCPEpoch?
        var intervals:[UUID:ScanMeshTimeEvidence]=[:]
        var images=0,missing=0,removed=0,recoveryIssues=Set<String>(),seenSegments=Set<UUID>()
        let last=try archive.visit(id,control:control) {p,_ in
            seenSegments.insert(p.segmentID)
            if let source=p.recoverySource {for issue in source.retainedIssues {recoveryIssues.insert(issue)}}
            guard p.hasImage,let frame=p.frame else {return}
            if segment != p.segmentID || epoch != p.epoch {active=[:];intervals=[:];segment=p.segmentID;epoch=p.epoch}
            for change in p.meshes {if let mesh=change.mesh {active[change.anchorID]=mesh;intervals[change.anchorID]=ScanMeshTimeEvidence(anchorID:change.anchorID,observedFrom:change.observedFrom,observedAt:change.observedAt)} else {active.removeValue(forKey:change.anchorID);intervals.removeValue(forKey:change.anchorID);removed+=1}}
            sources[p.segmentID]=Source(frame:frame,epoch:p.epoch,meshes:active,start:p.segmentStart,intervals:intervals)
            images+=1;if p.previewIssue != nil {missing+=1}
            guard sources.count<=16,sources.values.reduce(0,{$0+$1.meshes.values.reduce(0,{$0+$1.vertices.count})})<=12*262_144 else {throw ScanFailure.capacity}
        }
        let state=last.corrections ?? ScanCorrection.empty(id);try ScanCorrection.validate(state,raw:last.raw)
        for scope in state.scopes {
            if let source=sources[scope.segmentID],source.epoch != scope.epoch {throw GCPFailure.generationMismatch}
        }
        var snapshots:[ScanDerivedSnapshot]=[]
        for (id,source) in sources.sorted(by:{$0.key.uuidString<$1.key.uuidString}) {
            try control?.check("形状を計算")
            var snapshot=try ScanShape.make(meshes:Array(source.meshes.values),frame:source.frame,segmentID:id,epoch:source.epoch,state:state,raw:last.raw,limits:archive.limits)
            snapshot.segmentStart=source.start;snapshot.sourceMeshIntervals=source.intervals.values.sorted {$0.anchorID.uuidString<$1.anchorID.uuidString};snapshots.append(snapshot)
        }
        guard !snapshots.isEmpty,snapshots.contains(where:{!$0.meshes.isEmpty}) else {throw ScanFailure.incomplete}
        guard snapshots.contains(where:{$0.meshes.contains(where:{!$0.indices.isEmpty})}) else {throw ScanFailure.noSurface}
        var limitations=["UNVERIFIED COVERAGE: unobserved regions and holes are not filled or certified", "Latest observed mesh snapshot per segment only; removed anchors are not exported", "No UV, textures, MTL or image copies in this geometry-only package; native originals remain in source record", "Fused vertices have unknown acquisition times; one rigid translation at snapshot frame reference is an approximation, not per-vertex temporal deformation", "Camera and mesh share the same snapshot translation; no rotation, scale, cross-epoch stitching or survey accuracy guarantee"]
        let unobserved=seenSegments.subtracting(sources.keys)
        if !unobserved.isEmpty {limitations.append("Segments without an image/mesh keyframe: \(unobserved.count); no geometry invented")}
        if snapshots.contains(where:{$0.meshes.isEmpty}) {limitations.append("Empty latest submaps: \(snapshots.filter {$0.meshes.isEmpty}.count)")}
        if Set(snapshots.map(\.epoch)).count>1 {limitations.append("Multiple unregistered epochs: OBJ files are separate per submap, not a merged world")}
        if removed>0 {limitations.append("Removed anchor events: \(removed); their prior raw snapshots remain in source")}
        if missing>0 {limitations.append("Missing JPEG derivatives: \(missing); native image originals were retained")}
        let normalEvidence=snapshots.flatMap(\.meshes).compactMap(\.normalDerivation)
        if !normalEvidence.isEmpty {limitations.append("Missing raw normal attributes in \(normalEvidence.count) mesh snapshots; original Float32 bits retained in source records. Derived export splits vertices per nondegenerate face and computes flat normals from source triangle winding; no outward orientation guarantee. Omitted degenerate faces: \(normalEvidence.reduce(0,{$0+$1.omittedDegenerateFaces})); unrepresented source vertices: \(normalEvidence.reduce(0,{$0+$1.unrepresentedVertices})); source face IDs and policy are in geometry metadata.")}
        limitations.append(contentsOf:recoveryIssues.sorted().map {"Recovery source retained issue: "+$0})
        return (ScanShapeDocument(sessionID:id,correctionState:state,snapshots:snapshots,originalImages:images,missingJPEG:missing,removedAnchors:removed,limitations:limitations),last.raw)
    }
    static func obj(_ doc:ScanShapeDocument,control:ScanExportControl?=nil) throws -> Data {
        guard Set(doc.snapshots.map(\.epoch)).count<=1 else {throw GCPFailure.generationMismatch}
        var text="# units: metres\n# ARKit local, right-handed Y-up; epochs are not stitched\n# correction: distance-weighted trajectory field, rigid snapshot at frame reference\n# INCOMPLETE COVERAGE; no textures/UV; see geometry.json and manifest.json\n",base=1
        func number(_ value:Double)->String {String(value)}
        for s in doc.snapshots {
            try s.validateMeshes()
            text+="# ar_session: \(s.epoch.arSessionID.uuidString); generation: \(s.epoch.generation); alignment_revision: \(s.epoch.alignmentRevision)\n# frame: \(s.frameID.uuidString); reference_time: \(s.time)\n# applied once: \(s.offset.x),\(s.offset.y),\(s.offset.z) metres; do not reapply journal\n"
            for mesh in s.meshes {
                try control?.check("形状OBJを生成")
                guard mesh.worldVertices.count%24==0,mesh.worldNormals.count==mesh.worldVertices.count else {throw ScanFailure.invalidGeometry}
                let count=mesh.worldVertices.count/24
                text+="o segment_\(s.segmentID.uuidString)_anchor_\(mesh.anchorID.uuidString)\n"
                if let d=mesh.normalDerivation {text+="# missing source normals; flat face winding normals; no outward guarantee; omitted degenerate faces \(d.omittedDegenerateFaces); see geometry.json sourceFaceIDs\n"}
                for i in 0..<count {let v=ScanShape.vector(mesh.worldVertices,i);text+="v \(number(v.x)) \(number(v.y)) \(number(v.z))\n"}
                for i in 0..<count {let n=ScanShape.vector(mesh.worldNormals,i);text+="vn \(number(n.x)) \(number(n.y)) \(number(n.z))\n"}
                for i in stride(from:0,to:mesh.indices.count,by:12) {
                    if i%3072==0 {try control?.check()}
                    let values=(0..<3).map {Int(ScanMesh.word(mesh.indices,i+$0*4))}
                    guard values.allSatisfy({$0<count}) else {throw ScanFailure.invalidGeometry}
                    text+="f "+values.map {"\($0+base)//\($0+base)"}.joined(separator:" ")+"\n"
                }
                base+=count;guard text.utf8.count<=maximumBytes else {throw ScanFailure.capacity}
            }
        }
        return Data(text.utf8)
    }
    static func csv(_ raw:GCPRawSession)->Data {
        var text="point_id,ar_session_id,generation,alignment_revision,reference_x_m,reference_y_m,reference_z_m,reference_kind\r\n"
        for p in raw.points {text+="\(p.id.uuidString),\(p.epoch.arSessionID.uuidString),\(p.epoch.generation),\(p.epoch.alignmentRevision),\(p.position.x),\(p.position.y),\(p.position.z),local_without_external_known_coordinates\r\n"}
        return Data(text.utf8)
    }
    static func make(archive:ScanArchive,id:UUID,root:URL?=nil,control:ScanExportControl?=nil,hook:((String)throws->Void)?=nil) throws -> URL {
        let (doc,raw)=try build(archive:archive,id:id,control:control)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var files=["geometry.json":try encoder.encode(doc),"gcp.csv":csv(raw),"gcp.json":try encoder.encode(ScanGCPDocument(raw:raw,corrections:doc.correctionState))]
        if doc.snapshots.count==1 {files["geometry.obj"]=try obj(doc,control:control)}
        else {for snapshot in doc.snapshots {var one=doc;one.snapshots=[snapshot];files["geometry-"+snapshot.segmentID.uuidString+".obj"]=try obj(one,control:control)}}
        return try ScanOutput.write(files:files,root:root ?? archive.root.deletingLastPathComponent().appendingPathComponent("LiDARScanExports",isDirectory:true),freeBytes:archive.freeBytes,minimumFree:archive.limits.minimumFreeBytes,hook:{stage in try control?.check();try hook?(stage)})
    }
}
/// Atomic publication of derived copies; a failed export leaves staging and all input files intact.
enum ScanOutput {
    struct Entry:Codable {var name:String;var bytes:Int;var checksum:UInt64}
    struct Manifest:Codable {var schema=1;var units="metres";var coordinates="ARKit local Y-up; epochs unregistered";var texture="not generated";var coverage="unverified, holes and missing regions not filled";var files:[Entry]}
    static func write(files:[String:Data],root:URL,freeBytes:()->Int64,minimumFree:Int,textureStatus:String="not generated",hook:((String)throws->Void)?=nil) throws -> URL {
        let bytes=files.values.reduce(0,{$0+$1.count})
        guard bytes<=ScanShapeExport.maximumBytes else {throw ScanFailure.capacity}
        guard freeBytes()>=Int64(minimumFree+bytes*2) else {throw ScanFailure.lowSpace}
        guard root.standardizedFileURL.path==root.resolvingSymlinksInPath().standardizedFileURL.path,
              !root.pathComponents.contains(where:{["ARWork","TreeSurvey","Documents","Archives"].contains($0)}) else {throw ScanFailure.foreignPath}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let id=UUID().uuidString,pending=root.appendingPathComponent(".pending-"+id,isDirectory:true),final=root.appendingPathComponent(id,isDirectory:true)
        try FileManager.default.createDirectory(at:pending,withIntermediateDirectories:false);try sync(root);try hook?("created-pending")
        var entries:[Entry]=[]
        for (name,data) in files.sorted(by:{$0.key<$1.key}) {
            guard !name.contains("/"),!name.hasPrefix("."),!data.isEmpty else {throw ScanFailure.foreignPath}
            try writeFile(data,to:pending.appendingPathComponent(name));entries.append(Entry(name:name,bytes:data.count,checksum:GCPStore.checksum(data)));try hook?("after-file")
        }
        try writeFile(try JSONEncoder().encode(Manifest(texture:textureStatus,files:entries)),to:pending.appendingPathComponent("manifest.json"))
        try sync(pending);try hook?("before-publish")
        guard !FileManager.default.fileExists(atPath:final.path),rename(pending.path,final.path)==0 else {throw ScanFailure.corrupt}
        try hook?("after-publish");try sync(root);return final
    }
    static func read(_ url:URL) throws -> ScanShapeDocument {
        guard url.standardizedFileURL.path==url.resolvingSymlinksInPath().standardizedFileURL.path else {throw ScanFailure.foreignPath}
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:url.appendingPathComponent("manifest.json")))
        guard manifest.schema==1,manifest.files.count>=4,manifest.files.count<=19,Set(manifest.files.map(\.name)).count==manifest.files.count,Set(["geometry.json","gcp.csv","gcp.json"]).isSubset(of:Set(manifest.files.map(\.name))),manifest.files.allSatisfy({["geometry.obj","geometry.json","gcp.csv","gcp.json"].contains($0.name) || ($0.name.hasPrefix("geometry-") && $0.name.hasSuffix(".obj") && UUID(uuidString:String($0.name.dropFirst(9).dropLast(4))) != nil)}) else {throw ScanFailure.corrupt}
        var total=0,geometry:Data?,gcp:Data?
        for entry in manifest.files {
            total+=entry.bytes;guard entry.bytes>0,total<=ScanShapeExport.maximumBytes else {throw ScanFailure.capacity}
            let path=url.appendingPathComponent(entry.name)
            guard path.standardizedFileURL.path==path.resolvingSymlinksInPath().standardizedFileURL.path,(try path.resourceValues(forKeys:[.fileSizeKey])).fileSize==entry.bytes else {throw ScanFailure.corrupt}
            let data=try Data(contentsOf:path);guard GCPStore.checksum(data)==entry.checksum else {throw ScanFailure.corrupt}
            if entry.name=="geometry.json" {geometry=data};if entry.name=="gcp.json" {gcp=data}
        }
        guard let geometry,let gcp else {throw ScanFailure.incomplete}
        let doc=try JSONDecoder().decode(ScanShapeDocument.self,from:geometry),reference=try JSONDecoder().decode(ScanGCPDocument.self,from:gcp)
        guard doc.schema==1,doc.units=="metres",reference.units=="metres",doc.sessionID==reference.raw.id,doc.correctionState==reference.corrections,doc.snapshots.count>0,doc.snapshots.count<=16 else {throw ScanFailure.corrupt}
        try ScanCorrection.validate(doc.correctionState,raw:reference.raw)
        guard doc.snapshots.contains(where:{$0.meshes.contains(where:{!$0.indices.isEmpty})}) else {throw ScanFailure.noSurface}
        let objects=Set(manifest.files.map(\.name).filter {$0.hasSuffix(".obj")})
        let expected=doc.snapshots.count==1 ? Set(["geometry.obj"]):Set(doc.snapshots.map {"geometry-"+$0.segmentID.uuidString+".obj"})
        guard objects==expected else {throw ScanFailure.corrupt}
        for snapshot in doc.snapshots {
            try snapshot.validateMeshes()
            _=try GCPCaptureEvidence.pose(snapshot.camera)
            guard snapshot.time.isFinite,snapshot.offset.finite,snapshot.segmentStart.map({$0.isFinite && $0<=snapshot.time}) ?? true else {throw ScanFailure.corrupt}
        }
        return doc
    }
    private static func writeFile(_ data:Data,to url:URL) throws {
        let fd=open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,mode_t(0o600));guard fd>=0 else {throw POSIXError(.EIO)};defer {close(fd)}
        try data.withUnsafeBytes {p in var offset=0;while offset<p.count {let n=Darwin.write(fd,p.baseAddress!.advanced(by:offset),p.count-offset);if n<0 && errno==EINTR {continue};guard n>0 else {throw POSIXError(.EIO)};offset+=n}}
        guard fsync(fd)==0 else {throw POSIXError(.EIO)}
        if fcntl(fd,F_FULLFSYNC)<0,errno != EINVAL,errno != ENOTSUP {throw POSIXError(.EIO)}
    }
    private static func sync(_ url:URL) throws {let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw POSIXError(.EIO)};defer {close(fd)};guard fsync(fd)==0 else {throw POSIXError(.EIO)}}
}
