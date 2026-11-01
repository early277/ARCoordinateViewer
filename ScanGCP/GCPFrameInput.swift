import Foundation
import CoreGraphics
import CoreVideo
import simd

/// Value snapshot of ONE ARFrame. Buffer access is synchronous and read-only.
/// Live construction is confined to GCPARFrameAdapter; fixtures use this DTO.
struct GCPFrameSnapshot {
    var frameID=UUID()
    var time:Double
    var tracking:GCPTracking
    var camera:simd_float4x4
    var intrinsics:simd_float3x3
    var imageSize:CGSize
    var viewport:CGSize
    var imageToView:CGAffineTransform
    var orientationToken:Int
    var depth:CVPixelBuffer?
    var confidence:CVPixelBuffer?
    /// Normalized position of the visible reticle in this exact viewport.
    var targetInView=CGPoint(x:0.5,y:0.5)
    var viewKey:[Double] {
        [Double(viewport.width),Double(viewport.height),Double(imageSize.width),Double(imageSize.height),
         Double(imageToView.a),Double(imageToView.b),Double(imageToView.c),Double(imageToView.d),Double(imageToView.tx),Double(imageToView.ty),Double(orientationToken),Double(targetInView.x),Double(targetInView.y)]
    }
    var matrix:[Double] {(0..<4).flatMap {c in (0..<4).map {Double(camera[c][$0])}}}
}
enum GCPInputIssue:Error,Equatable {
    case notRecording,busy,staleFrame,tracking,unstable,viewChanged,sessionChanged,depthRequired,capacity
    case core(GCPFailure)
}
struct GCPInputReading {var observation:GCPObservation;var depthAccepted:Bool}
enum GCPFrameInput {
    static func observation(_ frame:GCPFrameSnapshot,epoch:GCPEpoch,now:Double) throws -> GCPInputReading {
        guard frame.time.isFinite,now.isFinite,now>=frame.time,now-frame.time<=0.25 else {throw GCPInputIssue.staleFrame}
        guard frame.viewKey.allSatisfy(\.isFinite),frame.viewport.width>0,frame.viewport.height>0,
              frame.imageSize.width>0,frame.imageSize.height>0,frame.imageSize.width<=16384,frame.imageSize.height<=16384,
              floor(frame.imageSize.width)==frame.imageSize.width,floor(frame.imageSize.height)==frame.imageSize.height,
              abs(frame.imageToView.a*frame.imageToView.d-frame.imageToView.b*frame.imageToView.c)>1e-10 else {throw GCPFailure.calibration}
        guard frame.targetInView.x>=0,frame.targetInView.x<1,frame.targetInView.y>=0,frame.targetInView.y<1 else {throw GCPFailure.calibration}
        let p=frame.targetInView.applying(frame.imageToView.inverted())
        guard p.x>=0,p.x<1,p.y>=0,p.y<1 else {throw GCPFailure.calibration}
        let k=(0..<3).flatMap {c in (0..<3).map {Double(frame.intrinsics[c][$0])}}
        let pose=try GCPCaptureEvidence.pose(frame.matrix)
        var evidence=GCPCaptureEvidence(frameID:frame.frameID,frameTime:frame.time,cameraTransform:frame.matrix,cameraIntrinsics:k,
            imageToView:[Double(frame.imageToView.a),Double(frame.imageToView.b),Double(frame.imageToView.c),Double(frame.imageToView.d),Double(frame.imageToView.tx),Double(frame.imageToView.ty)],
            viewportWidth:Double(frame.viewport.width),viewportHeight:Double(frame.viewport.height),imageX:Double(p.x),imageY:Double(p.y),depthPatch:nil,viewX:Double(frame.targetInView.x),viewY:Double(frame.targetInView.y))
        if let depth=frame.depth {evidence.depthPatch=patch(depth,confidence:frame.confidence,x:Double(p.x),y:Double(p.y))}
        let intrinsics=GCPIntrinsics(width:Int(frame.imageSize.width),height:Int(frame.imageSize.height),fx:k[0],fy:k[4],cx:k[6],cy:k[7])
        let o=GCPObservation(epoch:epoch,time:frame.time,pose:pose,intrinsics:intrinsics,pixelX:Double(p.x*frame.imageSize.width),pixelY:Double(p.y*frame.imageSize.height),tracking:frame.tracking,depth:evidence.depthPatch?.measurement(),captureEvidence:evidence)
        _=try o.ray();try evidence.validate(o)
        let accepted=o.depth != nil && (try? GCPMath.usable(o)) != nil
        return GCPInputReading(observation:o,depthAccepted:accepted)
    }
    private static func patch(_ depth:CVPixelBuffer,confidence:CVPixelBuffer?,x:Double,y:Double)->GCPDepthPatch {
        let w=CVPixelBufferGetWidth(depth),h=CVPixelBufferGetHeight(depth),stride=CVPixelBufferGetBytesPerRow(depth)
        let px=Int(x*Double(w)),py=Int(y*Double(h))
        var p=GCPDepthPatch(availability:.unsupported,width:w,height:h,bytesPerRow:stride,format:CVPixelBufferGetPixelFormatType(depth),x:px,y:py,
            confidenceWidth:confidence.map(CVPixelBufferGetWidth),confidenceHeight:confidence.map(CVPixelBufferGetHeight),confidenceBytesPerRow:confidence.map(CVPixelBufferGetBytesPerRow),confidenceFormat:confidence.map(CVPixelBufferGetPixelFormatType),bits:[],confidence:[])
        guard w>0,h>0,stride>=w*4,stride%4==0,!CVPixelBufferIsPlanar(depth),[kCVPixelFormatType_DepthFloat32,kCVPixelFormatType_OneComponent32Float].contains(p.format) else {return p}
        guard CVPixelBufferLockBaseAddress(depth,.readOnly)==kCVReturnSuccess else {p.availability = .locked;return p}
        defer {CVPixelBufferUnlockBaseAddress(depth,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(depth),Int(bitPattern:base)%4==0 else {p.availability = .locked;return p}
        var confidenceBase:UnsafeMutableRawPointer?,confidenceLocked=false
        if let confidence,p.confidenceWidth==w,p.confidenceHeight==h,
           p.confidenceFormat==kCVPixelFormatType_OneComponent8,(p.confidenceBytesPerRow ?? 0)>=w,!CVPixelBufferIsPlanar(confidence),
           CVPixelBufferLockBaseAddress(confidence,.readOnly)==kCVReturnSuccess {
            confidenceLocked=true;confidenceBase=CVPixelBufferGetBaseAddress(confidence)
        }
        defer {if let confidence,confidenceLocked {CVPixelBufferUnlockBaseAddress(confidence,.readOnly)}}
        p.availability = .readable
        for dy in -1...1 {for dx in -1...1 {
            let cx=px+dx,cy=py+dy
            guard cx>=0,cx<w,cy>=0,cy<h else {p.bits.append(nil);p.confidence.append(nil);continue}
            p.bits.append(base.advanced(by:cy*stride).assumingMemoryBound(to:UInt32.self)[cx])
            p.confidence.append(confidenceBase.map {$0.advanced(by:cy*(p.confidenceBytesPerRow ?? 0)).assumingMemoryBound(to:UInt8.self)[cx]})
        }}
        return p
    }
}
