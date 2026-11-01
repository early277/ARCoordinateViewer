import ARKit
import UIKit

enum GCPARFrameAdapter {
    static func tracking(_ state:ARCamera.TrackingState)->GCPTracking {
        switch state {
        case .normal:return .normal
        case .notAvailable:return .unavailable
        case .limited(.relocalizing):return .relocalizing
        case .limited:return .limited
        }
    }
    /// No capturedImage access, photo capture, scene configuration or session run.
    static func snapshot(_ frame:ARFrame,viewport:CGSize,orientation:UIInterfaceOrientation,targetInView:CGPoint?=nil)->GCPFrameSnapshot? {
        guard orientation != .unknown,viewport.width>0,viewport.height>0 else {return nil}
        let target=targetInView ?? CGPoint(x:viewport.width/2,y:viewport.height/2)
        guard target.x.isFinite,target.y.isFinite,target.x>=0,target.x<viewport.width,target.y>=0,target.y<viewport.height else {return nil}
        let camera=frame.camera,depth=frame.sceneDepth
        return GCPFrameSnapshot(time:frame.timestamp,tracking:tracking(camera.trackingState),camera:camera.transform,
            intrinsics:camera.intrinsics,imageSize:camera.imageResolution,viewport:viewport,
            imageToView:frame.displayTransform(for:orientation,viewportSize:viewport),orientationToken:orientation.rawValue,
            depth:depth?.depthMap,confidence:depth?.confidenceMap,targetInView:CGPoint(x:target.x/viewport.width,y:target.y/viewport.height))
    }
}
