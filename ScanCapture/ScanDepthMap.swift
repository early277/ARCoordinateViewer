import Foundation
import CoreVideo

/// Raw same-frame sceneDepth: camera optical-axis Z in metres, not normalized-ray range.
struct ScanDepthMap:Codable,Equatable {
    var frameID:UUID
    var time:Double
    var imageWidth:Int
    var imageHeight:Int
    var width:Int
    var height:Int
    var cameraZBits:Data // packed little-endian Float32; invalid raw bits are retained
    var confidence:Data
    var semantics="ARKit sceneDepth camera-z metres; image-normalized grid"
    func validate(_ frame:ScanFrameInfo) throws {
        guard frameID==frame.frameID,time==frame.time,imageWidth==frame.width,imageHeight==frame.height,
              width>0,height>0,width<=512,height<=512,cameraZBits.count==width*height*4,confidence.count==width*height,
              semantics=="ARKit sceneDepth camera-z metres; image-normalized grid" else {throw ScanFailure.mixedFrame}
    }
    func z(_ x:Int,_ y:Int)->Double {Double(Float(bitPattern:ScanMesh.word(cameraZBits,(y*width+x)*4)))}
    static func capture(_ frame:GCPFrameSnapshot)->ScanDepthMap? {
        guard let depth=frame.depth,let confidence=frame.confidence else {return nil}
        let w=CVPixelBufferGetWidth(depth),h=CVPixelBufferGetHeight(depth),ds=CVPixelBufferGetBytesPerRow(depth),cs=CVPixelBufferGetBytesPerRow(confidence)
        guard w>0,h>0,w<=512,h<=512,CVPixelBufferGetWidth(confidence)==w,CVPixelBufferGetHeight(confidence)==h,
              !CVPixelBufferIsPlanar(depth),!CVPixelBufferIsPlanar(confidence),ds>=w*4,cs>=w,
              [kCVPixelFormatType_DepthFloat32,kCVPixelFormatType_OneComponent32Float].contains(CVPixelBufferGetPixelFormatType(depth)),
              CVPixelBufferGetPixelFormatType(confidence)==kCVPixelFormatType_OneComponent8 else {return nil}
        guard CVPixelBufferLockBaseAddress(depth,.readOnly)==0 else {return nil};defer {CVPixelBufferUnlockBaseAddress(depth,.readOnly)}
        guard CVPixelBufferLockBaseAddress(confidence,.readOnly)==0 else {return nil};defer {CVPixelBufferUnlockBaseAddress(confidence,.readOnly)}
        guard let d=CVPixelBufferGetBaseAddress(depth),let c=CVPixelBufferGetBaseAddress(confidence) else {return nil}
        var bits=Data(),levels=Data();bits.reserveCapacity(w*h*4);levels.reserveCapacity(w*h)
        for y in 0..<h {
            for x in 0..<w {var value=d.loadUnaligned(fromByteOffset:y*ds+x*4,as:UInt32.self).littleEndian;withUnsafeBytes(of:&value) {bits.append(contentsOf:$0)}}
            levels.append(c.advanced(by:y*cs).assumingMemoryBound(to:UInt8.self),count:w)
        }
        return ScanDepthMap(frameID:frame.frameID,time:frame.time,imageWidth:Int(frame.imageSize.width),imageHeight:Int(frame.imageSize.height),width:w,height:h,cameraZBits:bits,confidence:levels)
    }
}
