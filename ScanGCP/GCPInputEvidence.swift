import Foundation
import simd
import CoreVideo

struct GCPDepthPatch:Codable,Equatable {
    enum Availability:String,Codable {case readable,unsupported,locked}
    var availability:Availability
    var width:Int;var height:Int;var bytesPerRow:Int;var format:UInt32
    var x:Int;var y:Int
    var confidenceWidth:Int?;var confidenceHeight:Int?;var confidenceBytesPerRow:Int?;var confidenceFormat:UInt32?
    /// Nine raw Float32 bit patterns (including invalid values); nil is outside.
    var bits:[UInt32?]
    var confidence:[UInt8?]
    func measurement()->GCPDepth? {
        guard availability == .readable,bits.count==9,confidence.count==9,let center=bits[4] else {return nil}
        let z=Double(Float(bitPattern:center));guard z.isFinite else {return nil}
        let values=bits.compactMap {$0.map {Double(Float(bitPattern:$0))}}.filter {$0.isFinite && $0>0}
        let spread=(values.max() ?? z)-(values.min() ?? z)
        let support=zip(bits,confidence).filter {bit,c in
            guard let bit,let c,c==1 || c==2 else {return false}
            let v=Float(bitPattern:bit);return v.isFinite && v>0
        }.count
        let edge=bits.contains(where:{$0==nil}) || values.count<9 || support<5
            || values.contains(where:{abs($0-z)>max(0.03,abs(z)*0.015)})
        let level:GCPDepthConfidence=confidence[4]==2 ? .high:confidence[4]==1 ? .medium:.low
        return GCPDepth(cameraZ:z,confidence:level,neighbourhoodSpread:spread,boundaryRisk:edge)
    }
}
struct GCPCaptureEvidence:Codable,Equatable {
    var frameID:UUID
    var frameTime:Double
    var cameraTransform:[Double]
    var cameraIntrinsics:[Double]
    var imageToView:[Double]
    var viewportWidth:Double;var viewportHeight:Double
    var imageX:Double;var imageY:Double
    var depthPatch:GCPDepthPatch?
    /// Legacy records used the viewport centre. Missing values preserve that meaning.
    var viewX:Double? = nil;var viewY:Double? = nil
    static func pose(_ m:[Double]) throws -> GCPPose {
        guard m.count==16,m.allSatisfy(\.isFinite),abs(m[3])+abs(m[7])+abs(m[11])+abs(m[15]-1)<1e-5 else {throw GCPFailure.calibration}
        let r=simd_double3x3(columns:(SIMD3(m[0],m[1],m[2]),SIMD3(m[4],m[5],m[6]),SIMD3(m[8],m[9],m[10])))
        guard abs(simd_determinant(r)-1)<1e-3,
              (0..<3).allSatisfy({abs(simd_length(r[$0])-1)<1e-3}),
              abs(simd_dot(r[0],r[1]))+abs(simd_dot(r[0],r[2]))+abs(simd_dot(r[1],r[2]))<1e-3 else {throw GCPFailure.calibration}
        let q=simd_normalize(simd_quatd(r))
        let pose=GCPPose(position:GCPVector(m[12],m[13],m[14]),qx:q.vector.x,qy:q.vector.y,qz:q.vector.z,qw:q.vector.w)
        guard pose.valid else {throw GCPFailure.calibration};return pose
    }
    func validate(_ o:GCPObservation) throws {
        guard frameTime==o.time,frameTime.isFinite,cameraIntrinsics.count==9,cameraIntrinsics.allSatisfy(\.isFinite),
              imageToView.count==6,imageToView.allSatisfy(\.isFinite),viewportWidth.isFinite,viewportHeight.isFinite,
              viewportWidth>0,viewportHeight>0,imageX>=0,imageX<1,imageY>=0,imageY<1 else {throw GCPFailure.calibration}
        let targetX=viewX ?? 0.5,targetY=viewY ?? 0.5
        guard (viewX==nil)==(viewY==nil),targetX.isFinite,targetY.isFinite,targetX>=0,targetX<1,targetY>=0,targetY<1 else {throw GCPFailure.calibration}
        let k=cameraIntrinsics,t=imageToView
        guard k[0]==o.intrinsics.fx,k[4]==o.intrinsics.fy,k[6]==o.intrinsics.cx,k[7]==o.intrinsics.cy,
              abs(k[1])+abs(k[2])+abs(k[3])+abs(k[5])+abs(k[8]-1)<1e-6,
              abs(t[0]*t[3]-t[1]*t[2])>1e-10,
              abs(t[0]*imageX+t[2]*imageY+t[4]-targetX)<1e-6,
              abs(t[1]*imageX+t[3]*imageY+t[5]-targetY)<1e-6,
              abs(imageX*Double(o.intrinsics.width)-o.pixelX)<1e-6,
              abs(imageY*Double(o.intrinsics.height)-o.pixelY)<1e-6 else {throw GCPFailure.calibration}
        let p=try Self.pose(cameraTransform)
        guard simd_length(p.position.v-o.pose.position.v)<1e-6,abs(simd_dot(p.rotation.vector,o.pose.rotation.vector))>1-1e-10 else {throw GCPFailure.calibration}
        if let d=depthPatch {
            guard d.width>0,d.height>0,d.width<=16384,d.height<=16384,d.bytesPerRow>=0,d.x>=0,d.x<d.width,d.y>=0,d.y<d.height else {throw GCPFailure.calibration}
            if d.availability == .readable {
                guard [kCVPixelFormatType_DepthFloat32,kCVPixelFormatType_OneComponent32Float].contains(d.format),
                      d.bytesPerRow>=d.width*4,d.bits.count==9,d.confidence.count==9,d.x==Int(imageX*Double(d.width)),d.y==Int(imageY*Double(d.height)) else {throw GCPFailure.calibration}
                if d.confidence.contains(where:{$0 != nil}) {
                    guard d.confidenceWidth==d.width,d.confidenceHeight==d.height,(d.confidenceBytesPerRow ?? 0)>=d.width,d.confidenceFormat==kCVPixelFormatType_OneComponent8 else {throw GCPFailure.calibration}
                }
            }
        }
        guard o.depth==depthPatch?.measurement() else {throw GCPFailure.calibration}
    }
}
