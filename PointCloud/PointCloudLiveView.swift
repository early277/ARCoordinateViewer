import SwiftUI
import ARKit
import SceneKit
import CoreImage
import CoreVideo

/// Uses one frame for RGB, depth, confidence, pose and calibration. Owned packed
/// bytes leave this function; ARFrame and borrowed CV buffers never enter I/O queue.
enum PCLiveInput {
    static func capture(_ frame:ARFrame,snapshot:GCPFrameSnapshot,epoch:GCPEpoch)throws->PCRawFrame {
        guard frame.timestamp==snapshot.time,frame.camera.transform==snapshot.camera,frame.camera.intrinsics==snapshot.intrinsics,
              snapshot.tracking == .normal,ProcessInfo.processInfo.systemUptime>=snapshot.time,ProcessInfo.processInfo.systemUptime-snapshot.time<=0.25,let depth=ScanDepthMap.capture(snapshot) else {throw PCFailure.invalidInput}
        let image=frame.capturedImage,info=ScanImageCodec.describe(image)
        guard info.width==Int(snapshot.imageSize.width),info.height==Int(snapshot.imageSize.height),
              info.attributes["ColorPrimaries"]==(kCVImageBufferColorPrimaries_ITU_R_709_2 as String) else {throw PCFailure.unsupportedColour}
        let matrix:String,transfer:String
        if info.attributes["YCbCrMatrix"]==(kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) {matrix="709"}
        else if info.attributes["YCbCrMatrix"]==(kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {matrix="601"}
        else {throw PCFailure.unsupportedColour}
        if info.attributes["TransferFunction"]==(kCVImageBufferTransferFunction_ITU_R_709_2 as String) {transfer="709"}
        else if info.attributes["TransferFunction"]==(kCVImageBufferTransferFunction_sRGB as String) {transfer="sRGB"}
        else {throw PCFailure.unsupportedColour}
        let d=snapshot.imageToView,k=snapshot.intrinsics
        let metadata=PCFrame(id:snapshot.frameID,sourceCameraTransform:snapshot.matrix,sourceCameraIntrinsics:(0..<3).flatMap{c in (0..<3).map{Double(k[c][$0])}},sourceImageAttributes:info.attributes,time:snapshot.time,epoch:epoch,automatic:true,pose:try GCPCaptureEvidence.pose(snapshot.matrix),
            intrinsics:GCPIntrinsics(width:info.width,height:info.height,fx:Double(k[0][0]),fy:Double(k[1][1]),cx:Double(k[2][0]),cy:Double(k[2][1])),
            depthWidth:depth.width,depthHeight:depth.height,fullRange:info.pixelFormat==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            colourMatrix:matrix,transfer:transfer,orientation:snapshot.orientationToken,imageToView:[d.a,d.b,d.c,d.d,d.tx,d.ty].map(Double.init))
        try metadata.validate()
        return PCRawFrame(frame:metadata,image:try ScanImageCodec.original(image,limits:ScanLimits()),depth:depth.cameraZBits,confidence:depth.confidence)
    }
}
/// Camera opacity is independent of geometry. No AR mesh, photo library, new
/// permissions, per-point entity or unbounded frame-retention is used.
@MainActor final class PCSceneView:UIView,@preconcurrency ARSessionDelegate,UIGestureRecognizerDelegate {
    let session=ARSession()
    let imageView=UIImageView()
    let sceneView=SCNView()
    // Low-resolution opaque progress surface; GCPs/camera remain separate.
    let coverageView=SCNView()
    let coverageScene=SCNScene(),coverageCamera=SCNNode()
    private let reticle=UIView(),reticleShape=CAShapeLayer()
    private var layoutRevision=0
    private var layoutSize=CGSize.zero
    let scene=SCNScene(),camera=SCNNode(),modelCamera=SCNNode(),cloud=SCNNode()
    var model:PCController
    private let torch:PCTorchControl
    private var torchAllowed=true
    private var torchContextPending=false
    private let imageWorker=DispatchQueue(label:"point-cloud-camera-preview",qos:.userInitiated)
    private let imageContext=CIContext(options:[.cacheIntermediates:false])
    private var rendering=false,running=false,modelMode=false
    private var lastImageTime = -Double.infinity
    private var lastPreviewRevision = -1
    private var lastCoverageStyle:Bool?
    private var cloudNodes:[SCNNode]=[]
    private var cloudChunkIDs:[UUID]=[]
    private var renderGeneration=0
    private var displayedSnapshot:GCPFrameSnapshot?
    private var markerNodes:[SCNNode]=[]
    private var lastMarkerPositions:[SIMD3<Float>?]=[]
    private var lastMarkerNumbers:[Int]=[]
    private var pendingRayNode:SCNNode?
    private var pendingRayID:UUID?
    private let pivotWorker=DispatchQueue(label:"point-cloud-model-pivot",qos:.userInitiated)
    private let pivotTap=UITapGestureRecognizer()
    private var pivotRequest=0
    private var pivotPicking=false
    private var pivotControl:PCWorkControl?
    private var latest:(ARFrame,GCPFrameSnapshot)?
    private let imu=PCIMUCollector()
    private var invalidated=false
    init(model:PCController,torch:PCTorchControl?=nil) {
        self.model=model;self.torch=torch ?? PCTorchControl();super.init(frame:.zero)
        backgroundColor = .black;imageView.alpha=1;imageView.contentMode = .scaleToFill
        addSubview(imageView);addSubview(coverageView);addSubview(sceneView);
        coverageView.scene=coverageScene;coverageView.backgroundColor = .clear;coverageView.isOpaque=false
        coverageView.alpha=PCCoverageDisplayStyle.opacity;coverageView.layer.allowsGroupOpacity=false
        coverageView.contentScaleFactor=PCCoverageDisplayStyle.renderScale;coverageView.isUserInteractionEnabled=false;coverageView.isHidden=true
        coverageView.preferredFramesPerSecond=12;coverageView.antialiasingMode = .none;coverageView.rendersContinuously=false
        coverageCamera.camera=SCNCamera();coverageScene.rootNode.addChildNode(coverageCamera)
        PCCameraBinding.bind(coverageView,to:coverageCamera,interactive:false)
        sceneView.backgroundColor = .clear;sceneView.scene=scene;sceneView.isOpaque=false
        camera.camera=SCNCamera();modelCamera.camera=SCNCamera();scene.rootNode.addChildNode(camera);scene.rootNode.addChildNode(modelCamera);scene.rootNode.addChildNode(cloud);PCCameraBinding.bind(sceneView,to:camera,interactive:false)
        sceneView.preferredFramesPerSecond=30;sceneView.antialiasingMode = .none;sceneView.rendersContinuously=false
        // Native geometry and sampling share one viewport, independent of SwiftUI's
        // safe area / navigation bar. No glyph baseline or visual offset is involved.
        reticle.isUserInteractionEnabled=false;reticle.backgroundColor = .clear
        reticleShape.strokeColor=UIColor.white.cgColor;reticleShape.lineWidth=1.5
        reticleShape.shadowColor=UIColor.black.cgColor;reticleShape.shadowOpacity=1;reticleShape.shadowRadius=1
        // This fixed screen reference remains visible even in saved-model view.
        // Tracking/depth/outcome never changes its appearance or visibility.
        reticle.layer.addSublayer(reticleShape);addSubview(reticle)
        pivotTap.numberOfTapsRequired=2;pivotTap.addTarget(self,action:#selector(selectOrbitCentre(_:)))
        pivotTap.delegate=self;sceneView.addGestureRecognizer(pivotTap)
        session.delegate=self;session.delegateQueue = .main
        model.startCamera={ [weak self] in self?.start() }
        model.stopCamera={ [weak self] in self?.pause() }
        model.captureVisibleGCP={ [weak self] in
            guard let self,!self.modelMode,!self.model.showingModel,!self.sceneView.isHidden,
                  let snapshot=self.displayedSnapshot,self.latest?.1.viewKey==snapshot.viewKey,
                  ProcessInfo.processInfo.systemUptime-snapshot.time<=0.25 else {return nil}
            return snapshot
        }
        model.captureLast={ [weak self] in
            guard let self,let (frame,snapshot)=self.latest,ProcessInfo.processInfo.systemUptime-snapshot.time<0.25,snapshot.tracking == .normal else {return nil}
            return try? PCLiveInput.capture(frame,snapshot:snapshot,epoch:self.model.input.epoch)
        }
    }
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
    override func layoutSubviews() {
        super.layoutSubviews();imageView.frame=bounds;sceneView.frame=bounds;coverageView.frame=bounds
        coverageView.contentScaleFactor=PCCoverageDisplayStyle.renderScale
        reticle.bounds=CGRect(x:0,y:0,width:32,height:32);reticle.center=CGPoint(x:bounds.midX,y:bounds.midY)
        reticleShape.frame=reticle.bounds
        let path=UIBezierPath();path.move(to:CGPoint(x:2,y:16));path.addLine(to:CGPoint(x:30,y:16))
        path.move(to:CGPoint(x:16,y:2));path.addLine(to:CGPoint(x:16,y:30));reticleShape.path=path.cgPath
        if layoutSize != bounds.size {
            layoutSize=bounds.size;layoutRevision+=1;renderGeneration+=1;latest=nil;displayedSnapshot=nil;imageView.image=nil
            if !modelMode {sceneView.isHidden=true;coverageView.isHidden=true}
            for node in cloudNodes where node.name=="capture-coverage" {
                PCSceneGeometry.configureCoverage(node.geometry,viewport:bounds.size)
                PCSceneGeometry.configureCoverage(node.childNodes.first?.geometry,viewport:bounds.size)
            }
            model.input.cancelRequest(reason:.viewChanged)
            pivotControl?.cancel()
        }
    }
    func start() {
        guard !running,!invalidated else {return};running=true
        let configuration=ARWorldTrackingConfiguration();configuration.frameSemantics=[.sceneDepth]
        configuration.planeDetection=[];configuration.environmentTexturing = .none
        imu.start()
        session.run(configuration)
        updateTorchContext()
    }
    // Representable updates must not synchronously publish back into SwiftUI.
    // Recheck the actual context on the next main turn so stale AR/model work
    // cannot reactivate the light. Retain the control until close can turn it off.
    private func updateTorchContext() {
        guard !torchContextPending else {return};torchContextPending=true
        DispatchQueue.main.async { [weak self,torch] in
            guard let self else {torch.setCameraActive(false);return}
            self.torchContextPending=false
            torch.setCameraActive(!self.invalidated && self.running && !self.model.showingModel && self.torchAllowed)
        }
    }
    func setTorchAllowed(_ allowed:Bool) {torchAllowed=allowed;updateTorchContext()}
    func pause(){imu.stop();session.pause();running=false;latest=nil;displayedSnapshot=nil;renderGeneration+=1;updateTorchContext()}
    func close(){invalidated=true;pivotControl?.cancel();pause();model.startCamera=nil;model.stopCamera=nil;model.captureLast=nil;model.captureVisibleGCP=nil;session.delegate=nil}
    func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard !invalidated,running,let orientation=window?.windowScene?.interfaceOrientation,
              let snapshot=GCPARFrameAdapter.snapshot(frame,viewport:sceneView.bounds.size,orientation:orientation,targetInView:sceneView.convert(CGPoint(x:reticle.bounds.midX,y:reticle.bounds.midY),from:reticle)) else {return}
        model.cameraSessionChanged(session.identifier,now:frame.timestamp)
        guard running else {return}
        if latest==nil {torch.refreshAvailability()}
        latest=(frame,snapshot)
        model.receive(snapshot,imu:imu.samples(through:frame.timestamp),cameraFromDevice:PCIMUCollector.cameraFromDevice(frame:frame),imuStatus:imu.stateDescription) {
            do {return try PCLiveInput.capture(frame,snapshot:snapshot,epoch:self.model.input.epoch)}
            catch {self.model.message="入力待機: \(PCMessage.error(error))";return nil}
        }
        guard !model.showingModel,!rendering,frame.timestamp-lastImageTime>=1/12,ProcessInfo.processInfo.systemUptime-frame.timestamp<=0.25 else {return}
        rendering=true;lastImageTime=frame.timestamp
        let revision=layoutRevision,generation=renderGeneration,renderKey=snapshot.viewKey
        let image=CIImage(cvPixelBuffer:frame.capturedImage),w=Double(image.extent.width),h=Double(image.extent.height)
        let scale=min(1,720/max(bounds.width,bounds.height)),width=max(1,Int(bounds.width*scale)),height=max(1,Int(bounds.height*scale))
        let d=snapshot.imageToView,W=Double(width),H=Double(height)
        // CI coordinates bottom-left -> image-normalized top-left -> display
        // transform -> CI output bottom-left. This handles all device rotations/crop.
        let transform=PCDisplayMapping.cameraImage(d,width:w,height:h,outputWidth:W,outputHeight:H)
        let projection=frame.camera.projectionMatrix(for:orientation,viewportSize:bounds.size,zNear:0.05,zFar:1000)
        var pose=frame.camera.viewMatrix(for:orientation).inverse;let offset=model.cameraOffset;pose.columns.3+=SIMD4(offset,0)
        imageWorker.async { [weak self] in
            guard let self else {return}
            let cg=self.imageContext.createCGImage(image.transformed(by:transform).cropped(to:CGRect(x:0,y:0,width:width,height:height)),from:CGRect(x:0,y:0,width:width,height:height))
            DispatchQueue.main.async {
                self.rendering=false
                guard !self.invalidated,self.running,!self.model.showingModel,
                      self.layoutRevision==revision,self.renderGeneration==generation,self.latest?.1.viewKey==renderKey,self.model.cameraOffset==offset,
                      ProcessInfo.processInfo.systemUptime-snapshot.time<=0.25,let cg else {return}
                SCNTransaction.begin();SCNTransaction.disableActions=true
                self.camera.simdTransform=pose;self.camera.camera?.projectionTransform=SCNMatrix4(projection)
                self.coverageCamera.simdTransform=pose;self.coverageCamera.camera?.projectionTransform=SCNMatrix4(projection)
                PCCameraBinding.bind(self.sceneView,to:self.camera,interactive:false)
                SCNTransaction.commit()
                self.imageView.image=UIImage(cgImage:cg);self.displayedSnapshot=snapshot
                self.imageView.isHidden=false;self.sceneView.isHidden=false
                self.coverageView.isHidden=self.lastCoverageStyle != true
                self.sceneView.setNeedsDisplay();if !self.coverageView.isHidden {self.coverageView.setNeedsDisplay()}
            }
        }
    }
    func session(_ session:ARSession,cameraDidChangeTrackingState camera:ARCamera) {model.cameraTrackingChanged(GCPARFrameAdapter.tracking(camera.trackingState))}
    func sessionWasInterrupted(_ session:ARSession){model.interrupted()}
    func session(_ session:ARSession,didFailWithError error:Error){model.stop(reason:"ARセッションエラー: \(error.localizedDescription)",closingFrame:false);model.interrupted()}
    func refresh() {
        let geometryChanged=lastPreviewRevision != model.previewRevision
        let coverageStyle=model.detailPreview==nil && !model.showingModel
        let coverageStyleChanged=lastCoverageStyle != coverageStyle
        if geometryChanged || coverageStyleChanged {
            lastCoverageStyle=coverageStyle
            // Move the SAME immutable nodes between render layers. No duplicate
            // point buffers, second AR session, or transparent point material.
            let parent=coverageStyle ? coverageScene.rootNode:scene.rootNode
            if cloud.parent !== parent {cloud.removeFromParentNode();parent.addChildNode(cloud)}
            coverageView.isHidden = !coverageStyle || sceneView.isHidden
            pivotControl?.cancel()
            lastPreviewRevision=model.previewRevision
            // Immutable buffers are packed on the store worker. Preserve nodes
            // for the unchanged prefix; a new recording frame adds only its chunk.
            let chunks=(model.detailPreview ?? model.recordingPreview).chunks
            let common=coverageStyleChanged ? 0:zip(cloudChunkIDs,chunks).prefix(while:{$0.0==$0.1.id}).count
            for node in cloudNodes.dropFirst(common) {node.removeFromParentNode()}
            cloudNodes=Array(cloudNodes.prefix(common));cloudChunkIDs=Array(cloudChunkIDs.prefix(common))
            for chunk in chunks.dropFirst(common) {
                let node=SCNNode(geometry:PCSceneGeometry.cloud(chunk,coverage:coverageStyle));cloud.addChildNode(node);cloudNodes.append(node);cloudChunkIDs.append(chunk.id)
                if coverageStyle {
                    node.name="capture-coverage"
                    PCSceneGeometry.configureCoverage(node.geometry,viewport:sceneView.bounds.size)
                }
            }
            if !coverageView.isHidden {coverageView.setNeedsDisplay()};sceneView.setNeedsDisplay()
        }
        let markerPositions=model.markerPositions,numbers=model.gcpNumbers
        if lastMarkerPositions != markerPositions || lastMarkerNumbers != numbers {
            lastMarkerPositions=markerPositions;lastMarkerNumbers=numbers
            for node in markerNodes {node.removeFromParentNode()};markerNodes=[]
            for (i,position) in markerPositions.enumerated() {
                guard let position else {continue} // Never draw a point in a different coordinate frame.
                let node=PCSceneGeometry.marker(position:position,number:numbers.indices.contains(i) ? numbers[i]:i+1)
                scene.rootNode.addChildNode(node);markerNodes.append(node)
            }
        }
        let pending=model.phase == .recording ? model.pendingGCPRay:nil
        if pendingRayID != pending?.id {
            pendingRayNode?.removeFromParentNode();pendingRayNode=nil;pendingRayID=pending?.id
            if let pending,let ray=try? pending.ray() {
                let node=PCSceneGeometry.observationRay(origin:SIMD3<Float>(ray.origin),direction:SIMD3<Float>(ray.direction))
                scene.rootNode.addChildNode(node);pendingRayNode=node
            }
        }
        for case let gesture as UITapGestureRecognizer in sceneView.gestureRecognizers ?? [] where gesture !== pivotTap && gesture.numberOfTapsRequired==2 {gesture.isEnabled=false}
        let offline=model.showingModel
        updateTorchContext()
        if !offline && modelMode {
            pivotControl?.cancel()
            modelMode=false;renderGeneration+=1;displayedSnapshot=nil;lastImageTime = -.infinity
            imageView.image=nil;imageView.isHidden=true;sceneView.isHidden=true;coverageView.isHidden=true
            // Never let model-camera inertia or SceneKit's internal POV survive
            // AR return. Wait for a fresh image+pose pair before showing geometry.
            PCCameraBinding.bind(sceneView,to:camera,interactive:false)
        }
        if offline && (!modelMode || geometryChanged) {
            modelMode=true;renderGeneration+=1;displayedSnapshot=nil;imageView.isHidden=true;sceneView.isHidden=false;coverageView.isHidden=true
            let detail=model.detailPreview ?? model.recordingPreview,centre=detail.centre,radius=detail.radius
            SCNTransaction.begin();SCNTransaction.disableActions=true
            modelCamera.camera=SCNCamera();modelCamera.camera?.fieldOfView=60;modelCamera.camera?.zNear=0.02
            modelCamera.camera?.zFar=Double(max(100,radius*5))
            modelCamera.position=SCNVector3(centre.x,centre.y+radius*0.25,centre.z+radius*2.5);modelCamera.look(at:SCNVector3(centre))
            PCCameraBinding.bind(sceneView,to:modelCamera,interactive:true)
            for case let gesture as UITapGestureRecognizer in sceneView.gestureRecognizers ?? [] where gesture !== pivotTap && gesture.numberOfTapsRequired==2 {gesture.isEnabled=false}
            sceneView.defaultCameraController.automaticTarget=false
            sceneView.defaultCameraController.target=SCNVector3(centre)
            SCNTransaction.commit();sceneView.setNeedsDisplay()
        }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer)->Bool {
        gestureRecognizer !== pivotTap || (modelMode && model.showingModel && !sceneView.isHidden)
    }
    @objc private func selectOrbitCentre(_ gesture:UITapGestureRecognizer) {
        guard gesture.state == .ended,!pivotPicking,modelMode,model.showingModel,let pov=sceneView.pointOfView,let lens=pov.camera else {return}
        sceneView.defaultCameraController.stopInertia()
        let chunks=(model.detailPreview ?? model.recordingPreview).chunks
        let clip=simd_float4x4(lens.projectionTransform(withViewportSize:sceneView.bounds.size))*pov.presentation.simdWorldTransform.inverse
        let location=gesture.location(in:sceneView),size=sceneView.bounds.size
        let viewport=SIMD2<Float>(Float(size.width),Float(size.height)),tap=SIMD2<Float>(Float(location.x),Float(location.y))
        pivotPicking=true
        let control=PCWorkControl(seconds:5);pivotControl=control
        pivotRequest+=1;let request=pivotRequest,revision=model.previewRevision,generation=renderGeneration,layout=layoutRevision
        let pose=pov.presentation.simdWorldTransform
        pivotWorker.async { [weak self] in
            let point=PCOrbitPicking.point(chunks:chunks,clipFromWorld:clip,viewport:viewport,tap:tap,control:control)
            DispatchQueue.main.async {
                guard let self else {return}
                guard self.pivotRequest==request else {return}
                self.pivotPicking=false;self.pivotControl=nil
                do {try control.check()} catch {return}
                guard !self.invalidated,self.modelMode,self.model.showingModel,self.pivotRequest==request,
                      self.renderGeneration==generation,self.layoutRevision==layout,
                      self.model.previewRevision==revision,self.sceneView.pointOfView===pov,
                      pov.presentation.simdWorldTransform==pose,let point else {return}
                _=PCCameraBinding.focus(self.sceneView,camera:pov,point:point,from:pose)
                // Viewer-only recenter + small dolly; source coordinates unchanged.
                self.sceneView.setNeedsDisplay()
            }
        }
    }

}
struct PCLiveView:UIViewRepresentable {
    @ObservedObject var model:PCController
    var torch:PCTorchControl?=nil
    var torchAllowed=true
    func makeUIView(context:Context)->PCSceneView {let view=PCSceneView(model:model,torch:torch);view.setTorchAllowed(torchAllowed);return view}
    func updateUIView(_ uiView:PCSceneView,context:Context){uiView.setTorchAllowed(torchAllowed);uiView.refresh()}
    static func dismantleUIView(_ uiView:PCSceneView,coordinator:()){uiView.close()}
}

/// Geometry also exercised with synthetic buffers on macOS; no camera access.
enum PCSceneGeometry {
    static func cloud(_ chunk:PCPreviewChunk,coverage:Bool=false)->SCNGeometry {
        let source=SCNGeometrySource(data:chunk.positions,semantic:.vertex,vectorCount:chunk.count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:0,dataStride:12)
        // PCPreviewPacking already decoded sRGB once for SceneKit's linear
        // working space. Live and stored models share this exact path.
        let colour=SCNGeometrySource(data:chunk.colours,semantic:.color,vectorCount:chunk.count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let element=SCNGeometryElement(data:chunk.indices,primitiveType:.point,primitiveCount:chunk.count,bytesPerIndex:4)
        element.pointSize=coverage ? PCCoverageDisplayStyle.nativePointSize:4
        element.minimumPointScreenSpaceRadius=coverage ? PCCoverageDisplayStyle.minimumPointRadius:1
        element.maximumPointScreenSpaceRadius=coverage ? PCCoverageDisplayStyle.pointRadius:4
        let geometry=SCNGeometry(sources:[source,colour],elements:[element]),material=SCNMaterial()
        material.lightingModel = .constant;material.diffuse.contents=UIColor.white
        if coverage {material.blendMode = .replace;material.transparency=1;material.writesToDepthBuffer=true}
        geometry.materials=[material];return geometry
    }
    /// Keep the SAME fixed 56pt aiming aperture in every live frame. Only the
    /// progress layer is hidden here; raw camera/depth and the reticle are intact.
    /// Vertex rejection runs on the GPU, so moving the camera never rebuilds
    /// 50,000 CPU vertices and never changes a GCP observation's sampling point.
    static func configureCoverage(_ geometry:SCNGeometry?,viewport:CGSize) {
        guard let geometry else {return}
        if geometry.shaderModifiers==nil {
            geometry.shaderModifiers=[.geometry:"""
            #pragma arguments
            float3 pcCoverageViewport;
            #pragma body
            float4 pcClip = scn_node.modelViewProjectionTransform * _geometry.position;
            float2 pcPixel = (pcClip.xy / max(abs(pcClip.w), 0.000001)) * pcCoverageViewport.xy * 0.5;
            if (pcClip.w > 0.0 && dot(pcPixel, pcPixel) < pcCoverageViewport.z * pcCoverageViewport.z) {
                _geometry.position = float4(0.0, 0.0, 100000000.0, 1.0);
            }
            """]
        }
        geometry.setValue(NSValue(scnVector3:SCNVector3(Float(viewport.width),Float(viewport.height),56)),forKey:"pcCoverageViewport")
    }
    /// Legacy build70 comparison only. Live progress no longer creates rims.
    static func coverageOutline(_ chunk:PCPreviewChunk)->SCNGeometry {
        let source=SCNGeometrySource(data:chunk.positions,semantic:.vertex,vectorCount:chunk.count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:0,dataStride:12)
        let element=SCNGeometryElement(data:chunk.indices,primitiveType:.point,primitiveCount:chunk.count,bytesPerIndex:4)
        element.pointSize=7;element.minimumPointScreenSpaceRadius=2.5;element.maximumPointScreenSpaceRadius=PCCoverageDisplayStyle.outlineRadius
        let geometry=SCNGeometry(sources:[source],elements:[element]),material=SCNMaterial()
        material.lightingModel = .constant;material.diffuse.contents=UIColor.black
        material.blendMode = .replace;material.transparency=1;material.writesToDepthBuffer=false;geometry.materials=[material];return geometry
    }
    /// A fixed-length guide shows the measured bearing, never an invented endpoint.
    static func observationRay(origin:SIMD3<Float>,direction:SIMD3<Float>)->SCNNode {
        let end=origin+direction*8
        let source=SCNGeometrySource(vertices:[SCNVector3(origin),SCNVector3(end)])
        let element=SCNGeometryElement(indices:[UInt32(0),UInt32(1)],primitiveType:.line)
        let geometry=SCNGeometry(sources:[source],elements:[element]),material=SCNMaterial()
        material.diffuse.contents=UIColor.systemYellow;material.lightingModel = .constant
        material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false;geometry.materials=[material]
        let node=SCNNode(geometry:geometry);node.name="GCP-first-bearing-guide-8m";node.opacity=1;node.renderingOrder=102;return node
    }
    static func marker(position:SIMD3<Float>,number:Int)->SCNNode {
        let root=SCNNode();root.simdPosition=position;root.name="GCP-\(number)";root.opacity=1
        let dot=SCNNode(geometry:SCNSphere(radius:0.018));dot.name="point";dot.opacity=1;dot.renderingOrder=100
        let material=SCNMaterial();material.diffuse.contents=UIColor.yellow;material.lightingModel = .constant
        material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false;dot.geometry?.materials=[material]
        root.addChildNode(dot) // Local origin is exactly the measured GCP position.
        let text=SCNText(string:"G\(number)",extrusionDepth:0);text.font=UIFont.boldSystemFont(ofSize:12);text.flatness=0.4
        text.materials=[material]
        let label=SCNNode(geometry:text);label.name="label";label.simdPosition=PCGCPDisplay.labelOffset
        label.scale=SCNVector3(0.005,0.005,0.005);label.constraints=[SCNBillboardConstraint()];label.opacity=1;label.renderingOrder=101
        root.addChildNode(label);return root
    }
}

/// Used by the real UIView and the host SceneKit render/interaction regression.
@MainActor enum PCCameraBinding {
    @discardableResult static func focus(_ view:SCNView,camera:SCNNode,point:SIMD3<Float>,from pose:simd_float4x4)->Bool {
        guard let focused=PCOrbitFocus.camera(from:pose,toward:point,near:Float(camera.camera?.zNear ?? 0.02)) else {return false}
        view.defaultCameraController.stopInertia()
        SCNTransaction.begin();SCNTransaction.disableActions=true
        camera.simdWorldTransform=focused
        view.defaultCameraController.automaticTarget=false
        view.defaultCameraController.pointOfView=camera;view.pointOfView=camera
        view.defaultCameraController.target=SCNVector3(point)
        SCNTransaction.commit();return true
    }
    static func bind(_ view:SCNView,to camera:SCNNode,interactive:Bool) {
        view.defaultCameraController.stopInertia()
        view.allowsCameraControl=interactive
        if interactive {
            view.cameraControlConfiguration.allowsTranslation=true
            view.cameraControlConfiguration.autoSwitchToFreeCamera=false
            view.defaultCameraController.interactionMode = .orbitTurntable
        }
        view.defaultCameraController.pointOfView=camera
        view.pointOfView=camera
    }
}
