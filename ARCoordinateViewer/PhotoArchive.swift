import Foundation
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PhotoArchive {
    struct Package { var jpeg:Data; var record:PhotoCaptureRecord; var directory:URL }
    static var directory:URL { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("撮影記録",isDirectory:true) }
    static func cameraImage(_ buffer:CVPixelBuffer,orientation:CGImagePropertyOrientation) throws -> UIImage {
        let input=CIImage(cvPixelBuffer:buffer).oriented(orientation)
        guard let output=CIContext(options:[.cacheIntermediates:false]).createCGImage(input,from:input.extent) else { throw CocoaError(.fileReadCorruptFile) }
        return UIImage(cgImage:output)
    }
    static func json(_ record:PhotoCaptureRecord) throws -> Data {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let format=ISO8601DateFormatter();format.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            var value=encoder.singleValueContainer();try value.encode(format.string(from:date))
        }
        return try encoder.encode(record)
    }
    static func properties(_ record:PhotoCaptureRecord) throws -> [CFString:Any] {
        let time=DateFormatter();time.locale=Locale(identifier:"en_US_POSIX");time.timeZone=TimeZone(secondsFromGMT:0);time.dateFormat="yyyy:MM:dd HH:mm:ss"
        let fraction=record.capturedAt.timeIntervalSince1970-floor(record.capturedAt.timeIntervalSince1970)
        var result:[CFString:Any]=[
            kCGImageDestinationLossyCompressionQuality:0.97,
            kCGImagePropertyOrientation:1,
            kCGImagePropertyExifDictionary:[
                kCGImagePropertyExifVersion:[3,0,1],
                kCGImagePropertyExifDateTimeOriginal:time.string(from:record.capturedAt),
                kCGImagePropertyExifOffsetTimeOriginal:"+00:00",
                kCGImagePropertyExifSubsecTimeOriginal:String(format:"%03d",Int(fraction*1000)),
                kCGImagePropertyExifUserComment:"ARCoordinateViewerMetadata/1\n"+(String(data:try json(record),encoding:.utf8) ?? "")
            ],
            kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFSoftware:"ARCoordinateViewer",kCGImagePropertyTIFFImageDescription:"\(record.mode.title); AR alignment estimate; record \(record.id.uuidString)"]
        ]
        if record.georeferenceUsable {
            var latitude:Double?,longitude:Double?,altitude:Double?,altitudeRef:Int?,direction:Double?,directionRef:String?
            var datum="",method=""
            var accuracy:Double?
            if record.positionSource == .ar,let pose=record.pose {
                latitude=pose.latitude;longitude=pose.longitude;datum=record.context.settings.datum.title;method="AR_DIAGRAM_ALIGNMENT"
                direction=pose.trueDirectionDegrees;directionRef="T"
                // Exif 3.x: 0/1 ellipsoid, 2/3 sea level. Local or unknown Z is omitted.
                if let height=pose.altitudeMetres,height.isFinite {
                    if record.context.settings.heightReference == .ellipsoid { altitude=abs(height);altitudeRef=height<0 ? 1 : 0 }
                    if record.context.settings.heightReference == .seaLevel { altitude=abs(height);altitudeRef=height<0 ? 3 : 2 }
                }
            } else if let observation=record.deviceObservation,let location=observation.location {
                latitude=location.latitude;longitude=location.longitude;datum="WGS-84";method="CORE_LOCATION"
                accuracy=location.horizontalAccuracy
                if location.verticalAccuracy>=0,let height=location.ellipsoidalAltitude,height.isFinite {
                    altitude=abs(height);altitudeRef=height<0 ? 1 : 0
                }
                if record.deviceCameraDirectionUsable { direction=observation.cameraDirectionDegrees;directionRef=observation.cameraDirectionReference }
            }
            if let latitude,let longitude,latitude.isFinite,longitude.isFinite,abs(latitude)<=90,abs(longitude)<=180 {
                var gps:[CFString:Any]=[
                    kCGImagePropertyGPSVersion:[2,4,0,0],
                    kCGImagePropertyGPSLatitude:abs(latitude),kCGImagePropertyGPSLatitudeRef:latitude<0 ? "S" : "N",
                    kCGImagePropertyGPSLongitude:abs(longitude),kCGImagePropertyGPSLongitudeRef:longitude<0 ? "W" : "E",
                    kCGImagePropertyGPSMapDatum:datum,kCGImagePropertyGPSProcessingMethod:method
                ]
                if let direction,let directionRef,direction.isFinite { gps[kCGImagePropertyGPSImgDirection]=direction;gps[kCGImagePropertyGPSImgDirectionRef]=directionRef }
                if let altitude,let altitudeRef { gps[kCGImagePropertyGPSAltitude]=altitude;gps[kCGImagePropertyGPSAltitudeRef]=altitudeRef }
                if let accuracy,accuracy.isFinite,accuracy>=0 { gps[kCGImagePropertyGPSHPositioningError]=accuracy }
                result[kCGImagePropertyGPSDictionary]=gps
            }
        }
        return result
    }
    static func save(_ image:UIImage,record initial:PhotoCaptureRecord,to root:URL = directory) throws -> Package {
        let size=CGSize(width:image.size.width*image.scale,height:image.size.height*image.scale)
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
        let upright=UIGraphicsImageRenderer(size:size,format:format).image { _ in image.draw(in:CGRect(origin:.zero,size:size)) }
        guard let cg=upright.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        var record=initial;record.imageWidth=cg.width;record.imageHeight=cg.height;record.imageFileName="AR_\(record.id.uuidString).jpg"
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,UTType.jpeg.identifier as CFString,1,nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination,cg,try properties(record) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let manager=FileManager.default
        try manager.createDirectory(at:root,withIntermediateDirectories:true)
        let temporary=root.appendingPathComponent(".\(record.id.uuidString).writing",isDirectory:true)
        let date=DateFormatter();date.locale=Locale(identifier:"en_US_POSIX");date.dateFormat="yyyyMMdd_HHmmss"
        let folder=root.appendingPathComponent("\(date.string(from:record.capturedAt))_\(record.id.uuidString)",isDirectory:true)
        do {
            try manager.createDirectory(at:temporary,withIntermediateDirectories:false)
            let jpeg=output as Data
            try jpeg.write(to:temporary.appendingPathComponent(record.imageFileName),options:.atomic)
            try json(record).write(to:temporary.appendingPathComponent("AR_\(record.id.uuidString).json"),options:.atomic)
            try Data(PhotoPriors.referenceCSV(record).utf8).write(to:temporary.appendingPathComponent("reference.csv"),options:.atomic)
            try Data(PhotoPriors.guide(record).utf8).write(to:temporary.appendingPathComponent("取込方法.txt"),options:.atomic)
            if let xmp=PhotoPriors.realityScanXMP(record) {
                try Data(xmp.utf8).write(to:temporary.appendingPathComponent("AR_\(record.id.uuidString).xmp"),options:.atomic)
            }
            try manager.moveItem(at:temporary,to:folder)
            return Package(jpeg:jpeg,record:record,directory:folder)
        } catch { try? manager.removeItem(at:temporary);throw error }
    }
}
