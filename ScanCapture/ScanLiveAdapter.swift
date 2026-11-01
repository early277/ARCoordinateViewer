import ARKit
import UIKit
import Metal

/// Called synchronously ONLY after an explicit start and a bounded queue reservation.
/// Mesh and image bytes are copied before returning; ARFrame/Metal buffers are never queued.
enum ScanLiveAdapter {
    static func capture(_ frame:ARFrame,snapshot:GCPFrameSnapshot,limits:ScanLimits) throws -> ScanNativePayload {
        guard frame.timestamp==snapshot.time,frame.camera.transform==snapshot.camera,
              frame.camera.intrinsics==snapshot.intrinsics,frame.camera.imageResolution==snapshot.imageSize,
              snapshot.tracking == .normal else {throw ScanFailure.mixedFrame}
        let anchors=frame.anchors.compactMap {$0 as? ARMeshAnchor}
        guard anchors.count<=limits.maximumAnchors else {throw ScanFailure.capacity}
        var meshes:[ScanMesh]=[],vertices=0,indices=0
        for (index,anchor) in anchors.enumerated() {
            let g=anchor.geometry,v=g.vertices,n=g.normals,f=g.faces
            // Store layout diagnostics only, never vertex/image/position values.
            let counts="anchor=\(index),v=\(v.count),n=\(n.count),faces=\(f.count)"
            guard v.format == .float3,n.format == .float3,v.componentsPerVector==3,n.componentsPerVector==3,v.count==n.count,
                  v.count>=0,n.count>=0,f.count>=0,f.primitiveType == .triangle,f.indexCountPerPrimitive==3 else {
                throw ScanMeshInputIssue.invalid("layout; \(counts); vfmt=\(v.format),nfmt=\(n.format),components=\(v.componentsPerVector)/\(n.componentsPerVector),primitive=\(f.primitiveType)/\(f.indexCountPerPrimitive)")
            }
            guard v.count<=limits.maximumVertices,f.count<=limits.maximumIndices/3 else {throw ScanFailure.capacity}
            // An empty anchor has no measurable surface yet. Reject the entire snapshot
            // as pending, so it cannot silently tombstone the previous valid mesh.
            if f.count==0 {throw ScanMeshInputIssue.notReady("\(counts)")}
            guard v.count>0 else {throw ScanMeshInputIssue.invalid("faces-without-vertices; \(counts)")}
            guard [2,4].contains(f.bytesPerIndex) else {throw ScanMeshInputIssue.invalid("index-width=\(f.bytesPerIndex); \(counts)")}
            vertices+=v.count;indices+=f.count*3
            guard vertices<=limits.maximumVertices,indices<=limits.maximumIndices else {throw ScanFailure.capacity}
            func source(_ s:ARGeometrySource,_ name:String) throws -> Data {
                let detail="\(name)-buffer; \(counts); offset=\(s.offset),stride=\(s.stride),bytes=\(s.buffer.length)"
                guard s.offset>=0,s.stride>=12,s.count>0,s.offset<=s.buffer.length,
                      s.count<=(s.buffer.length-s.offset)/s.stride+1 else {throw ScanMeshInputIssue.invalid(detail)}
                let length=s.offset+(s.count-1)*s.stride+12
                guard length<=s.buffer.length else {throw ScanMeshInputIssue.invalid(detail)}
                return try ScanGeometryReader.vectors(Data(bytes:s.buffer.contents(),count:length),offset:s.offset,stride:s.stride,count:s.count,maximum:limits.maximumVertices)
            }
            let length=f.count*3*f.bytesPerIndex
            guard length<=f.buffer.length else {throw ScanMeshInputIssue.invalid("index-buffer; \(counts); bytes=\(f.buffer.length),required=\(length)")}
            var mesh=ScanMesh(anchorID:anchor.identifier,transform:(0..<4).flatMap {c in (0..<4).map {Double(anchor.transform[c][$0])}},vertices:try source(v,"vertex"),normals:try source(n,"normal"),indices:try ScanGeometryReader.triangles(Data(bytes:f.buffer.contents(),count:length),bytesPerIndex:f.bytesPerIndex,count:f.count*3,maximum:limits.maximumIndices))
            // Missing normal attributes do not invalidate finite positions/topology.
            // Keep every original bit; derive normals separately at export, never here.
            mesh.normalStatus=mesh.sourceNormalStatus
            do {try mesh.validate(limits)}
            catch let issue as ScanFailure {
                let detail=mesh.geometryIssue(limits) ?? issue.rawValue
                throw ScanMeshInputIssue.invalid("values-or-index-range; \(counts); \(detail); vertexLayout=\(v.offset)/\(v.stride),normalLayout=\(n.offset)/\(n.stride),indexWidth=\(f.bytesPerIndex)")
            }
            catch {throw ScanMeshInputIssue.invalid("anchor-transform; \(counts)")}
            meshes.append(mesh)
        }
        let image=frame.capturedImage
        guard CVPixelBufferGetWidth(image)==Int(snapshot.imageSize.width),CVPixelBufferGetHeight(image)==Int(snapshot.imageSize.height) else {throw ScanFailure.mixedFrame}
        return ScanNativePayload(meshes:meshes,image:try ScanImageCodec.copy(image,limits:limits),depthMap:ScanDepthMap.capture(snapshot))
    }
}
