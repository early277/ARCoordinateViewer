import Foundation
import CoreVideo
import CoreGraphics
import ImageIO

/// Native-size, unrotated selected keyframes. No Photos library or EXIF location.
enum ScanImageCodec {
    static func copy(_ source:CVPixelBuffer,limits:ScanLimits) throws -> CVPixelBuffer {
        let w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source),format=CVPixelBufferGetPixelFormatType(source)
        guard [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format),
              w>0,h>0,w<=limits.maximumImageSide,h<=limits.maximumImageSide,w<=limits.maximumImagePixels/h else {throw ScanFailure.unsupportedImage}
        var output:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,w,h,format,nil,&output)==kCVReturnSuccess,let output else {throw ScanFailure.capacity}
        guard CVPixelBufferLockBaseAddress(source,.readOnly)==kCVReturnSuccess else {throw ScanFailure.unsupportedImage};defer {CVPixelBufferUnlockBaseAddress(source,.readOnly)}
        guard CVPixelBufferLockBaseAddress(output,[])==kCVReturnSuccess else {throw ScanFailure.unsupportedImage};defer {CVPixelBufferUnlockBaseAddress(output,[])}
        guard CVPixelBufferGetPlaneCount(source)==2,CVPixelBufferGetPlaneCount(output)==2 else {throw ScanFailure.unsupportedImage}
        for plane in 0..<2 {
            guard let input=CVPixelBufferGetBaseAddressOfPlane(source,plane),let target=CVPixelBufferGetBaseAddressOfPlane(output,plane) else {throw ScanFailure.unsupportedImage}
            let rows=CVPixelBufferGetHeightOfPlane(source,plane),length=CVPixelBufferGetWidthOfPlane(source,plane)*(plane==0 ? 1:2)
            let srcStride=CVPixelBufferGetBytesPerRowOfPlane(source,plane),dstStride=CVPixelBufferGetBytesPerRowOfPlane(output,plane)
            guard length<=srcStride,length<=dstStride,rows==CVPixelBufferGetHeightOfPlane(output,plane) else {throw ScanFailure.unsupportedImage}
            for row in 0..<rows {memcpy(target.advanced(by:row*dstStride),input.advanced(by:row*srcStride),length)}
        }
        CVBufferPropagateAttachments(source,output)
        return output
    }
    static func describe(_ image:CVPixelBuffer)->ScanImageInfo {
        var attributes:[String:String]=[:]
        for (name,key) in [("YCbCrMatrix",kCVImageBufferYCbCrMatrixKey),("ColorPrimaries",kCVImageBufferColorPrimariesKey),("TransferFunction",kCVImageBufferTransferFunctionKey)] {
            if let value=CVBufferCopyAttachment(image,key,nil) as? String {attributes[name]=value}
        }
        let planes=CVPixelBufferGetPlaneCount(image)
        return ScanImageInfo(pixelFormat:CVPixelBufferGetPixelFormatType(image),width:CVPixelBufferGetWidth(image),height:CVPixelBufferGetHeight(image),planeWidths:(0..<planes).map {CVPixelBufferGetWidthOfPlane(image,$0)},planeHeights:(0..<planes).map {CVPixelBufferGetHeightOfPlane(image,$0)},packedRowBytes:(0..<planes).map {CVPixelBufferGetWidthOfPlane(image,$0)*($0==0 ? 1:2)},attributes:attributes)
    }
    /// The native NV12 planes are the immutable original; JPEG is only a convenience derivative.
    static func original(_ image:CVPixelBuffer,limits:ScanLimits) throws -> Data {
        let info=describe(image)
        guard info.width>0,info.height>0,info.width<=limits.maximumImageSide,info.height<=limits.maximumImageSide,info.width<=limits.maximumImagePixels/info.height,
              [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(info.pixelFormat),info.planeWidths.count==2,info.byteCount<=limits.maximumImageBytes else {throw ScanFailure.unsupportedImage}
        guard CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else {throw ScanFailure.unsupportedImage};defer {CVPixelBufferUnlockBaseAddress(image,.readOnly)}
        var data=Data();data.reserveCapacity(info.byteCount)
        for plane in 0..<2 {
            guard let base=CVPixelBufferGetBaseAddressOfPlane(image,plane),CVPixelBufferGetBytesPerRowOfPlane(image,plane)>=info.packedRowBytes[plane] else {throw ScanFailure.unsupportedImage}
            for row in 0..<info.planeHeights[plane] {data.append(base.advanced(by:row*CVPixelBufferGetBytesPerRowOfPlane(image,plane)).assumingMemoryBound(to:UInt8.self),count:info.packedRowBytes[plane])}
        }
        return data
    }
    private static func colourImage(_ buffer:CVPixelBuffer,limits:ScanLimits,strictColour:Bool=false) throws -> CGImage {
        let w=CVPixelBufferGetWidth(buffer),h=CVPixelBufferGetHeight(buffer),format=CVPixelBufferGetPixelFormatType(buffer)
        var space=CGColorSpace(name:CGColorSpace.sRGB)!
        if strictColour {
            let primaries=CVBufferCopyAttachment(buffer,kCVImageBufferColorPrimariesKey,nil) as? String,transfer=CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil) as? String
            if primaries==(kCVImageBufferColorPrimaries_ITU_R_709_2 as String),transfer==(kCVImageBufferTransferFunction_ITU_R_709_2 as String) {space=CGColorSpace(name:CGColorSpace.itur_709)!}
            else if primaries==(kCVImageBufferColorPrimaries_ITU_R_709_2 as String),transfer==(kCVImageBufferTransferFunction_sRGB as String) {space=CGColorSpace(name:CGColorSpace.sRGB)!}
            else if primaries==(kCVImageBufferColorPrimaries_P3_D65 as String),transfer==(kCVImageBufferTransferFunction_sRGB as String) {space=CGColorSpace(name:CGColorSpace.displayP3)!}
            else {throw ScanFailure.unsupportedImage}
        }
        guard w>0,h>0,w<=limits.maximumImageSide,h<=limits.maximumImageSide,w<=limits.maximumImagePixels/h,
              [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format),CVPixelBufferGetPlaneCount(buffer)==2 else {throw ScanFailure.unsupportedImage}
        // A bounded CPU conversion also works without an IOSurface/Metal context.
        // Unknown colour matrices are rejected instead of silently inventing colours.
        let matrix=CVBufferCopyAttachment(buffer,kCVImageBufferYCbCrMatrixKey,nil) as? String
        let kr:Double,kb:Double
        if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) {kr=0.2126;kb=0.0722}
        else if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {kr=0.299;kb=0.114}
        else {throw ScanFailure.unsupportedImage}
        guard CVPixelBufferLockBaseAddress(buffer,.readOnly)==kCVReturnSuccess else {throw ScanFailure.unsupportedImage};defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        guard let luma=CVPixelBufferGetBaseAddressOfPlane(buffer,0)?.assumingMemoryBound(to:UInt8.self),let chroma=CVPixelBufferGetBaseAddressOfPlane(buffer,1)?.assumingMemoryBound(to:UInt8.self) else {throw ScanFailure.unsupportedImage}
        let ys=CVPixelBufferGetBytesPerRowOfPlane(buffer,0),cs=CVPixelBufferGetBytesPerRowOfPlane(buffer,1),full=format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard ys>=w,cs>=((w+1)/2)*2,CVPixelBufferGetHeightOfPlane(buffer,1)>=(h+1)/2 else {throw ScanFailure.unsupportedImage}
        var rgb=Data(count:w*h*3)
        rgb.withUnsafeMutableBytes {storage in
            let out=storage.bindMemory(to:UInt8.self)
            func byte(_ value:Double)->UInt8 {UInt8(max(0,min(255,value.rounded())))}
            for y in 0..<h {for x in 0..<w {
                let index=(y/2)*cs+(x/2)*2,yy=(Double(luma[y*ys+x])-(full ? 0:16))*(full ? 1:255/219)
                let cb=(Double(chroma[index])-128)*(full ? 1:255/224),cr=(Double(chroma[index+1])-128)*(full ? 1:255/224)
                let r=yy+2*(1-kr)*cr,b=yy+2*(1-kb)*cb,g=(yy-kr*r-kb*b)/(1-kr-kb),p=(y*w+x)*3
                out[p]=byte(r);out[p+1]=byte(g);out[p+2]=byte(b)
            }}
        }
        guard let provider=CGDataProvider(data:rgb as CFData),let cg=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:w*3,space:space,bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw ScanFailure.unsupportedImage}
        return cg
    }
    static func jpeg(_ buffer:CVPixelBuffer,limits:ScanLimits) throws -> Data {
        let cg=try colourImage(buffer,limits:limits),data=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil) else {throw ScanFailure.unsupportedImage}
        CGImageDestinationAddImage(destination,cg,[kCGImageDestinationLossyCompressionQuality:0.85,kCGImagePropertyOrientation:1] as CFDictionary)
        guard CGImageDestinationFinalize(destination),data.length<=limits.maximumImageBytes else {throw ScanFailure.capacity}
        return data as Data
    }
    static func png(original:Data,info:ScanImageInfo,limits:ScanLimits) throws -> Data {
        guard info.width>0,info.height>0,info.width<=limits.maximumImageSide,info.height<=limits.maximumImageSide,
              info.width<=limits.maximumImagePixels/info.height,info.planeWidths==[info.width,(info.width+1)/2],info.planeHeights==[info.height,(info.height+1)/2],
              info.packedRowBytes==[info.width,((info.width+1)/2)*2],original.count==info.byteCount,
              [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(info.pixelFormat) else {throw ScanFailure.unsupportedImage}
        var value:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,info.width,info.height,info.pixelFormat,nil,&value)==0,let buffer=value else {throw ScanFailure.capacity}
        guard CVPixelBufferLockBaseAddress(buffer,[])==0 else {throw ScanFailure.unsupportedImage}
        var offset=0
        for plane in 0..<2 {
            guard let base=CVPixelBufferGetBaseAddressOfPlane(buffer,plane) else {CVPixelBufferUnlockBaseAddress(buffer,[]);throw ScanFailure.unsupportedImage}
            original.withUnsafeBytes {bytes in for y in 0..<info.planeHeights[plane] {memcpy(base.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)),bytes.baseAddress!.advanced(by:offset+y*info.packedRowBytes[plane]),info.packedRowBytes[plane])}}
            offset+=info.packedRowBytes[plane]*info.planeHeights[plane]
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        for (name,key) in [("YCbCrMatrix",kCVImageBufferYCbCrMatrixKey),("ColorPrimaries",kCVImageBufferColorPrimariesKey),("TransferFunction",kCVImageBufferTransferFunctionKey)] {
            if let value=info.attributes[name] {CVBufferSetAttachment(buffer,key,value as CFString,.shouldPropagate)}
        }
        let cg=try colourImage(buffer,limits:limits,strictColour:true),data=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else {throw ScanFailure.unsupportedImage}
        CGImageDestinationAddImage(destination,cg,[kCGImagePropertyOrientation:1] as CFDictionary)
        guard CGImageDestinationFinalize(destination),data.length<=limits.maximumImageBytes else {throw ScanFailure.capacity};return data as Data
    }

}
