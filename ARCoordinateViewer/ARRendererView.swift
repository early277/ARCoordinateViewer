import SwiftUI
import RealityKit
import ARKit
import AVFoundation
import Photos
import UIKit
import ImageIO

private struct HeadingStabilizationInput: Equatable {
    var enabled: Bool
    var updatesActive: Bool
    var compassHeadingDegrees: Double?
    var compassAccuracyDegrees: Double
}

/// ARSessionDelegateはnonisolatedで呼ばれるため、AppModelを直接保持・参照しない。
/// UIへの反映だけをMainActor上の橋渡しオブジェクトへ集約する。
private final class ARRendererUIBridge {
    @MainActor weak var model: AppModel?

    @MainActor
    func updateStatus(_ message: String) {
        model?.arStatusMessage = message
    }

    @MainActor
    func updateLabels(_ labels: [ScreenLabel]) {
        model?.screenLabels = labels
    }

    @MainActor
    func updateLiDARSupport(_ supported: Bool, disableRequestedSetting: Bool) {
        if model?.lidarSupported != supported { model?.lidarSupported = supported }
        if disableRequestedSetting {
            if model?.lidarEnabled == true { model?.lidarEnabled = false }
        }
    }

    @MainActor
    func updateHeadingCorrection(_ degrees: Double) {
        model?.updateAutomaticHeadingCorrectionFromRenderer(degrees)
    }

    @MainActor
    func updateHorizontalScreenBasis(_ basis: HorizontalScreenBasis) {
        model?.updateHorizontalScreenBasis(basis)
    }

    @MainActor
    func photoCaptureStarted(_ requestID: Int) {
        model?.photoCaptureDidStart(requestID: requestID)
    }

    @MainActor
    func photoCaptureSaving(_ requestID: Int) {
        model?.photoCaptureDidBeginSaving(requestID: requestID)
    }

    @MainActor
    func photoCaptureSucceeded(_ requestID: Int, message:String) {
        model?.photoCaptureSucceeded(requestID: requestID,message:message)
    }

    @MainActor
    func photoCaptureFailed(_ requestID: Int, message: String) {
        model?.photoCaptureFailed(requestID: requestID, message: message)
    }
}

private final class DrawingTapRecognizer: UIGestureRecognizer {
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var startTime: TimeInterval = 0
    private var travel = 0.0
    private var trackingTouch:UITouch?
    override func touchesBegan(_ touches:Set<UITouch>, with event:UIEvent) {
        guard trackingTouch == nil, touches.count == 1, let touch=touches.first, state == .possible else { state = .failed; return }
        trackingTouch=touch
        startPoint=touch.location(in:view); lastPoint=startPoint; startTime=touch.timestamp; travel=0
    }
    override func touchesMoved(_ touches:Set<UITouch>, with event:UIEvent) {
        guard let touch=touches.first else { return }
        lastPoint=touch.location(in:view)
        travel=max(travel,Double(hypot(lastPoint.x-startPoint.x,lastPoint.y-startPoint.y)))
        if travel > DrawingTapPolicy.maxTravel { state = .failed }
    }
    override func touchesEnded(_ touches:Set<UITouch>, with event:UIEvent) {
        guard state == .possible, let touch=touches.first else { return }
        lastPoint=touch.location(in:view)
        travel=max(travel,Double(hypot(lastPoint.x-startPoint.x,lastPoint.y-startPoint.y)))
        state=DrawingTapPolicy.accepts(travel:travel,duration:touch.timestamp-startTime) ? .recognized : .failed
    }
    override func touchesCancelled(_ touches:Set<UITouch>, with event:UIEvent) { state = .cancelled }
    override func location(in target:UIView?) -> CGPoint { view?.convert(lastPoint,to:target) ?? lastPoint }
    override func reset() { super.reset(); trackingTouch=nil; travel=0; startTime=0 }
}

struct ARRendererView: UIViewRepresentable {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var locationManager: LocationManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

        // AR画面の背景は必ずカメラ映像にする。
        // ここが黒背景になると、RealityKitの3D描画だけが見えて現実背景が見えないため、
        // 明示的に cameraFeed を指定しておく。
        arView.isOpaque = false
        arView.backgroundColor = .clear
        arView.environment.background = .cameraFeed(exposureCompensation: 0.45)
        // ARSessionDelegate側でもRealityKit EntityとCoordinator内の表示状態を更新する。
        // SwiftUI更新との競合を避けるため、delegate callbackをメインキューへ統一する。
        arView.session.delegateQueue = .main
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView
        context.coordinator.scanInput = model.scanFeatureAvailable ? model.scanInput : nil
        context.coordinator.scanCapture = model.scanFeatureAvailable ? model.scanCapture : nil
        let drawingTap = DrawingTapRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDrawingTap(_:)))
        drawingTap.cancelsTouchesInView = false
        drawingTap.delegate = context.coordinator
        arView.addGestureRecognizer(drawingTap)

        context.coordinator.rootAnchor = AnchorEntity(world: .zero)
        if let root = context.coordinator.rootAnchor {
            arView.scene.addAnchor(root)
        }

        context.coordinator.setSessionActive(model.arCameraActive, on: arView)
        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.uiBridge.model = model
        context.coordinator.arView = arView
        context.coordinator.scanInput = model.scanFeatureAvailable ? model.scanInput : nil
        context.coordinator.scanCapture = model.scanFeatureAvailable ? model.scanCapture : nil
        if model.scanFeatureAvailable {
            model.scanInput.alignmentChanged(model.positionAlignmentRevision)
            if !model.arCameraActive || model.treeSurvey.active || model.drawing.active || model.drawingSelectionMode {
                model.scanCapture.stop(reason:"AR画面または測定モードの変更")
            }
        }
        context.coordinator.synchronizeDroggerContext(model:model)
        context.coordinator.setSessionActive(model.arCameraActive, on: arView)
        context.coordinator.setScanCaptureEnabled(model.scanFeatureAvailable && model.scanCapture.isRecording, on:arView)
        if model.scanFeatureAvailable {
            context.coordinator.scanPreviewRenderer.update(model.scanCapture,view:arView,frame:model.arCameraActive ? arView.session.currentFrame:nil)
        }
        context.coordinator.setLiDARPreference(model.lidarEnabled, measurementEnabled: model.drawing.active || model.treeSurvey.active, on: arView)
        context.coordinator.setLiDARFadePreference(
            enabled: model.settings.lidarFadeBehindObjectsEnabled,
            behindOpacity: Float(model.settings.lidarBehindOpacity)
        )
        context.coordinator.consumeTreeCaptureRequest()
        context.coordinator.consumeDrawingCaptureRequest()
        guard model.arCameraActive else { return }
        guard let root = context.coordinator.rootAnchor else { return }

        // UI/モデルのMainActor値は、SwiftUI更新時に値型としてCoordinatorへコピーする。
        // ARフレーム処理からAppModelのactor-isolatedプロパティは参照しない。
        let renderedRootHeight = Float(model.effectiveDisplayPlaneOffsetMeters)
        let renderedTotalHeading = context.coordinator.updateDisplayState(
            eastMeters: Float(model.planePanEastMeters),
            northMeters: Float(model.planePanNorthMeters),
            heightMeters: renderedRootHeight,
            manualHeadingDegrees: model.headingOffsetDegrees,
            automaticHeadingDegrees: model.automaticHeadingCorrectionDegrees,
            headingInput: HeadingStabilizationInput(
                enabled: model.settings.headingStabilizationEnabled,
                updatesActive: model.arCameraActive,
                compassHeadingDegrees: locationManager.compassHeadingDegrees,
                compassAccuracyDegrees: locationManager.compassAccuracyDegrees
            ),
            interfaceOrientation: arView.window?.windowScene?.interfaceOrientation ?? .portrait
        )
        context.coordinator.recordRenderedTransform(model:model,heading:renderedTotalHeading,height:Double(renderedRootHeight))

        // 撮影要求は、表示要素が多い場合の再描画判定より先に受け付ける。
        // タップ後の反応を遅らせず、Coordinator側の監視タイマーもすぐ開始する。
        // AppModel側ですでにタイムアウト／失敗になった古い要求を、画面復帰後に
        // 遅れて撮影しない。要求が有効な撮影待ち状態の間だけCoordinatorへ渡す。
        context.coordinator.updatePhotoContext(model:model,location:locationManager)
        if model.photoCaptureState == .capturing {
            context.coordinator.capturePhotoIfRequested(model.photoCaptureRequestID, from: arView)
        }

        context.coordinator.render(
            features: model.renderFeatures,
            rasters: model.renderRasters,
            labels: model.renderLabels,
            selectedPosition: model.selectedRenderPosition,
            style: model.renderStyle,
            showPillars: model.pillarsEnabled,
            showDistance: model.distancesEnabled,
            into: root
        )
        context.coordinator.updateDrawing(model: model)
        context.coordinator.updateTreeDisplay(model:model)
    }

    final class Coordinator: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer) -> Bool {
            gestureRecognizer is DrawingTapRecognizer || other is DrawingTapRecognizer
        }

        fileprivate let uiBridge = ARRendererUIBridge()
        weak var arView: ARView?
        weak var scanInput: GCPInputSession?
        weak var scanCapture: ScanCaptureController?
        private var scanReconstructionEnabled=false
        fileprivate let scanPreviewRenderer=ScanPreviewRenderer()
        var rootAnchor: AnchorEntity?

        private var drawingEntity = Entity()
        private var lastTreeCaptureRequest = 0
        private var lastDrawingCaptureRequest = 0
        private var treeEntity = Entity()
        private var treeRayAnchor = AnchorEntity(world:.zero)
        private var treeMeshes:[UUID:(entity:Entity,visual:TreeVisual,labels:[TreeExtraLabel])] = [:]
        private lazy var treeBodyMesh=makeTreeUnitMesh(ring:false)
        private lazy var treeRingMesh=makeTreeUnitMesh(ring:true)
        private var treeDirectionsEntity=Entity()
        private var treeDirectionsKey=""
        private var treeDirectionLabels:[TreeExtraLabel]=[]
        private let treeDirectionIDs=[UUID(),UUID()]
        private var treeExtraLabels:[TreeExtraLabel]=[]
        private struct TreeExtraLabel {var id:UUID;var position:SIMD3<Float>;var text:String}
        private var treeProjectionKey = ""
        private struct TreeVisual:Equatable {
            var id:UUID;var position:SIMD3<Float>;var radius:Float;var color:TreeColor;var number:String
            var bounds:TreePreviewBounds?;var lower:Float?;var upper:Float?;var ticks:[Int]=[]
            var preview=false
        }
        private var treeVisuals: [TreeVisual] = []
        private var treeLabels: [TreeVisual] = []
        private var lastTreeDisplayTime: Double = 0
        private var lastTreeRays: [ObservationRay] = []
        private var treeMarkers: [UUID:(entity:ModelEntity,position:SIMD3<Float>,scale:Float)] = [:]
        private var treeMarkerLabels: [(id:UUID,position:SIMD3<Float>,number:Int)] = []
        private var observationAnchor = AnchorEntity(world: .zero)
        private var observationRay: ObservationRay?
        private var observationEpoch = 0
        private var droggerWorldEpoch = 0
        private var droggerOffset = SIMD3<Float>.zero
        private var drawingResetID = 0
        private var importedSnapPaths:[DrawingSnapPath] = []
        private var drawnSnapPaths:[DrawingSnapPath] = []
        private var snapImportRevision = -1
        private var snapDrawingVersion:DrawingState?
        private var snapPaths:[DrawingSnapPath] {importedSnapPaths+drawnSnapPaths}
        private var drawingIsActive = false
        private var drawingDistances: [DrawingDistance] = []
        private var drawingDistanceMode: DrawingDistanceMode = .slope
        private var previousDrawingFadeEnabled: Bool?
        private var registeringDrawingOcclusion = false
        private var drawingVersion: DrawingState?
        private var drawingPathCache: [UUID:(points:[SIMD3<Float>], entity:Entity, radius:Float, selected:Bool, pointsOnly:Bool)] = [:]
        private var previousDrawingWidth: Double?
        private var previousDrawingPointScale: Float?
        private var previousDrawingSelection: UUID?
        private lazy var drawingPointMesh = MeshResource.generateSphere(radius:0.035)
        private let drawingMaterial = UnlitMaterial(color:.systemOrange)

        @MainActor
        func updateTreeDisplay(model: AppModel, force: Bool = false) {
            guard let root=rootAnchor,let view=arView,let frame=view.session.currentFrame else {return}
            let now=ProcessInfo.processInfo.systemUptime
            guard force || now-lastTreeDisplayTime>=0.2 else {return}
            lastTreeDisplayTime=now
            if treeEntity.parent == nil {root.addChild(treeEntity)}
            let survey=model.treeSurvey
            let origin=model.origin,datum=model.drawingCaptureDatum
            let key="\(survey.recordsRevision):\(survey.frame?.id.uuidString ?? ""):\(origin?.latitude.description ?? "nil"):\(origin?.longitude.description ?? "nil"):\(datum?.description ?? "nil")"
            func visual(_ record:TreeRecord,preview:Bool)->TreeVisual? {
                guard let fixed=survey.frame,let position=try? TreeCoordinateBridge.display(record.geometry.circle.center,frame:fixed,origin:origin,datum:datum) else {return nil}
                let bounds=TreePreviewBounds.make(record.geometry,preview:preview)
                let lower=bounds.map {position.y+Float($0.lower-record.geometry.circle.center.up)}
                let upper=bounds.map {position.y+Float($0.upper-record.geometry.circle.center.up)}
                return TreeVisual(id:record.id,position:position,radius:Float(record.geometry.circle.radius),color:preview ? survey.color:record.color,number:preview ? survey.numberInput:String(record.number),bounds:bounds,lower:lower,upper:upper,preview:preview)
            }
            if key != treeProjectionKey {
                treeProjectionKey=key
                treeVisuals=survey.records.compactMap {visual($0,preview:false)}
                survey.reportDisplayUnavailable(survey.records.count-treeVisuals.count)
            }
            var visuals=treeVisuals
            let candidateID=survey.active ? survey.candidate?.id:nil
            if let candidate=survey.candidate,survey.active,let item=visual(candidate,preview:true) {
                visuals.removeAll {$0.id==candidate.id};visuals.append(item)
            }
            let camera=SIMD3(frame.camera.transform[3].x,frame.camera.transform[3].y,frame.camera.transform[3].z)
            let matrix=root.transformMatrix(relativeTo:nil)
            let localCamera=DiagramTransform.localPoint(camera,root:matrix)
            let distances=visuals.map {($0.id,TreeDisplayBudget.distance(camera:localCamera,center:$0.position,lower:$0.lower,upper:$0.upper))}
            let selected=TreeDisplayBudget.selected(distances,priority:candidateID)
            let visualByID=Dictionary(uniqueKeysWithValues:visuals.map {($0.id,$0)})
            var visible=selected.compactMap {visualByID[$0]}
            let ticks=TreeDisplayBudget.tickAllocation(visible.map {($0.id,$0.bounds?.metreTicks ?? [])})
            for i in visible.indices {visible[i].ticks=ticks[visible[i].id] ?? []}
            let ids=Set(visible.map(\.id))
            for id in Array(treeMeshes.keys) where !ids.contains(id) {
                treeMeshes[id]?.entity.removeFromParent();treeMeshes[id]=nil
            }
            for item in visible {
                if let old=treeMeshes[item.id],old.visual==item {continue}
                treeMeshes[item.id]?.entity.removeFromParent()
                let entity=Entity();treeEntity.addChild(entity)
                var labels:[TreeExtraLabel]=[]
                addTreeRing(position:item.position,radius:item.radius,provisional:false,color:item.color,into:entity)
                if let lower=item.lower,let upper=item.upper,let bounds=item.bounds,upper>lower,let mesh=treeBodyMesh {
                    var material=UnlitMaterial(color:item.color.uiColor)
                    material.blending = .transparent(opacity:.init(floatLiteral:bounds.provisional ? 0.12:0.22))
                    let body=ModelEntity(mesh:mesh,materials:[material]);body.position=SIMD3(item.position.x,(lower+upper)/2,item.position.z)
                    body.scale=SIMD3(item.radius,upper-lower,item.radius);entity.addChild(body)
                    addTreeRing(position:SIMD3(item.position.x,lower,item.position.z),radius:item.radius,provisional:bounds.lowerProvisional,color:item.color,into:entity)
                    addTreeRing(position:SIMD3(item.position.x,upper,item.position.z),radius:item.radius,provisional:bounds.upperProvisional,color:item.color,into:entity)
                    for metre in item.ticks {
                        let position=SIMD3(item.position.x,lower+Float(metre),item.position.z)
                        addTreeRing(position:position,radius:item.radius*1.04,provisional:bounds.upperProvisional,color:item.color,into:entity)
                        if item.preview,bounds.labelledMetres.contains(metre) {labels.append(TreeExtraLabel(id:UUID(),position:position+SIMD3(item.radius+0.07,0,0),text:"\(metre)m"))}
                    }
                    if item.preview {labels.insert(TreeExtraLabel(id:UUID(),position:SIMD3(item.position.x,upper,item.position.z),text:bounds.title),at:0)}
                }
                treeMeshes[item.id]=(entity,item,labels)
            }
            treeLabels=Array(visible.prefix(12))
            treeExtraLabels=visible.flatMap {treeMeshes[$0.id]?.labels ?? []}
            let directionKey=key+":\(survey.displayRevision)"
            if directionKey != treeDirectionsKey || treeDirectionsEntity.parent == nil {
                treeDirectionsKey=directionKey;treeDirectionsEntity.children.removeAll();treeDirectionLabels=[]
                if treeDirectionsEntity.parent == nil {treeEntity.addChild(treeDirectionsEntity)}
                if let fixed=survey.frame {
                    for (i,sight) in survey.directionSights.prefix(2).enumerated() {
                        guard let unit=sight.ray.unit else {continue}
                        let length=min(40,max(0.3,simd_length(sight.target.vector-sight.ray.origin.vector)))
                        let end=sight.ray.origin.vector+unit*length
                        guard let start=try? TreeCoordinateBridge.display(sight.ray.origin,frame:fixed,origin:origin,datum:datum),
                              let finish=try? TreeCoordinateBridge.display(TreePoint(east:end.x,north:end.y,up:end.z),frame:fixed,origin:origin,datum:datum) else {continue}
                        // Dashes and a flat cross identify a direction, never a measured sphere.
                        let delta=finish-start
                        for dash in 0..<16 {
                            let a=Float(dash)/16,b=(Float(dash)+0.55)/16
                            addTreeSightSegment(start+a*delta,start+b*delta,into:treeDirectionsEntity)
                        }
                        addTreeSightSegment(finish+SIMD3(-0.06,0,0),finish+SIMD3(0.06,0,0),into:treeDirectionsEntity)
                        addTreeSightSegment(finish+SIMD3(0,-0.06,0),finish+SIMD3(0,0.06,0),into:treeDirectionsEntity)
                        treeDirectionLabels.append(TreeExtraLabel(id:treeDirectionIDs[i],position:finish,text:sight.side.rawValue))
                    }
                }
            }
            let markers=survey.markers.compactMap {marker -> (id:UUID,position:SIMD3<Float>,number:Int)? in
                guard let fixed=survey.frame,let position=try? TreeCoordinateBridge.display(marker.point,frame:fixed,origin:origin,datum:datum) else {return nil}
                return (marker.id,position,marker.number)
            }
            let markerIDs=Set(markers.map(\.id))
            for id in Array(treeMarkers.keys) where !markerIDs.contains(id) {
                treeMarkers[id]?.entity.removeFromParent();treeMarkers[id]=nil
            }
            // Tree capture dots are one third of the ordinary point diameter; measurement geometry is unchanged.
            let pointScale=DrawingGeometry.pointScale(lineWidth:model.drawingLineWidth,referenceWidth:model.drawingPointReferenceWidth)*TreeCaptureStyle.scale
            for marker in markers {
                if let old=treeMarkers[marker.id],old.position==marker.position,old.scale==pointScale,old.entity.parent === treeEntity {continue}
                treeMarkers[marker.id]?.entity.removeFromParent()
                let dot=ModelEntity(mesh:drawingPointMesh,materials:[drawingMaterial])
                dot.position=marker.position;dot.scale=SIMD3(repeating:pointScale)
                treeEntity.addChild(dot)
                treeMarkers[marker.id]=(dot,marker.position,pointScale)
            }
            treeMarkerLabels=markers
            let rays=survey.active ? survey.rays : []
            if rays != lastTreeRays {
                lastTreeRays=rays;treeRayAnchor.children.removeAll()
                if !rays.isEmpty,treeRayAnchor.scene==nil {view.scene.addAnchor(treeRayAnchor)}
                for ray in rays.prefix(TreeDisplayBudget.maximumRays) {
                    addCylinder(from:ray.origin,to:ray.origin+ray.direction*10,radius:TreeCaptureStyle.observationRadius,material:UnlitMaterial(color:.systemPink),registerForOcclusion:false,into:treeRayAnchor)
                }
            }
        }

        private func makeTreeUnitMesh(ring:Bool)->MeshResource? {
            let data=TreeUnitMesh.make(ring:ring)
            var descriptor=MeshDescriptor()
            descriptor.positions=MeshBuffers.Positions(data.positions);descriptor.primitives = .triangles(data.indices)
            return try? MeshResource.generate(from:[descriptor])
        }
        private func addTreeRing(position:SIMD3<Float>,radius:Float,provisional:Bool,color:TreeColor,into parent:Entity) {
            guard let mesh=treeRingMesh else {return}
            var material=UnlitMaterial(color:provisional ? .systemCyan:color.uiColor)
            if provisional {material.blending = .transparent(opacity:.init(floatLiteral:0.5))}
            let ring=ModelEntity(mesh:mesh,materials:[material]);ring.position=position;ring.scale=SIMD3(repeating:radius);parent.addChild(ring)
        }
        private func addTreeSightSegment(_ start:SIMD3<Float>,_ end:SIMD3<Float>,into parent:Entity) {
            guard let mesh=treeBodyMesh else {return}
            let delta=end-start,length=simd_length(delta)
            guard length>0.0001,length.isFinite else {return}
            let entity=ModelEntity(mesh:mesh,materials:[UnlitMaterial(color:.systemCyan)])
            entity.position=(start+end)/2;entity.scale=SIMD3(TreeCaptureStyle.directionRadius,length,TreeCaptureStyle.directionRadius)
            entity.orientation=simd_quatf(from:SIMD3(0,1,0),to:delta/length);parent.addChild(entity)
        }

        @MainActor
        func updateDrawing(model: AppModel) {
            uiBridge.model = model
            if model.drawingSnapEnabled,model.drawing.active,!model.treeSurvey.active {
                let features=model.renderFeatures
                if snapImportRevision != model.drawingSnapGeometryRevision {
                    snapImportRevision=model.drawingSnapGeometryRevision
                    importedSnapPaths=features.map {feature in
                        let heights=feature.sourceAltitudes ?? []
                        let vertexHeights=(feature.pillarPositions == nil ? feature.sourceAltitudes:feature.pillarSourceAltitudes) ?? []
                        return DrawingSnapPath(points:feature.positions,vertices:feature.pillarPositions ?? feature.positions,heights:heights,vertexHeights:vertexHeights,segments:feature.kind != .point,closed:feature.kind == .polygon,source:.imported,heightSources:heights.map {_ in .sourceDrawing},vertexHeightSources:vertexHeights.map {_ in .sourceDrawing})
                    }
                }
                if snapDrawingVersion != model.drawing {
                    snapDrawingVersion=model.drawing
                    drawnSnapPaths=(model.drawing.completed+[model.drawing.draft]).filter {!$0.points.isEmpty}.map {path in
                        let heights=path.vertices?.map(\.elevation) ?? [],sources=path.vertices?.map(\.elevationSource) ?? []
                        return DrawingSnapPath(points:path.points,vertices:path.points,heights:heights,vertexHeights:heights,segments:!path.isPointCollection,source:path.id == model.drawing.draft.id ? .input:.saved,heightSources:sources,vertexHeightSources:sources)
                    }
                }
            }
            drawingIsActive = model.drawing.active
            if drawingDistanceMode != model.settings.drawingDistanceMode {
                drawingDistanceMode = model.settings.drawingDistanceMode
                updateProjectedLabels(force:true)
            }
            if model.drawingObservationResetID != drawingResetID || !drawingIsActive {
                drawingResetID = model.drawingObservationResetID
                clearObservation()
            }
            // render() may remove all root children; restore the independent drawing child.
            if drawingEntity.parent == nil { rootAnchor?.addChild(drawingEntity) }
            let selectedID=model.drawingSelectionMode ? model.selectedDrawingID : nil
            let pointScale=DrawingGeometry.pointScale(lineWidth:model.drawingLineWidth,referenceWidth:model.drawingPointReferenceWidth)
            let pointSizeChanged=previousDrawingPointScale != pointScale
            let fadeEnabled = requestedLiDAREnabled && lidarFadePreferenceEnabled
            let fadeChanged = previousDrawingFadeEnabled != fadeEnabled
            guard drawingVersion != model.drawing || previousDrawingWidth != model.drawingLineWidth || pointSizeChanged || previousDrawingSelection != selectedID || fadeChanged else { return }
            previousDrawingFadeEnabled = fadeEnabled
            registeringDrawingOcclusion = true
            defer {
                registeringDrawingOcclusion = false
                // Undo, delete and style changes detach geometry retained by the target list.
                // Remove those references before the next depth frame, then reindex all budgets.
                occlusionTargets.removeAll { target in
                    guard target.isDrawing else { return false }
                    var ancestor: Entity? = target.entity
                    while let node = ancestor {
                        if node === drawingEntity { return false }
                        ancestor = node.parent
                    }
                    return true
                }
                rebuildOcclusionIndices()
                let labelIDs = Set(currentLabels.map(\.id) + drawingDistances.map(\.id))
                labelOpacityByID = labelOpacityByID.filter { labelIDs.contains($0.key) }
                updateProjectedLabels(force:true)
            }
            previousDrawingPointScale=pointScale
            drawingVersion = model.drawing
            previousDrawingWidth=model.drawingLineWidth; previousDrawingSelection=selectedID
            let paths = (model.drawing.completed + [model.drawing.draft]).filter { !$0.points.isEmpty }
            let current = model.drawing.currentPaths
            let other = model.drawing.completed.filter { $0.resolvedLayerID != model.drawing.currentLayerID }
            drawingDistances = DrawingDistance.segments([model.drawing.draft]+Array(current.reversed())+Array(other.reversed()))
            let validIDs = Set(paths.map(\.id))
            for id in Array(drawingPathCache.keys) where !validIDs.contains(id) {
                drawingPathCache.removeValue(forKey:id)?.entity.removeFromParent()
            }
            func addPoint(_ point: SIMD3<Float>, material:UnlitMaterial, to entity:Entity) {
                let dot = ModelEntity(mesh:drawingPointMesh,materials:[material])
                dot.scale = SIMD3(repeating:pointScale)
                dot.position = point; entity.addChild(dot)
                if fadeEnabled {
                    registerOcclusionTarget(entity:dot,samplePositions:pointOcclusionSamples(center:point,radius:0.035*pointScale),kind:.point)
                }
            }
            func addLine(_ a:SIMD3<Float>, _ b:SIMD3<Float>, radius:Float, material:UnlitMaterial, to entity:Entity) {
                // A tiny segment still occupies one child so Undo can remove the last pair.
                let line = Entity()
                addCylinder(from:a,to:b,radius:radius,material:material,registerForOcclusion:fadeEnabled,into:line)
                entity.addChild(line)
            }
            for path in paths {
                let cached = drawingPathCache[path.id]
                let entity = cached?.entity ?? Entity()
                if entity.parent == nil { drawingEntity.addChild(entity) }
                let selected=path.id==selectedID
                let radius=Float(model.drawingLineWidth/2)*(selected ? 1.5 : 1)
                let material=selected ? UnlitMaterial(color:.systemYellow) : drawingMaterial
                let sameStyle = !fadeChanged && !pointSizeChanged && cached?.radius==radius && cached?.selected==selected && cached?.pointsOnly==path.isPointCollection
                let delta=sameStyle ? DrawingPathDelta.classify(old:cached?.points ?? [],new:path.points) : .rebuild
                switch delta {
                case .unchanged: break
                case .append:
                    if !path.isPointCollection, let last = cached?.points.last { addLine(last,path.points.last!,radius:radius,material:material,to:entity) }
                    addPoint(path.points.last!,material:material,to:entity)
                case .removeLast:
                    Array(entity.children).last?.removeFromParent()
                    if !path.isPointCollection, !path.points.isEmpty { Array(entity.children).last?.removeFromParent() }
                case .rebuild:
                    entity.children.removeAll()
                    for (index,point) in path.points.enumerated() {
                        if !path.isPointCollection, index > 0 { addLine(path.points[index-1],point,radius:radius,material:material,to:entity) }
                        addPoint(point,material:material,to:entity)
                    }
                }
                drawingPathCache[path.id] = (path.points,entity,radius,selected,path.isPointCollection)
            }
        }

        @MainActor
        private func clearObservation() {
            guard observationRay != nil || uiBridge.model?.drawingHasObservation == true else { return }
            observationRay = nil; observationAnchor.children.removeAll()
            // updateDrawing is also called inside SwiftUI.updateUIView. Publishing here
            // synchronously (even false -> false) creates a view-update feedback loop.
            Task { @MainActor [weak self] in
                guard let self, self.observationRay == nil,
                      let model = self.uiBridge.model, model.drawingHasObservation else { return }
                model.drawingHasObservation = false
                if model.drawingMessage.hasPrefix("視線") || model.drawingMessage.contains("横へ移動") { model.drawingMessage="視線取消・再観測" }
            }
        }

        @MainActor
        private func showObservation(_ ray: ObservationRay) {
            observationRay = ray
            if observationAnchor.scene == nil { arView?.scene.addAnchor(observationAnchor) }
            observationAnchor.children.removeAll()
            addCylinder(from:ray.origin,to:ray.origin+ray.direction*10,radius:0.008,material:UnlitMaterial(color:.systemPink),registerForOcclusion:false,into:observationAnchor)
            uiBridge.model?.drawingHasObservation = true
        }

        /// A tap can arrive before SwiftUI applies the last alignment gesture.
        /// Apply pending alignment once, then use this matrix for every capture
        /// path so the next updateUIView cannot move a newly captured world point.
        @MainActor
        func synchronizeDrawingTransform(model:AppModel) -> simd_float4x4? {
            guard let root=rootAnchor else { return nil }
            synchronizeDroggerContext(model:model)
            let height=Float(model.effectiveDisplayPlaneOffsetMeters)
            let heading=updateDisplayState(
                eastMeters:Float(model.planePanEastMeters),
                northMeters:Float(model.planePanNorthMeters),
                heightMeters:height,
                manualHeadingDegrees:model.headingOffsetDegrees,
                automaticHeadingDegrees:model.automaticHeadingCorrectionDegrees,
                headingInput:headingInput,
                interfaceOrientation:interfaceOrientation
            )
            let matrix=root.transformMatrix(relativeTo:nil)
            guard DiagramTransform.validRigid(matrix) else { return nil }
            recordRenderedTransform(model:model,heading:heading,height:Double(height))
            return matrix
        }

        @MainActor
        func synchronizeDroggerContext(model:AppModel) {
            model.drogger.synchronizeContext(origin:model.origin,revision:model.positionAlignmentRevision,epoch:droggerWorldEpoch)
            droggerOffset=model.drogger.worldOffset
        }

        @MainActor
        func recordRenderedTransform(model:AppModel,heading:Double,height:Double) {
            // Expose the complete root transform to centre-update and photo coordinates.
            // The correction itself remains session-local; it never edits stored vertices.
            let pan=DroggerFusion.renderedPan(east:model.planePanEastMeters,north:model.planePanNorthMeters,heading:heading,offset:droggerOffset)
            model.updateRenderedTransform(panEastMeters:pan.x,panNorthMeters:pan.y,rootHeightMeters:height,totalHeadingDegrees:heading)
        }

        @MainActor
        private func updateDrogger(using frame:ARFrame,normal:Bool) {
            guard isSessionActive, let model=uiBridge.model, model.drogger.needsARUpdates, let root=rootAnchor else { return }
            // Apply a pending gesture before storing a timed pose, just as tap capture does.
            guard synchronizeDrawingTransform(model:model) != nil else { return }
            var base=root.transformMatrix(relativeTo:nil)
            base.columns.3 -= SIMD4(droggerOffset,0)
            droggerOffset=model.drogger.recordFrame(time:frame.timestamp,camera:frame.camera.transform,baseRoot:base,origin:model.origin,revision:model.positionAlignmentRevision,epoch:droggerWorldEpoch,normal:normal)
            applyRootTransform()
            recordRenderedTransform(model:model,heading:manualHeadingDegrees+displayedAutomaticHeadingCorrectionDegrees,height:Double(displayHeightMeters))
        }

        @MainActor
        func consumeTreeCaptureRequest() {
            guard let survey=uiBridge.model?.treeSurvey,survey.capturePending,survey.captureRequestID != lastTreeCaptureRequest else {return}
            let id=survey.captureRequestID;lastTreeCaptureRequest=id
            DispatchQueue.main.async { [weak self] in
                guard let self,let survey=self.uiBridge.model?.treeSurvey,survey.capturePending,survey.captureRequestID==id else {return}
                defer {survey.finishCenterCapture(id)}
                guard let view=self.arView else {survey.reportCaptureUnavailable("AR画面の準備待ち");return}
                self.handleDrawingInput(at:CGPoint(x:view.bounds.midX,y:view.bounds.midY))
            }
        }
        @MainActor
        func consumeDrawingCaptureRequest() {
            guard let model=uiBridge.model,model.drawingCapturePending,model.drawingCaptureRequestID != lastDrawingCaptureRequest else {return}
            let id=model.drawingCaptureRequestID;lastDrawingCaptureRequest=id
            DispatchQueue.main.async { [weak self] in
                guard let self,let model=self.uiBridge.model,model.drawingCapturePending,model.drawingCaptureRequestID==id else {return}
                defer {model.finishDrawingCapture(id)}
                guard let view=self.arView else {model.drawingMessage="AR画面の準備待ち";return}
                self.handleDrawingInput(at:CGPoint(x:view.bounds.midX,y:view.bounds.midY))
            }
        }
        @MainActor
        @objc func handleDrawingTap(_ recognizer: UIGestureRecognizer) {
            // Touch selection remains available, but geometry sampling is centre-confirm only.
            guard let model=uiBridge.model,model.drawingSelectionMode,!model.drawing.active,!model.treeSurvey.active,let view=arView else {return}
            handleDrawingInput(at:recognizer.location(in:view))
        }
        @MainActor
        private func handleDrawingInput(at tap:CGPoint) {
            guard let model = uiBridge.model, model.drawing.active || model.drawingSelectionMode || model.treeSurvey.active else { return }
            func rejected(_ message:String) {
                model.drawingMessage=message
                if model.treeSurvey.active {model.treeSurvey.reportCaptureUnavailable(message)}
            }
            guard model.canEditWork else { rejected("復元待ち"); return }
            guard let view=arView, let frame=view.session.currentFrame,
                  isSessionActive, hasReceivedActiveFrame else { rejected("AR準備待ち・再タップ"); return }
            guard case .normal = frame.camera.trackingState,
                  ProcessInfo.processInfo.systemUptime-frame.timestamp < 0.5 else {
                rejected("AR追跡待ち・周囲も映してください"); return
            }
            if let orientation=view.window?.windowScene?.interfaceOrientation,orientation != .unknown {interfaceOrientation=orientation}
            guard view.bounds.width > 0, view.bounds.height > 0 else { rejected("画面準備待ち"); return }
            guard let rootMatrix=synchronizeDrawingTransform(model:model) else { rejected("表示の更新待ち・再タップ");return }
            let cameraFromWorld=simd_inverse(frame.camera.transform)
            func projection()->(CGPoint,SIMD2<Float>,ObservationRay)? {
                guard let image=DrawingProjection.imagePoint(viewPoint:tap,viewport:view.bounds.size,imageToView:frame.displayTransform(for:interfaceOrientation,viewportSize:view.bounds.size)),
                      let pixel=DrawingProjection.pixel(imagePoint:image,resolution:frame.camera.imageResolution),
                      let ray=DrawingProjection.ray(pixel:pixel,intrinsics:frame.camera.intrinsics,camera:frame.camera.transform,epoch:observationEpoch) else {return nil}
                return (image,pixel,ray)
            }
            if model.treeSurvey.active {
                guard let (image,pixel,ray)=projection() else {rejected("照準の画像座標を確認");return}
                var world:SIMD3<Float>?,failure:DrawingDepthFailure?
                if model.treeSurvey.needsSurfaceDistance && model.lidarEnabled && model.lidarSupported && measurementDepthEnabled {
                    switch reliableDepthPoint(frame:frame,imagePoint:image,pixel:pixel) {
                    case .success(let point):world=point
                    case .failure(let reason):failure=reason
                    }
                }
                let reference=TreeCaptureReference(root:rootMatrix,origin:model.origin,datum:model.drawingCaptureDatum,alignmentRevision:model.positionAlignmentRevision,epoch:observationEpoch)
                model.treeSurvey.accept(ray:ray,depth:world,current:reference)
                if let failure,model.treeSurvey.needsSurfaceDistance,!model.treeSurvey.rays.isEmpty {model.treeSurvey.reportCaptureUnavailable(failure.message+"・同じ樹皮を横移動して再確定")}
                updateTreeDisplay(model:model,force:true);updateProjectedLabels(force:true)
                return
            }
            if model.drawingSelectionMode {
                let id=DrawingSelection.hit(paths:model.drawing.currentPaths,tap:SIMD2(Float(tap.x),Float(tap.y))) { point in
                    let world=DrawingGeometry.point(point,transformedBy:rootMatrix)
                    guard DrawingGeometry.point(world,transformedBy:cameraFromWorld).z < -0.05,
                          let screen=view.project(world) else { return nil }
                    return SIMD2(Float(screen.x),Float(screen.y))
                }
                model.selectDrawing(id)
                return
            }
            if snapAllowed(model), let picked=pickDrawingPoint(tap,rootMatrix:rootMatrix,cameraFromWorld:cameraFromWorld,projectWorld:{ view.project($0) }) {
                model.addDrawingPoint(picked.point,sourceAltitude:picked.altitude,altitudeSource:picked.elevationSource ?? .arEstimate); model.drawingMessage="吸着・"+picked.title+"を追加"
                return
            }
            guard let (imagePoint,pixel,ray)=projection() else {rejected("照準の画像座標を確認");return}
            let enabled=model.lidarEnabled && model.lidarSupported && measurementDepthEnabled
            var depthFailure:DrawingDepthFailure?
            let outcome=DrawingCapture.resolve(first:observationRay,next:ray,useDepth:enabled) {
                switch self.reliableDepthPoint(frame:frame,imagePoint:imagePoint,pixel:pixel) {
                case .success(let point):return point
                case .failure(let reason):depthFailure=reason;return nil
                }
            }
            let depthReason=depthFailure?.message ?? (!model.lidarEnabled ? "LiDARオフ":(!model.lidarSupported ? "LiDAR非対応":"深度準備待ち"))
            switch outcome {
            case .rejected(let reason):
                if reason == .epoch { clearObservation() }
                rejected(reason.message+"・"+depthReason)
            case .point(let world,let depth):
                model.addDrawingPoint(DiagramTransform.localPoint(world,root:rootMatrix))
                clearObservation(); model.drawingMessage=depth ? String(format:"点追加・LiDAR %.2fm",Double(simd_length(world-ray.origin))) : "点追加・2視点"
            case .hold:
                showObservation(ray); model.drawingMessage="視線1/2・横移動（"+depthReason+"）"
            }
        }

        @MainActor
        private func snapAllowed(_ model:AppModel)->Bool {
            DrawingSnap.allowed(enabled:model.drawingSnapEnabled,active:model.drawing.active,selecting:model.drawingSelectionMode,treeActive:model.treeSurvey.active,hasObservation:observationRay != nil || model.drawingHasObservation)
        }
        func pickDrawingPoint(_ tap:CGPoint,rootMatrix:simd_float4x4,cameraFromWorld:simd_float4x4,projectWorld:(SIMD3<Float>)->CGPoint?)->DrawingSnapHit? {
            DrawingSnap.pick(tap,paths:snapPaths,root:rootMatrix,cameraFromWorld:cameraFromWorld,project:projectWorld)
        }

        private func reliableDepthPoint(frame:ARFrame,imagePoint:CGPoint,pixel:SIMD2<Float>)->Result<SIMD3<Float>,DrawingDepthFailure> {
            guard let depth=frame.sceneDepth else {return .failure(.noDepth)}
            return DrawingDepth.sample(map:depth.depthMap,confidence:depth.confidenceMap,imagePoint:imagePoint,pixel:pixel,intrinsics:frame.camera.intrinsics).flatMap {sample in
                let world=DrawingGeometry.point(sample.cameraPoint,transformedBy:frame.camera.transform)
                guard world.x.isFinite,world.y.isFinite,world.z.isFinite else {return .failure(.calibration)}
                return .success(world)
            }
        }

        private var fallbackToGravityUsed = false
        private var currentAlignment: ARConfiguration.WorldAlignment = .gravityAndHeading
        private var lastRenderSignature: Int = 0
        private var textureCache: [UUID: TextureResource] = [:]
        private var requestedLiDAREnabled = false
        private var measurementDepthEnabled = false
        private var lastAppliedLiDAREnabled: Bool?
        private var isSessionActive = false
        private var hasReceivedActiveFrame = false
        private var currentLabels: [RenderLabel] = []
        private var currentShowDistance = false
        private var lastProjectionTime: CFTimeInterval = 0
        private var lastProjectedLabels: [ScreenLabel] = []
        private var interfaceOrientation: UIInterfaceOrientation = .portrait

        // SwiftUI側からコピーされた表示値。ARSessionDelegateからAppModelへは触れない。
        private var displayEastMeters: Float = 0
        private var displayNorthMeters: Float = 0
        private var displayHeightMeters: Float = -1
        private var manualHeadingDegrees: Double = 0
        private var headingInput = HeadingStabilizationInput(enabled: false, updatesActive: false, compassHeadingDegrees: nil, compassAccuracyDegrees: -1)

        // 実際のroot描画には、AppModelへ反映済みの値だけを使用する。
        // センサー計算中の値と描画値を分け、「中心を更新」が別フレームの角度を
        // 参照してしまう競合を防ぐ。
        private var displayedAutomaticHeadingCorrectionDegrees: Double = 0
        private var stabilizationAutomaticHeadingCorrectionDegrees: Double = 0
        private var hasInitializedStabilizationCorrection = false
        private var headingAlignmentBiasDegrees: Double?
        private var lastCompassHeadingDegrees: Double?
        private var lastARHeadingDegrees: Double?
        private var lastHeadingUpdateTime: CFTimeInterval = 0
        private var lastHorizontalBasisUpdateTime: CFTimeInterval = 0

        private enum OcclusionTargetKind: Equatable {
            case point
            case linearGeometry
            case raster
        }

        private struct OcclusionTarget {
            var entity: ModelEntity
            /// Entity全体を1点だけで判定すると、長い線や大きい点が一括で明滅する。
            /// Entity内を代表する複数のローカル座標を持ち、奥側になった割合から
            /// Entityの不透明度を連続的に決める。
            var samplePositions: [SIMD3<Float>]
            var kind: OcclusionTargetKind
            var isDrawing: Bool
            var currentOpacity: Float = 1
        }

        private var occlusionTargets: [OcclusionTarget] = []
        private var linearOcclusionTargetIndices: [Int] = []
        private var pointOcclusionTargetIndices: [Int] = []
        private var rasterOcclusionTargetIndices: [Int] = []
        private var linearOcclusionCursor = 0
        private var pointOcclusionCursor = 0
        private var labelOpacityByID: [UUID: Double] = [:]
        private var labelOcclusionCursor = 0
        private var lidarFadePreferenceEnabled = true
        private var lidarFadeEffectiveActive = false
        private var lidarBehindOpacity: Float = 0.50
        private var lastDepthUpdateTime: CFTimeInterval = 0
        private var depthWasAvailable = false

        private var lastHandledPhotoCaptureRequestID = 0
        private var photoCaptureInProgress = false
        private var activePhotoCaptureRequestID: Int?
        private var photoSnapshotStarted = false
        private var photoCaptureWatchdog: DispatchWorkItem?
        private var photoContext:PhotoCoordinateContext?
        private var photoMode:PhotoCaptureMode = .arOverlay
        private var photoSource:PhotoPositionSource = .ar
        private var photoDeviceLocation:DeviceLocationObservation?
        private var photoDeviceHeading:DeviceHeadingObservation?
        private var photoSessionID=UUID()
        private var photoAlignmentRevisionAtReset=0
        @MainActor func updatePhotoContext(model:AppModel,location:LocationManager) {
            photoContext=model.photoCoordinateContext
            photoMode=model.activePhotoMode
            photoSource=model.activePhotoPositionSource
            photoDeviceLocation=location.photoLocation
            photoDeviceHeading=location.photoHeading
        }

        private struct LineSegment {
            var start: SIMD3<Float>
            var end: SIMD3<Float>
            var width: Float
        }

        private struct SegmentSpatialKey: Hashable {
            var x: Int
            var y: Int
            var z: Int
        }

        private let pointMaterial: UnlitMaterial = {
            var material = UnlitMaterial()
            material.color = .init(tint: .systemYellow)
            return material
        }()

        private let lineMaterial: UnlitMaterial = {
            var material = UnlitMaterial()
            material.color = .init(tint: .systemCyan)
            return material
        }()

        private let pillarMaterial: UnlitMaterial = {
            var material = UnlitMaterial()
            material.color = .init(tint: .white.withAlphaComponent(0.65))
            return material
        }()

        @discardableResult
        fileprivate func updateDisplayState(
            eastMeters: Float,
            northMeters: Float,
            heightMeters: Float,
            manualHeadingDegrees: Double,
            automaticHeadingDegrees: Double,
            headingInput: HeadingStabilizationInput,
            interfaceOrientation: UIInterfaceOrientation
        ) -> Double {
            displayEastMeters = eastMeters
            displayNorthMeters = northMeters
            displayHeightMeters = heightMeters
            self.manualHeadingDegrees = manualHeadingDegrees
            displayedAutomaticHeadingCorrectionDegrees = automaticHeadingDegrees
            if !hasInitializedStabilizationCorrection {
                stabilizationAutomaticHeadingCorrectionDegrees = automaticHeadingDegrees
                hasInitializedStabilizationCorrection = true
            }
            self.interfaceOrientation = interfaceOrientation

            if self.headingInput.enabled != headingInput.enabled || self.headingInput.updatesActive != headingInput.updatesActive {
                resetHeadingStabilization(clearCorrection: !headingInput.enabled || !headingInput.updatesActive)
            }
            self.headingInput = headingInput
            applyRootTransform()
            return manualHeadingDegrees + displayedAutomaticHeadingCorrectionDegrees
        }

        private func applyRootTransform() {
            guard let root = rootAnchor else { return }
            let totalHeading = manualHeadingDegrees + displayedAutomaticHeadingCorrectionDegrees
            let angle = Float(totalHeading * .pi / 180)
            let cosA = cos(angle)
            let sinA = sin(angle)

            // displayEast/Northは利用者が原点から移動した地理座標上の量。
            // 地物は利用者の移動と反対へ動くため、rootの方位回転を掛けた移動量を
            // 符号反転して平行移動する。中心更新後は新原点から再計算した地物座標と
            // この変換が一致するため、確定時に表示が飛ばない。
            let rotatedPlayerEast = displayEastMeters * cosA - displayNorthMeters * sinA
            let rotatedPlayerNorth = displayEastMeters * sinA + displayNorthMeters * cosA
            root.position = SIMD3<Float>(
                -rotatedPlayerEast,
                displayHeightMeters,
                rotatedPlayerNorth
            ) + droggerOffset
            root.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }

        func setLiDARFadePreference(enabled: Bool, behindOpacity: Float) {
            let clamped = max(0.05, min(behindOpacity, 0.85))
            lidarFadePreferenceEnabled = enabled
            lidarBehindOpacity = clamped
            let nextEffective = enabled && requestedLiDAREnabled
            if lidarFadeEffectiveActive && !nextEffective {
                resetOcclusionOpacity()
            }
            lidarFadeEffectiveActive = nextEffective
        }

        func setSessionActive(_ active: Bool, on arView: ARView) {
            if active {
                guard !isSessionActive else { return }
                isSessionActive = true
                startSession(on: arView)
            } else {
                guard isSessionActive else { return }
                MainActor.assumeIsolated {scanCapture?.stop(reason:"ARセッション中断");scanCapture?.invalidatePreview()}
                Task { @MainActor in self.clearObservation(); self.uiBridge.model?.reportDrawingSnap(nil); self.uiBridge.model?.drogger.suspendAR(); self.uiBridge.model?.treeSurvey.invalidateObservations("ARが停止しました") }
                observationEpoch += 1
                arView.session.pause()
                isSessionActive = false
                hasReceivedActiveFrame = false
                headingInput.updatesActive = false
                lastProjectedLabels = []
                resetHeadingStabilization(clearCorrection: true)
                resetOcclusionOpacity()
                Task { @MainActor [uiBridge] in
                    uiBridge.updateLabels([])
                }
                setARStatus("AR停止中：読込・設定画面")
            }
        }

        func startSession(on arView: ARView) {
            guard ARWorldTrackingConfiguration.isSupported else {
                setARStatus("ARWorldTracking非対応端末です")
                return
            }

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                // 一度方位センサー失敗でgravityへ退避した場合は、その基準を画面復帰後も維持する。
                runARSession(on: arView, alignment: currentAlignment, resetTracking: true)
            case .notDetermined:
                setARStatus("カメラ許可待ち")
                AVCaptureDevice.requestAccess(for: .video) { [weak self, weak arView] granted in
                    DispatchQueue.main.async {
                        guard let self, let arView else { return }
                        if granted {
                            // 権限ダイアログ中に別画面／バックグラウンドへ移った場合は、
                            // 停止要求を上書きしてセッションを再開しない。
                            guard self.isSessionActive else { return }
                            self.runARSession(on: arView, alignment: self.currentAlignment, resetTracking: true)
                        } else {
                            self.setARStatus("カメラが許可されていません")
                        }
                    }
                }
            case .denied, .restricted:
                setARStatus("カメラが許可されていません。設定アプリで許可してください。")
            @unknown default:
                setARStatus("カメラ許可状態を確認できません")
            }
        }

        func setLiDARPreference(_ enabled: Bool, measurementEnabled: Bool, on arView: ARView) {
            let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            let effectiveEnabled = enabled && supported
            Task { @MainActor [uiBridge] in
                uiBridge.updateLiDARSupport(supported, disableRequestedSetting: enabled && !supported)
            }

            requestedLiDAREnabled = effectiveEnabled
            measurementDepthEnabled = measurementEnabled && effectiveEnabled
            let depthEnabled = effectiveEnabled || measurementDepthEnabled
            if !effectiveEnabled {
                if lidarFadeEffectiveActive {
                    resetOcclusionOpacity()
                }
                lidarFadeEffectiveActive = false
            }

            guard isSessionActive else { return }
            guard lastAppliedLiDAREnabled != depthEnabled else { return }
            lastAppliedLiDAREnabled = depthEnabled
            Task { @MainActor [uiBridge] in uiBridge.model?.reportLiDARDepth(false) }
            if enabled && !supported {
                setARStatus("LiDAR非対応端末です")
            }
            runARSession(on: arView, alignment: currentAlignment, resetTracking: false)
        }

        func setScanCaptureEnabled(_ enabled:Bool,on arView:ARView) {
            let active=ScanFeatureAvailability.isEnabled && enabled && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            guard active != scanReconstructionEnabled else {return}
            scanReconstructionEnabled=active
            if isSessionActive {runARSession(on:arView,alignment:currentAlignment,resetTracking:false)}
        }

        private func runARSession(on arView: ARView, alignment: ARConfiguration.WorldAlignment, resetTracking: Bool) {
            if resetTracking { photoSessionID=UUID();photoAlignmentRevisionAtReset=photoContext?.alignmentRevision ?? 0 }
            if resetTracking {MainActor.assumeIsolated {scanInput?.sessionReset(photoSessionID)}}
            if resetTracking { observationEpoch += 1; droggerWorldEpoch += 1; droggerOffset = .zero }
            Task { @MainActor in
                if resetTracking { self.clearObservation() }
                if resetTracking, let model = self.uiBridge.model,
                   !model.drawing.completed.isEmpty || !model.drawing.draft.points.isEmpty {
                    model.workNeedsRealignment = true
                }
            }
            currentAlignment = alignment
            arView.environment.background = .cameraFeed(exposureCompensation: 0.45)
            arView.isOpaque = false
            arView.backgroundColor = .clear

            let config = ARWorldTrackingConfiguration()
            config.worldAlignment = alignment
            config.planeDetection = []
            config.isLightEstimationEnabled = true

            if requestedLiDAREnabled || measurementDepthEnabled {
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth)
                }
                // 今回の前後判定はsceneDepthを直接使う。再構成メッシュは参照しないため、
                // 有効化せずLiDAR処理の余分な負荷を避ける。
            }

            if scanReconstructionEnabled {
                config.sceneReconstruction = .mesh
                config.frameSemantics.insert(.sceneDepth)
            }
            let options: ARSession.RunOptions = resetTracking ? [.resetTracking, .removeExistingAnchors] : []
            arView.session.run(config, options: options)
            isSessionActive = true
            hasReceivedActiveFrame = false
            if resetTracking { resetHeadingStabilization(clearCorrection: true) }

            let lidarText = requestedLiDAREnabled ? " / LiDAR補助" : ""
            switch alignment {
            case .gravityAndHeading:
                setARStatus("AR起動中：方位あり\(lidarText)")
            case .gravity:
                setARStatus("AR起動中：方位なし\(lidarText)")
            case .camera:
                setARStatus("AR起動中：カメラ基準\(lidarText)")
            @unknown default:
                setARStatus("AR起動中\(lidarText)")
            }
        }

        func render(features: [RenderFeature], rasters: [RenderRaster], labels: [RenderLabel], selectedPosition: SIMD3<Float>?, style: RenderStyle, showPillars: Bool, showDistance: Bool, into root: AnchorEntity) {
            currentLabels = labels
            currentShowDistance = showDistance
            let useDepthFadeGeometry = requestedLiDAREnabled && lidarFadePreferenceEnabled
            let validLabelIDs = Set(labels.map(\.id) + drawingDistances.map(\.id))
            labelOpacityByID = labelOpacityByID.filter { validLabelIDs.contains($0.key) }
            updateProjectedLabels(force: true)

            let activeRasterIDs = Set(rasters.map(\.id))
            textureCache = textureCache.filter { activeRasterIDs.contains($0.key) }
            let signature = renderSignature(features: features, rasters: rasters, labels: labels, selectedPosition: selectedPosition, style: style, showPillars: showPillars)
            guard signature != lastRenderSignature else { return }
            lastRenderSignature = signature

            root.children.removeAll()
            // Re-register cached drawing geometry when imported geometry rebuilds the target list.
            previousDrawingFadeEnabled = nil
            occlusionTargets.removeAll(keepingCapacity: true)
            linearOcclusionTargetIndices.removeAll(keepingCapacity: true)
            pointOcclusionTargetIndices.removeAll(keepingCapacity: true)
            rasterOcclusionTargetIndices.removeAll(keepingCapacity: true)
            linearOcclusionCursor = 0
            pointOcclusionCursor = 0
            guard !features.isEmpty || !rasters.isEmpty || selectedPosition != nil else { return }

            // GeoTIFFは先に置く。点・線はその上に描画する。
            for raster in rasters {
                addRaster(
                    raster,
                    opacity: style.rasterOpacity,
                    registerForOcclusion: useDepthFadeGeometry,
                    to: root
                )
            }

            // 大量線分を1本ずつEntity化すると、RealityKit側のEntity数が増えて重くなる。
            // 線・柱は一度配列に集め、少数の結合メッシュとして追加する。
            var lineSegments: [LineSegment] = []
            var coloredSegments: [SourceColor?: [LineSegment]] = [:]
            var pillarSegments: [LineSegment] = []

            for feature in features {
                lineSegments.removeAll(keepingCapacity: true)
                switch feature.kind {
                case .point:
                    for position in feature.positions {
                        addPoint(
                            position,
                            radius: effectivePointRadius(at: position, style: style),
                            sourceColor: feature.sourceColor,
                            showPillar: false,
                            registerForOcclusion: useDepthFadeGeometry,
                            to: root
                        )
                        if showPillars {
                            appendPillar(at: position, to: &pillarSegments)
                        }
                    }
                case .line:
                    appendBoundaryLine(feature.positions, pillarPositions: feature.pillarPositions, closed: false, style: style, showPillars: showPillars, lineSegments: &lineSegments, pillarSegments: &pillarSegments)
                case .polygon:
                    appendBoundaryLine(feature.positions, pillarPositions: feature.pillarPositions, closed: true, style: style, showPillars: showPillars, lineSegments: &lineSegments, pillarSegments: &pillarSegments)
                }
                let color = feature.sourceColor
                if !lineSegments.isEmpty { coloredSegments[color, default: []].append(contentsOf: lineSegments) }
            }

            for (color, segments) in coloredSegments {
                var material = lineMaterial
                if let color {
                    material.color = .init(tint: color.uiColor.withAlphaComponent(1))
                    if color.alpha < 1 { material.blending = .transparent(opacity: .init(floatLiteral: Float(color.alpha))) }
                }
                addSegmentMesh(segments, material: material, registerForOcclusion: useDepthFadeGeometry,
                               preferredOcclusionPieceLength: 0.30, into: root)
            }
            addSegmentMesh(
                pillarSegments,
                material: pillarMaterial,
                registerForOcclusion: useDepthFadeGeometry,
                preferredOcclusionPieceLength: 0.25,
                into: root
            )

            if let selectedPosition {
                let selectedRadius = style.effectivePointRadius(
                    distance: horizontalDistance(selectedPosition),
                    baseRadius: style.selectedPointRadius
                )
                addSelectedPoint(
                    selectedPosition,
                    radius: selectedRadius,
                    registerForOcclusion: useDepthFadeGeometry,
                    to: root
                )
            }
        }

        private func renderSignature(features: [RenderFeature], rasters: [RenderRaster], labels: [RenderLabel], selectedPosition: SIMD3<Float>?, style: RenderStyle, showPillars: Bool) -> Int {
            // 大量SIMA/KMLで毎回長大なStringを組み立てると、AR表示更新時のCPU負荷が出る。
            // Hashベースの軽量署名にして、標高ON時も不要な再生成を避ける。
            var hasher = Hasher()
            hasher.combine(showPillars)
            hasher.combine(requestedLiDAREnabled && lidarFadePreferenceEnabled)
            hasher.combine(labels.count)
            hasher.combine(Int((style.pointRadius * 10000).rounded()))
            hasher.combine(Int((style.selectedPointRadius * 10000).rounded()))
            hasher.combine(Int((style.lineRadius * 10000).rounded()))
            hasher.combine(style.farMinimumSizeEnabled)
            hasher.combine(Int((style.farPointMinRadius * 10000).rounded()))
            hasher.combine(Int((style.farLineMinRadius * 10000).rounded()))
            hasher.combine(Int((style.rasterOpacity * 1000).rounded()))

            if let selectedPosition {
                hasher.combine("SEL")
                hashPosition(selectedPosition, scale: 100, into: &hasher)
            }

            for raster in rasters {
                hasher.combine(raster.id)
                hasher.combine(raster.image.size.width)
                hasher.combine(raster.image.size.height)
                hasher.combine(raster.positions.count)
                if let first = raster.positions.first { hashPosition(first, scale: 10, into: &hasher) }
                if let last = raster.positions.last { hashPosition(last, scale: 10, into: &hasher) }
            }

            for label in labels {
                hasher.combine(label.text)
                hashPosition(label.position, scale: 10, into: &hasher)
                hasher.combine(Int(label.screenYOffset.rounded()))
            }

            for feature in features {
                hasher.combine(feature.id)
                hasher.combine(feature.kind.rawValue)
                hasher.combine(feature.sourceColor)
                hasher.combine(feature.positions.count)
                for position in feature.positions {
                    hashPosition(position, scale: 100, into: &hasher)
                }
                hasher.combine(feature.pillarPositions?.count ?? -1)
                for position in feature.pillarPositions ?? [] {
                    hashPosition(position, scale: 100, into: &hasher)
                }
            }

            return hasher.finalize()
        }

        private func hashPosition(_ position: SIMD3<Float>, scale: Float, into hasher: inout Hasher) {
            hasher.combine(Int((position.x * scale).rounded()))
            hasher.combine(Int((position.y * scale).rounded()))
            hasher.combine(Int((position.z * scale).rounded()))
        }

        private func addRaster(
            _ raster: RenderRaster,
            opacity: Float,
            registerForOcclusion: Bool,
            to root: Entity
        ) {
            guard raster.positions.count == 4, let cgImage = raster.image.cgImage else { return }

            let topLeft = raster.positions[0]
            let topRight = raster.positions[1]
            let bottomLeft = raster.positions[3]
            let width = simd_length(topRight - topLeft)
            let depth = simd_length(bottomLeft - topLeft)
            guard width > 0.05, depth > 0.05 else { return }


            let texture: TextureResource
            if let cached = textureCache[raster.id], cached.width == cgImage.width, cached.height == cgImage.height {
                texture = cached
            } else if let generated = try? TextureResource(image: cgImage, options: .init(semantic: .color)) {
                textureCache[raster.id] = generated
                texture = generated
            } else {
                return
            }

            let clampedOpacity = max(0, min(1, opacity))

            var material = UnlitMaterial()
            material.color = .init(
                tint: .white.withAlphaComponent(CGFloat(clampedOpacity)),
                texture: .init(texture)
            )
            // RealityKit の UnlitMaterial は、透明・半透明面では alpha 付き tint だけでは
            // 不透明描画のままになることがある。GeoTIFF全体を確実に半透明にするため、
            // blending を明示する。
            let realityOpacity = PhysicallyBasedMaterial.Opacity(floatLiteral: clampedOpacity)
            material.blending = .transparent(opacity: realityOpacity)

            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffers.Positions(raster.positions.map { $0 + SIMD3<Float>(0,-0.02,0) })
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([SIMD2<Float>(0,0), SIMD2<Float>(1,0), SIMD2<Float>(1,1), SIMD2<Float>(0,1)])
            descriptor.primitives = .triangles([0,2,1,0,3,2])
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }
            let plane = ModelEntity(mesh: mesh, materials: [material])
            root.addChild(plane)
            if registerForOcclusion {
                registerOcclusionTarget(
                    entity: plane,
                    samplePositions: rasterOcclusionSamples(corners: raster.positions),
                    kind: .raster
                )
            }
        }

        private func addPoint(
            _ position: SIMD3<Float>,
            radius: Float,
            sourceColor: SourceColor? = nil,
            showPillar: Bool,
            registerForOcclusion: Bool,
            to root: Entity
        ) {
            // 点は薄い板状だと真横から見えにくくなるため、球体表示に戻す。
            // 点数は表示制限で絞られるため、負荷の主因になりやすい線分より影響は小さい。
            var material = pointMaterial
            if let color = sourceColor {
                material.color = .init(tint: color.uiColor.withAlphaComponent(1))
                if color.alpha < 1 { material.blending = .transparent(opacity: .init(floatLiteral: Float(color.alpha))) }
            }
            let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
            sphere.position = position
            root.addChild(sphere)
            if registerForOcclusion {
                registerOcclusionTarget(
                    entity: sphere,
                    samplePositions: pointOcclusionSamples(center: position, radius: radius),
                    kind: .point
                )
            }

            if showPillar {
                addPillar(at: position, registerForOcclusion: registerForOcclusion, to: root)
            }
        }

        private func addSelectedPoint(
            _ position: SIMD3<Float>,
            radius: Float,
            registerForOcclusion: Bool,
            to root: Entity
        ) {
            var material = UnlitMaterial()
            material.color = .init(tint: .systemRed)
            let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
            sphere.position = position + SIMD3<Float>(0, 0.05, 0)
            root.addChild(sphere)
            let selectedCenter = position + SIMD3<Float>(0, 0.05, 0)
            if registerForOcclusion {
                registerOcclusionTarget(
                    entity: sphere,
                    samplePositions: pointOcclusionSamples(center: selectedCenter, radius: radius),
                    kind: .point
                )
            }

            var pillarMaterial = UnlitMaterial()
            pillarMaterial.color = .init(tint: .systemRed.withAlphaComponent(0.75))
            addCylinder(
                from: position + SIMD3<Float>(0, -1.4, 0),
                to: position + SIMD3<Float>(0, 1.4, 0),
                radius: max(radius * 0.18, 0.025),
                material: pillarMaterial,
                registerForOcclusion: registerForOcclusion,
                into: root
            )
        }

        private func appendBoundaryLine(_ positions: [SIMD3<Float>], pillarPositions: [SIMD3<Float>]?, closed: Bool, style: RenderStyle, showPillars: Bool, lineSegments: inout [LineSegment], pillarSegments: inout [LineSegment]) {
            guard !positions.isEmpty else { return }

            if showPillars {
                for position in pillarPositions ?? positions {
                    appendPillar(at: position, to: &pillarSegments)
                }
            }

            guard positions.count >= 2 else { return }

            for index in 0..<(positions.count - 1) {
                let radius = effectiveLineRadius(from: positions[index], to: positions[index + 1], style: style)
                appendSegment(from: positions[index], to: positions[index + 1], radius: radius, to: &lineSegments)
            }

            if closed, positions.count >= 3, let first = positions.first, let last = positions.last, distance(first, last) > 0.01 {
                let radius = effectiveLineRadius(from: last, to: first, style: style)
                appendSegment(from: last, to: first, radius: radius, to: &lineSegments)
            }
        }


        private func effectivePointRadius(at position: SIMD3<Float>, style: RenderStyle) -> Float {
            style.effectivePointRadius(distance: horizontalDistance(position))
        }

        private func effectiveLineRadius(from start: SIMD3<Float>, to end: SIMD3<Float>, style: RenderStyle) -> Float {
            let mid = (start + end) / 2
            return style.effectiveLineRadius(distance: horizontalDistance(mid))
        }

        private func appendPillar(at position: SIMD3<Float>, to segments: inout [LineSegment]) {
            let bottom = position + SIMD3<Float>(0, -5, 0)
            let top = position + SIMD3<Float>(0, 5, 0)
            appendSegment(from: bottom, to: top, radius: 0.035, to: &segments)
        }

        private func addPillar(
            at position: SIMD3<Float>,
            registerForOcclusion: Bool,
            to root: Entity
        ) {
            var segments: [LineSegment] = []
            appendPillar(at: position, to: &segments)
            addSegmentMesh(
                segments,
                material: pillarMaterial,
                registerForOcclusion: registerForOcclusion,
                preferredOcclusionPieceLength: 0.25,
                into: root
            )
        }

        private func addCylinder(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            radius: Float,
            material: UnlitMaterial,
            registerForOcclusion: Bool,
            into root: Entity
        ) {
            var segments: [LineSegment] = []
            appendSegment(from: start, to: end, radius: radius, to: &segments)
            addSegmentMesh(
                segments,
                material: material,
                registerForOcclusion: registerForOcclusion,
                preferredOcclusionPieceLength: 0.20,
                into: root
            )
        }

        private func appendSegment(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, to segments: inout [LineSegment]) {
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.001 else { return }
            let safeWidth = max(radius * 2.0, 0.003)
            segments.append(LineSegment(start: start, end: end, width: safeWidth))
        }

        private func addSegmentMesh(
            _ segments: [LineSegment],
            material: UnlitMaterial,
            registerForOcclusion: Bool,
            preferredOcclusionPieceLength: Float = 0.30,
            into root: Entity
        ) {
            guard !segments.isEmpty else { return }

            if registerForOcclusion {
                // 線全体を1つのEntityへ結合すると、代表点が手や樹木の後ろに入っただけで
                // 全線が一括して薄くなる。長い線を適度に分割してから空間セルへまとめ、
                // 描画Entity数を抑えつつ局所的に不透明度を変えられるようにする。
                let chunks = makeSpatialOcclusionChunks(
                    from: segments,
                    preferredPieceLength: preferredOcclusionPieceLength
                )
                for chunk in chunks {
                    addSegmentMeshChunk(
                        chunk,
                        material: material,
                        registerForOcclusion: true,
                        into: root
                    )
                }
            } else {
                // 1メッシュが大きくなりすぎると環境差が出るため、適度な単位に分割する。
                let chunkSize = 1500
                var startIndex = 0
                while startIndex < segments.count {
                    let endIndex = min(startIndex + chunkSize, segments.count)
                    addSegmentMeshChunk(
                        Array(segments[startIndex..<endIndex]),
                        material: material,
                        registerForOcclusion: false,
                        into: root
                    )
                    startIndex = endIndex
                }
            }
        }

        private func makeSpatialOcclusionChunks(
            from source: [LineSegment],
            preferredPieceLength: Float
        ) -> [[LineSegment]] {
            guard !source.isEmpty else { return [] }

            // 大量データでも細分化後がおおむね3,000本を超えないよう、データ量に応じて
            // 分割長を自動的に広げる。小規模データでは30cm前後の細粒度を維持する。
            let totalLength = source.reduce(Float.zero) { partial, segment in
                partial + simd_length(segment.end - segment.start)
            }
            let preferred = max(preferredPieceLength, 0.25)
            let adaptivePieceLength = max(preferred, totalLength / 3000.0)
            let pieces = subdivideSegments(source, maximumLength: adaptivePieceLength)

            // 通常時は小さい空間セルを使い、Entity数が多くなりすぎる場合だけセルを広げる。
            // これにより大量KML/SIMAでも従来の結合メッシュの軽さを大きく損なわない。
            let maximumSpatialChunks = 180
            if pieces.count <= maximumSpatialChunks {
                // 小規模データは30cm前後の分割片をそのまま個別判定する。
                // 手や細い柱が線の途中へ重なったとき、隣接部分まで一括で薄くしない。
                return pieces.map { [$0] }
            }

            var cellSize = max(0.35, adaptivePieceLength * 1.35)
            var grouped: [SegmentSpatialKey: [LineSegment]] = [:]

            // 表示半径の上限（10km）まで確実に収束できる回数を確保する。
            for _ in 0..<24 {
                grouped = groupSegments(pieces, cellSize: cellSize)
                if grouped.count <= maximumSpatialChunks { break }
                cellSize *= 1.45
            }

            let orderedKeys = grouped.keys.sorted {
                if $0.x != $1.x { return $0.x < $1.x }
                if $0.y != $1.y { return $0.y < $1.y }
                return $0.z < $1.z
            }

            var chunks: [[LineSegment]] = []
            chunks.reserveCapacity(grouped.count)
            let maximumSegmentsPerMesh = 1200

            for key in orderedKeys {
                guard let cellSegments = grouped[key], !cellSegments.isEmpty else { continue }
                var startIndex = 0
                while startIndex < cellSegments.count {
                    let endIndex = min(startIndex + maximumSegmentsPerMesh, cellSegments.count)
                    chunks.append(Array(cellSegments[startIndex..<endIndex]))
                    startIndex = endIndex
                }
            }
            return chunks
        }

        private func subdivideSegments(_ source: [LineSegment], maximumLength: Float) -> [LineSegment] {
            let safeMaximumLength = max(maximumLength, 0.25)
            var result: [LineSegment] = []
            result.reserveCapacity(source.count)

            for segment in source {
                let delta = segment.end - segment.start
                let length = simd_length(delta)
                guard length > 0.001 else { continue }
                let pieceCount = max(1, Int((length / safeMaximumLength).rounded(.up)))
                if pieceCount == 1 {
                    result.append(segment)
                    continue
                }

                for index in 0..<pieceCount {
                    let t0 = Float(index) / Float(pieceCount)
                    let t1 = Float(index + 1) / Float(pieceCount)
                    result.append(
                        LineSegment(
                            start: segment.start + delta * t0,
                            end: segment.start + delta * t1,
                            width: segment.width
                        )
                    )
                }
            }
            return result
        }

        private func groupSegments(_ segments: [LineSegment], cellSize: Float) -> [SegmentSpatialKey: [LineSegment]] {
            let safeCellSize = max(cellSize, 0.25)
            var grouped: [SegmentSpatialKey: [LineSegment]] = [:]
            grouped.reserveCapacity(min(segments.count, 180))

            for segment in segments {
                let midpoint = (segment.start + segment.end) / 2
                let key = SegmentSpatialKey(
                    x: Int((midpoint.x / safeCellSize).rounded(.down)),
                    y: Int((midpoint.y / safeCellSize).rounded(.down)),
                    z: Int((midpoint.z / safeCellSize).rounded(.down))
                )
                grouped[key, default: []].append(segment)
            }
            return grouped
        }

        private func addSegmentMeshChunk(_ segments: [LineSegment], material: UnlitMaterial, registerForOcclusion: Bool, into root: Entity) {
            var positions: [SIMD3<Float>] = []
            var indices: [UInt32] = []
            positions.reserveCapacity(segments.count * 8)
            indices.reserveCapacity(segments.count * 36)

            for segment in segments {
                appendBoxSegment(segment, positions: &positions, indices: &indices)
            }

            guard !positions.isEmpty, !indices.isEmpty else { return }

            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.primitives = .triangles(indices)

            if let mesh = try? MeshResource.generate(from: [descriptor]) {
                let entity = ModelEntity(mesh: mesh, materials: [material])
                root.addChild(entity)
                if registerForOcclusion {
                    registerOcclusionTarget(
                        entity: entity,
                        samplePositions: segmentOcclusionSamples(segments),
                        kind: .linearGeometry
                    )
                }
            }
        }

        private func appendBoxSegment(_ segment: LineSegment, positions: inout [SIMD3<Float>], indices: inout [UInt32]) {
            let start = segment.start
            let end = segment.end
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.001 else { return }

            let xAxis = simd_normalize(delta)
            var zAxis = simd_cross(SIMD3<Float>(0, 1, 0), xAxis)
            if simd_length(zAxis) < 0.0001 {
                zAxis = SIMD3<Float>(1, 0, 0)
            } else {
                zAxis = simd_normalize(zAxis)
            }
            let yAxis = simd_normalize(simd_cross(zAxis, xAxis))

            let center = (start + end) / 2
            let hx = xAxis * (length / 2)
            let hy = yAxis * (segment.width / 2)
            let hz = zAxis * (segment.width / 2)

            let p0 = center - hx - hy - hz
            let p1 = center + hx - hy - hz
            let p2 = center + hx + hy - hz
            let p3 = center - hx + hy - hz
            let p4 = center - hx - hy + hz
            let p5 = center + hx - hy + hz
            let p6 = center + hx + hy + hz
            let p7 = center - hx + hy + hz

            let base = UInt32(positions.count)
            positions.append(p0)
            positions.append(p1)
            positions.append(p2)
            positions.append(p3)
            positions.append(p4)
            positions.append(p5)
            positions.append(p6)
            positions.append(p7)

            indices.append(base + 0); indices.append(base + 1); indices.append(base + 2)
            indices.append(base + 0); indices.append(base + 2); indices.append(base + 3)
            indices.append(base + 4); indices.append(base + 6); indices.append(base + 5)
            indices.append(base + 4); indices.append(base + 7); indices.append(base + 6)
            indices.append(base + 0); indices.append(base + 4); indices.append(base + 5)
            indices.append(base + 0); indices.append(base + 5); indices.append(base + 1)
            indices.append(base + 3); indices.append(base + 2); indices.append(base + 6)
            indices.append(base + 3); indices.append(base + 6); indices.append(base + 7)
            indices.append(base + 0); indices.append(base + 3); indices.append(base + 7)
            indices.append(base + 0); indices.append(base + 7); indices.append(base + 4)
            indices.append(base + 1); indices.append(base + 5); indices.append(base + 6)
            indices.append(base + 1); indices.append(base + 6); indices.append(base + 2)
        }

        private func horizontalDistance(_ position: SIMD3<Float>) -> Float {
            simd_length(SIMD2<Float>(position.x, position.z))
        }

        private func pointOcclusionSamples(center: SIMD3<Float>, radius: Float) -> [SIMD3<Float>] {
            let offset = max(radius * 0.72, 0.01)
            return [
                center,
                center + SIMD3<Float>(offset, 0, 0),
                center - SIMD3<Float>(offset, 0, 0),
                center + SIMD3<Float>(0, offset, 0),
                center - SIMD3<Float>(0, offset, 0),
                center + SIMD3<Float>(0, 0, offset),
                center - SIMD3<Float>(0, 0, offset)
            ]
        }

        private func rasterOcclusionSamples(corners: [SIMD3<Float>]) -> [SIMD3<Float>] {
            guard corners.count == 4 else { return corners }
            let topLeft = corners[0]
            let topRight = corners[1]
            let bottomRight = corners[2]
            let bottomLeft = corners[3]
            var samples: [SIMD3<Float>] = []
            samples.reserveCapacity(9)

            for row in 0...2 {
                let v = Float(row) / 2.0
                for column in 0...2 {
                    let u = Float(column) / 2.0
                    let top = topLeft + (topRight - topLeft) * u
                    let bottom = bottomLeft + (bottomRight - bottomLeft) * u
                    samples.append(top + (bottom - top) * v)
                }
            }
            return samples
        }

        private func segmentOcclusionSamples(_ segments: [LineSegment]) -> [SIMD3<Float>] {
            guard !segments.isEmpty else { return [] }
            // Sample the actual line, not the centroid between separate lines or shared
            // endpoints. Those may lie behind a surface while the visible piece is in front.
            // Length-spaced interior samples retain the existing maximum of nine probes.
            let lengths = segments.map { simd_length($0.end - $0.start) }
            let totalLength = lengths.reduce(0, +)
            guard totalLength.isFinite, totalLength > 0.001 else { return [] }
            let sampleCount = min(9, segments.count + 2)
            var samples: [SIMD3<Float>] = []
            samples.reserveCapacity(sampleCount)
            var segmentIndex = 0
            var segmentStartDistance: Float = 0
            for index in 0..<sampleCount {
                let distance = totalLength * (Float(index) + 0.5) / Float(sampleCount)
                while segmentIndex < segments.count - 1,
                      distance > segmentStartDistance + lengths[segmentIndex] {
                    segmentStartDistance += lengths[segmentIndex]
                    segmentIndex += 1
                }
                let segment = segments[segmentIndex]
                let fraction = max(0, min(1, (distance - segmentStartDistance) / max(lengths[segmentIndex], 0.001)))
                let candidate = segment.start + (segment.end - segment.start) * fraction
                if !samples.contains(where: { simd_length($0 - candidate) < 0.01 }) {
                    samples.append(candidate)
                }
            }
            return samples
        }

        private func registerOcclusionTarget(
            entity: ModelEntity,
            samplePositions: [SIMD3<Float>],
            kind: OcclusionTargetKind
        ) {
            guard !samplePositions.isEmpty else { return }
            let index = occlusionTargets.count
            occlusionTargets.append(
                OcclusionTarget(
                    entity: entity,
                    samplePositions: samplePositions,
                    kind: kind,
                    isDrawing: registeringDrawingOcclusion,
                    currentOpacity: 1
                )
            )
            switch kind {
            case .linearGeometry:
                linearOcclusionTargetIndices.append(index)
            case .point:
                pointOcclusionTargetIndices.append(index)
            case .raster:
                rasterOcclusionTargetIndices.append(index)
            }
        }

        private func rebuildOcclusionIndices() {
            linearOcclusionTargetIndices = occlusionTargets.indices.filter { occlusionTargets[$0].kind == .linearGeometry }
            pointOcclusionTargetIndices = occlusionTargets.indices.filter { occlusionTargets[$0].kind == .point }
            rasterOcclusionTargetIndices = occlusionTargets.indices.filter { occlusionTargets[$0].kind == .raster }
        }

        private func resetOcclusionOpacity() {
            depthWasAvailable = false
            for index in occlusionTargets.indices {
                occlusionTargets[index].currentOpacity = 1
                occlusionTargets[index].entity.components.set(OpacityComponent(opacity: 1))
            }
            labelOpacityByID.removeAll(keepingCapacity: true)
            updateProjectedLabels(force: true)
        }

        private func updateLiDAROcclusion(using frame: ARFrame) {
            guard requestedLiDAREnabled, lidarFadePreferenceEnabled else { return }

            let now = CACurrentMediaTime()
            // 毎秒5回まで。複数点判定にしても毎フレーム全要素は走査しない。
            guard now - lastDepthUpdateTime >= 0.20 else { return }
            lastDepthUpdateTime = now

            guard case .normal = frame.camera.trackingState,
                  let depthData = frame.sceneDepth,
                  depthData.confidenceMap != nil,
                  let arView,
                  let root = rootAnchor,
                  arView.bounds.width > 1,
                  arView.bounds.height > 1 else {
                if depthWasAvailable {
                    resetOcclusionOpacity()
                    depthWasAvailable = false
                }
                return
            }
            depthWasAvailable = true

            let depthMap = depthData.depthMap
            let confidenceMap = depthData.confidenceMap
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            }
            defer {
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                if let confidenceMap {
                    CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
                }
            }

            guard let depthBase = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self) else {
                resetOcclusionOpacity(); return
            }
            let depthWidth = CVPixelBufferGetWidth(depthMap)
            let depthHeight = CVPixelBufferGetHeight(depthMap)
            let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

            let confidenceBase = confidenceMap.flatMap {
                CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self)
            }
            let confidenceWidth = confidenceMap.map { CVPixelBufferGetWidth($0) } ?? 0
            let confidenceHeight = confidenceMap.map { CVPixelBufferGetHeight($0) } ?? 0
            let confidenceStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
            guard depthWidth > 0, depthHeight > 0, confidenceBase != nil,
                  confidenceWidth > 0, confidenceHeight > 0 else { resetOcclusionOpacity(); return }

            let viewportSize = arView.bounds.size
            let viewToImage = frame.displayTransform(for: interfaceOrientation, viewportSize: viewportSize).inverted()

            func sampledDepth(at viewPoint: CGPoint) -> Float? {
                let viewNormalized = CGPoint(
                    x: viewPoint.x / viewportSize.width,
                    y: viewPoint.y / viewportSize.height
                )
                let imageNormalized = viewNormalized.applying(viewToImage)
                guard imageNormalized.x >= 0, imageNormalized.x <= 1,
                      imageNormalized.y >= 0, imageNormalized.y <= 1 else { return nil }

                let centerX = min(depthWidth - 1, max(0, Int(imageNormalized.x * CGFloat(depthWidth - 1))))
                let centerY = min(depthHeight - 1, max(0, Int(imageNormalized.y * CGFloat(depthHeight - 1))))
                let offsets = [(0, 0), (-2, 0), (2, 0), (0, -2), (0, 2)]
                var samples: [(depth:Float,confidence:UInt8?)] = []
                samples.reserveCapacity(offsets.count)

                for (dx, dy) in offsets {
                    let x = min(depthWidth - 1, max(0, centerX + dx))
                    let y = min(depthHeight - 1, max(0, centerY + dy))

                    var confidence: UInt8?
                    if let confidenceBase, confidenceWidth > 0, confidenceHeight > 0 {
                        let cx = min(confidenceWidth - 1, max(0, x * confidenceWidth / max(depthWidth, 1)))
                        let cy = min(confidenceHeight - 1, max(0, y * confidenceHeight / max(depthHeight, 1)))
                        confidence = confidenceBase[cy * confidenceStride + cx]
                    }

                    let value = depthBase[y * depthStride + x]
                    samples.append((value,confidence))
                }

                return LiDARFade.sampledDepth(samples)
            }

            let cameraFromWorld = simd_inverse(frame.camera.transform)

            func behindWeight(at worldPosition: SIMD3<Float>) -> Float? {
                guard let point = arView.project(worldPosition),
                      let realDepth = sampledDepth(at: point) else { return nil }

                // sceneDepthはカメラ座標系の奥行きとして扱うため、ユークリッド距離ではなく
                // 仮想要素も同じカメラZへ変換して比較する。特に画面端の誤判定を抑えられる。
                let cameraPosition = cameraFromWorld * SIMD4<Float>(
                    worldPosition.x,
                    worldPosition.y,
                    worldPosition.z,
                    1
                )
                return LiDARFade.behindWeight(cameraPosition:SIMD3(cameraPosition.x,cameraPosition.y,cameraPosition.z),realDepth:realDepth,trackingNormal:true)
            }

            let linearBatch = Self.circularBatch(
                indices: linearOcclusionTargetIndices,
                cursor: linearOcclusionCursor,
                maximumCount: 72
            )
            linearOcclusionCursor = linearBatch.nextCursor

            let pointBatch = Self.circularBatch(
                indices: pointOcclusionTargetIndices,
                cursor: pointOcclusionCursor,
                maximumCount: 96
            )
            pointOcclusionCursor = pointBatch.nextCursor

            // GeoTIFFは現仕様上1枚までなので毎回判定する。線を優先枠、点を別枠にし、
            // 点が多いデータでも線・柱の更新が後回しにならないようにする。
            let targetIndices = rasterOcclusionTargetIndices + linearBatch.indices + pointBatch.indices
            for index in targetIndices {
                let samples = occlusionTargets[index].samplePositions
                var accumulatedBehindWeight: Float = 0
                var strongestBehindWeight: Float = 0
                var validSampleCount = 0

                for localPosition in samples {
                    let worldPosition = root.convert(position: localPosition, to: nil)
                    if let weight = behindWeight(at: worldPosition) {
                        accumulatedBehindWeight += weight
                        strongestBehindWeight = max(strongestBehindWeight, weight)
                        validSampleCount += 1
                    }
                }

                let desiredOpacity: Float
                if validSampleCount > 0 {
                    let averageCoverage = accumulatedBehindWeight / Float(validSampleCount)
                    let behindCoverage: Float
                    switch occlusionTargets[index].kind {
                    case .point:
                        // 球体は分割描画しないため、どこか1点で確実に奥と分かれば全体を薄くする。
                        behindCoverage = strongestBehindWeight
                    case .linearGeometry:
                        // Fade by the covered fraction; one hidden or valid depth sample
                        // must not force the visible/unknown portion of a chunk to fade.
                        behindCoverage = LiDARFade.linearCoverage(
                            accumulatedWeight: accumulatedBehindWeight, sampleCount: samples.count
                        )
                    case .raster:
                        behindCoverage = averageCoverage
                    }
                    desiredOpacity = 1 - behindCoverage * (1 - lidarBehindOpacity)
                } else {
                    // 深度を取得できない場合は通常表示。
                    desiredOpacity = 1
                }

                let current = occlusionTargets[index].currentOpacity
                let smoothed = current + (desiredOpacity - current) * 0.46
                occlusionTargets[index].currentOpacity = smoothed
                occlusionTargets[index].entity.components.set(OpacityComponent(opacity: smoothed))
            }

            // 画面内ラベルを優先し、画面外の大量ラベルで更新枠を消費しない。
            // 画面内候補が取れない初期状態だけ全候補を巡回する。
            let projectedLabelIDs = Set(lastProjectedLabels.map(\.id))
            let visibleLabelIndices = currentLabels.indices.filter {
                projectedLabelIDs.contains(currentLabels[$0].id)
            }
            let labelCandidateIndices = visibleLabelIndices.isEmpty
                ? Array(currentLabels.indices)
                : visibleLabelIndices
            let labelBatch = Self.circularBatch(
                indices: labelCandidateIndices,
                cursor: labelOcclusionCursor,
                maximumCount: 32
            )
            labelOcclusionCursor = labelBatch.nextCursor

            if !labelBatch.indices.isEmpty {
                for index in labelBatch.indices {
                    let label = currentLabels[index]
                    let worldPosition = root.convert(position: label.position, to: nil)
                    let desiredOpacity: Double

                    if let weight = behindWeight(at: worldPosition) {
                        desiredOpacity = Double(1 - weight * (1 - lidarBehindOpacity))
                    } else {
                        desiredOpacity = 1
                    }

                    let current = labelOpacityByID[label.id] ?? 1
                    labelOpacityByID[label.id] = current + (desiredOpacity - current) * 0.46
                }
                updateProjectedLabels(force: true)
            }
            // Distances belong to drawn lines and follow the same depth policy.
            for distance in drawingDistances where projectedLabelIDs.contains(distance.id) {
                let world = root.convert(position:distance.midpoint,to:nil)
                let desired = behindWeight(at:world).map { Double(1-$0*(1-lidarBehindOpacity)) } ?? 1
                let current = labelOpacityByID[distance.id] ?? 1
                labelOpacityByID[distance.id] = current + (desired-current)*0.46
            }
            updateProjectedLabels(force:true)
        }

        private static func circularBatch(
            indices: [Int],
            cursor: Int,
            maximumCount: Int
        ) -> (indices: [Int], nextCursor: Int) {
            guard !indices.isEmpty, maximumCount > 0 else { return ([], 0) }
            let normalizedCursor = ((cursor % indices.count) + indices.count) % indices.count
            let count = min(maximumCount, indices.count)
            var batch: [Int] = []
            batch.reserveCapacity(count)
            for offset in 0..<count {
                batch.append(indices[(normalizedCursor + offset) % indices.count])
            }
            return (batch, (normalizedCursor + count) % indices.count)
        }

        private func updateHorizontalScreenBasis(using frame: ARFrame) {
            let now = CACurrentMediaTime()
            // 画面操作には十分滑らかで、MainActorへの不要な更新を増やさない20Hz上限。
            guard now - lastHorizontalBasisUpdateTime >= 0.05 else { return }
            lastHorizontalBasisUpdateTime = now

            let orientation = interfaceOrientation == .unknown ? .portrait : interfaceOrientation
            let cameraToWorld = simd_inverse(frame.camera.viewMatrix(for: orientation))
            let forwardWorld = -SIMD3<Float>(
                cameraToWorld.columns.2.x,
                cameraToWorld.columns.2.y,
                cameraToWorld.columns.2.z
            )
            let rightWorld = SIMD3<Float>(
                cameraToWorld.columns.0.x,
                cameraToWorld.columns.0.y,
                cameraToWorld.columns.0.z
            )

            // ARワールドは x=東、-z=北として扱う。カメラが真上／真下に近く、
            // 正面方向を水平面へ安定して投影できない場合は直前の基底を維持する。
            var forward = SIMD2<Double>(Double(forwardWorld.x), Double(-forwardWorld.z))
            let forwardLength = simd_length(forward)
            guard forwardLength.isFinite, forwardLength > 0.08 else { return }
            forward /= forwardLength

            var right = SIMD2<Double>(forward.y, -forward.x)
            let projectedRight = SIMD2<Double>(Double(rightWorld.x), Double(-rightWorld.z))
            if simd_length_squared(projectedRight) > 0.0001,
               simd_dot(right, projectedRight) < 0 {
                right = -right
            }

            let basis = HorizontalScreenBasis(
                rightEast: right.x,
                rightNorth: right.y,
                forwardEast: forward.x,
                forwardNorth: forward.y
            )
            Task { @MainActor [uiBridge] in
                uiBridge.updateHorizontalScreenBasis(basis)
            }
        }

        private func updateHeadingStabilization(using frame: ARFrame) {
            let now = CACurrentMediaTime()
            guard now - lastHeadingUpdateTime >= 0.10 else { return }
            lastHeadingUpdateTime = now

            guard headingInput.enabled,
                  headingInput.updatesActive,
                  let compass = headingInput.compassHeadingDegrees,
                  headingInput.compassAccuracyDegrees >= 0,
                  headingInput.compassAccuracyDegrees <= 35 else {
                return
            }

            let arHeading = Self.normalizedDegrees(-Double(frame.camera.eulerAngles.y) * 180 / .pi)
            guard let bias = headingAlignmentBiasDegrees,
                  let previousCompass = lastCompassHeadingDegrees,
                  let previousAR = lastARHeadingDegrees else {
                headingAlignmentBiasDegrees = Self.angularDifference(from: arHeading, to: compass)
                lastCompassHeadingDegrees = compass
                lastARHeadingDegrees = arHeading
                return
            }

            let compassStep = Self.angularDifference(from: previousCompass, to: compass)
            let arStep = Self.angularDifference(from: previousAR, to: arHeading)
            let expectedARHeading = Self.normalizedDegrees(arHeading + bias)
            let driftError = Self.angularDifference(from: expectedARHeading, to: compass)

            // コンパスがほぼ静止しているのにAR方位だけが動いた場合を主対象にする。
            let immediateMismatch = abs(compassStep) < 1.2 && abs(arStep) > 1.8
            let accumulatedMismatch = abs(compassStep) < 2.5 && abs(driftError) > 3.0
            if immediateMismatch || accumulatedMismatch {
                let target = max(-35.0, min(35.0, driftError))
                let delta = Self.angularDifference(from: stabilizationAutomaticHeadingCorrectionDegrees, to: target)
                stabilizationAutomaticHeadingCorrectionDegrees = Self.normalizedDegrees(
                    stabilizationAutomaticHeadingCorrectionDegrees + delta * 0.08
                )

                // rootをここで先に回さない。AppModelへ値が反映された次の
                // updateDisplayStateで、中心更新の計算値と同時に描画へ適用する。
                let displayValue = stabilizationAutomaticHeadingCorrectionDegrees
                Task { @MainActor [uiBridge] in
                    uiBridge.updateHeadingCorrection(displayValue)
                }
            }

            lastCompassHeadingDegrees = compass
            lastARHeadingDegrees = arHeading
        }

        private func resetHeadingStabilization(clearCorrection: Bool) {
            headingAlignmentBiasDegrees = nil
            lastCompassHeadingDegrees = nil
            lastARHeadingDegrees = nil
            if clearCorrection, stabilizationAutomaticHeadingCorrectionDegrees != 0 {
                stabilizationAutomaticHeadingCorrectionDegrees = 0
                Task { @MainActor [uiBridge] in
                    uiBridge.updateHeadingCorrection(0)
                }
            }
        }

        private static func normalizedDegrees(_ degrees: Double) -> Double {
            var value = degrees.truncatingRemainder(dividingBy: 360)
            if value > 180 { value -= 360 }
            if value <= -180 { value += 360 }
            return value
        }

        private static func angularDifference(from start: Double, to end: Double) -> Double {
            normalizedDegrees(end - start)
        }

        func capturePhotoIfRequested(_ requestID: Int, from arView: ARView) {
            guard requestID > 0 else { return }

            // 写真権限ダイアログ中にscenePhaseがinactiveになるとARSessionは一度停止する。
            // 同じ要求が復帰後に渡された場合は、新規要求にせず有効フレーム待ちを再開する。
            if activePhotoCaptureRequestID == requestID, photoCaptureInProgress {
                guard !photoSnapshotStarted else { return }
                switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
                case .authorized, .limited:
                    beginPhotoSnapshotIfReady(requestID: requestID, from: arView)
                case .denied, .restricted:
                    completePhotoCapture(
                        requestID: requestID,
                        success: false,
                        message: "写真への追加が許可されていません。iOSの設定で写真の追加を許可してください"
                    )
                case .notDetermined:
                    break
                @unknown default:
                    break
                }
                return
            }

            guard requestID != lastHandledPhotoCaptureRequestID,
                  !photoCaptureInProgress else { return }

            lastHandledPhotoCaptureRequestID = requestID
            photoCaptureInProgress = true
            activePhotoCaptureRequestID = requestID
            photoSnapshotStarted = false
            schedulePhotoCaptureWatchdog(
                for: requestID,
                after: 60,
                message: "写真撮影の準備が時間内に完了しませんでした。もう一度お試しください"
            )

            switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
            case .authorized, .limited:
                beginPhotoSnapshotIfReady(requestID: requestID, from: arView)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self, weak arView] status in
                    DispatchQueue.main.async {
                        guard let self,
                              let arView,
                              self.activePhotoCaptureRequestID == requestID else { return }
                        if status == .authorized || status == .limited {
                            // OS権限画面から戻った直後はARSessionがまだ停止／再初期化中のことがある。
                            // その場合はここでは待ち、updateUIViewまたは最初のARフレームで再試行する。
                            self.beginPhotoSnapshotIfReady(requestID: requestID, from: arView)
                        } else {
                            self.completePhotoCapture(
                                requestID: requestID,
                                success: false,
                                message: "写真への追加が許可されていません。iOSの設定で写真の追加を許可してください"
                            )
                        }
                    }
                }
            case .denied, .restricted:
                completePhotoCapture(
                    requestID: requestID,
                    success: false,
                    message: "写真への追加が許可されていません。iOSの設定で写真の追加を許可してください"
                )
            @unknown default:
                completePhotoCapture(
                    requestID: requestID,
                    success: false,
                    message: "写真の追加権限を確認できませんでした"
                )
            }
        }

        private func beginPhotoSnapshotIfReady(requestID: Int, from arView: ARView) {
            guard isSessionActive,
                  hasReceivedActiveFrame,
                  arView.window?.windowScene?.activationState == .foregroundActive,
                  arView.session.currentFrame != nil else { return }
            beginPhotoSnapshot(requestID: requestID, from: arView)
        }

        private func beginPhotoSnapshot(requestID: Int, from arView: ARView) {
            guard activePhotoCaptureRequestID == requestID,
                  photoCaptureInProgress,
                  !photoSnapshotStarted else { return }
            guard let frame=arView.session.currentFrame,let root=rootAnchor,let context=photoContext else { return }
            photoSnapshotStarted = true
            notifyPhotoCaptureStarted(requestID)
            schedulePhotoCaptureWatchdog(
                for: requestID,
                after: 12,
                message: "AR写真の作成が時間内に完了しませんでした。もう一度お試しください"
            )
            let labels = lastProjectedLabels
            let viewSize = arView.bounds.size
            let rootMatrix=root.transformMatrix(relativeTo:nil)
            let orientation=interfaceOrientation == .unknown ? .portrait : interfaceOrientation
            let pose=PhotoGeometry.pose(camera:frame.camera.transform,root:rootMatrix,context:context)
            let display=frame.displayTransform(for:orientation,viewportSize:viewSize)
            let fresh=ProcessInfo.processInfo.systemUptime-frame.timestamp
            let normal:Bool
            if case .normal=frame.camera.trackingState { normal=true } else { normal=false }
            var issues:[String]=[]
            if !normal { issues.append("tracking_not_normal") }
            if fresh<0 || fresh>0.5 { issues.append("frame_not_fresh") }
            if context.alignmentRevision<=photoAlignmentRevisionAtReset { issues.append("alignment_not_adjusted_since_AR_reset") }
            if context.settings.datum == .unknown { issues.append("geodetic_datum_unknown") }
            if context.origin == nil { issues.append("diagram_origin_unknown") }
            if pose == nil { issues.append("invalid_transform") }
            let epoch=observationEpoch
            let capturedAt=Date().addingTimeInterval(-max(0,min(1,fresh)))
            var record=PhotoCaptureRecord(id:UUID(),mode:photoMode,capturedAt:capturedAt,frameTimestamp:frame.timestamp,followingFrameTimestamp:nil,sessionID:photoSessionID,tracking:String(describing:frame.camera.trackingState),synchronization:photoMode == .cameraOnly ? "same_ARFrame_image_and_pose" : "asynchronous_snapshot_bracket",georeferenceUsable:issues.isEmpty,issues:issues,context:context,pose:pose,rootToARWorld:DiagramTransform.values(rootMatrix),rawCameraToARWorld:DiagramTransform.values(frame.camera.transform),followingRawCameraToARWorld:nil,rawImageWidth:Int(frame.camera.imageResolution.width),rawImageHeight:Int(frame.camera.imageResolution.height),intrinsicsColumnMajor:(0..<3).flatMap { column in (0..<3).map { Double(frame.camera.intrinsics[column][$0]) } },interfaceOrientation:String(orientation.rawValue),displayTransform:[Double(display.a),Double(display.b),Double(display.c),Double(display.d),Double(display.tx),Double(display.ty)])
            let rotation=PhotoGeometry.imageRotation(a:Double(display.a),b:Double(display.b))
            record.rawToOutputExifRotation=rotation
            record.positionSource=photoSource
            record.arPoseUsable=normal && fresh>=0 && fresh<=0.5 && pose != nil
            record.arGeoreferenceUsable=record.arPoseUsable && issues.isEmpty
            // Keep raw sensor observations even when they are stale or unselected.
            let deviceDirection=normal && fresh>=0 && fresh<=0.5 ? PhotoGeometry.deviceCameraDirection(heading:photoDeviceHeading,portraitCamera:simd_inverse(frame.camera.viewMatrix(for:.portrait)),date:capturedAt) : nil
            record.deviceObservation=DevicePhotoObservation(location:photoDeviceLocation,heading:photoDeviceHeading,cameraDirectionDegrees:deviceDirection?.degrees,cameraDirectionReference:deviceDirection?.reference)
            record.deviceCameraDirectionUsable=deviceDirection != nil
            record.outputCameraToDiagram=pose.map { PhotoGeometry.outputCameraToDiagram(raw:$0.cameraToDiagram,rotation:rotation) }
            record.updateSelectedValidity()
            if photoMode == .cameraOnly {
                let imageOrientation=CGImagePropertyOrientation(rawValue:rotation)!
                let buffer=frame.capturedImage
                DispatchQueue.global(qos:.userInitiated).async {
                    let result=Result { try PhotoArchive.cameraImage(buffer,orientation:imageOrientation) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self,self.activePhotoCaptureRequestID==requestID else { return }
                        switch result {
                        case .success(let image): self.archiveAndSavePhoto(image,record:record,requestID:requestID)
                        case .failure(let error):self.completePhotoCapture(requestID:requestID,success:false,message:"写真を作成できませんでした：\(error.localizedDescription)")
                        }
                    }
                }
                return
            }

            arView.snapshot(saveToHDR: false) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self,
                          self.activePhotoCaptureRequestID == requestID else { return }
                    guard let image else {
                        self.completePhotoCapture(
                            requestID: requestID,
                            success: false,
                            message: "AR写真を作成できませんでした"
                        )
                        return
                    }

                    if let after=arView.session.currentFrame {
                        record.followingFrameTimestamp=after.timestamp
                        record.followingRawCameraToARWorld=DiagramTransform.values(after.camera.transform)
                        record.followingRootToARWorld=DiagramTransform.values(root.transformMatrix(relativeTo:nil))
                        let sameRoot=zip(record.rootToARWorld,DiagramTransform.values(root.transformMatrix(relativeTo:nil))).allSatisfy { abs($0-$1)<0.00001 }
                        let stable=PhotoGeometry.stable(before:frame.camera.transform,after:after.camera.transform,seconds:after.timestamp-frame.timestamp)
                        if !stable || !sameRoot || epoch != self.observationEpoch || record.sessionID != self.photoSessionID {
                            record.arPoseUsable=false;record.arGeoreferenceUsable=false;record.deviceCameraDirectionUsable=false;record.issues.append("snapshot_pose_or_alignment_changed")
                        }
                        record.synchronization=stable && sameRoot ? "snapshot_bracket_stationary_estimate_not_exact_frame" : "snapshot_frame_unresolved"
                    } else { record.arPoseUsable=false;record.arGeoreferenceUsable=false;record.deviceCameraDirectionUsable=false;record.issues.append("snapshot_following_frame_missing") }
                    record.updateSelectedValidity()
                    let composite = self.compositeImage(image, labels: labels, viewSize: viewSize)
                    self.archiveAndSavePhoto(composite,record:record,requestID:requestID)
                }
            }
        }

        private func schedulePhotoCaptureWatchdog(
            for requestID: Int,
            after seconds: TimeInterval,
            message: String
        ) {
            photoCaptureWatchdog?.cancel()
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self,
                      self.activePhotoCaptureRequestID == requestID else { return }
                self.completePhotoCapture(requestID: requestID, success: false, message: message)
            }
            photoCaptureWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: watchdog)
        }

        private func completePhotoCapture(requestID: Int, success: Bool, message: String) {
            guard activePhotoCaptureRequestID == requestID else { return }
            photoCaptureWatchdog?.cancel()
            photoCaptureWatchdog = nil
            activePhotoCaptureRequestID = nil
            photoCaptureInProgress = false
            photoSnapshotStarted = false

            Task { @MainActor [uiBridge] in
                if success {
                    uiBridge.photoCaptureSucceeded(requestID,message:message)
                } else {
                    uiBridge.photoCaptureFailed(requestID, message: message)
                }
            }
        }

        private func notifyPhotoCaptureStarted(_ requestID: Int) {
            Task { @MainActor [uiBridge] in
                uiBridge.photoCaptureStarted(requestID)
            }
        }

        private func notifyPhotoCaptureSaving(_ requestID: Int) {
            Task { @MainActor [uiBridge] in
                uiBridge.photoCaptureSaving(requestID)
            }
        }

        private func compositeImage(_ image: UIImage, labels: [ScreenLabel], viewSize: CGSize) -> UIImage {
            guard viewSize.width > 0, viewSize.height > 0 else { return image }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            let scaleX = image.size.width / viewSize.width
            let scaleY = image.size.height / viewSize.height
            let textScale = max(1, min(scaleX, scaleY))

            return renderer.image { context in
                image.draw(in: CGRect(origin: .zero, size: image.size))

                for label in labels {
                    let font = UIFont.systemFont(
                        ofSize: 11 * textScale,
                        weight: label.labelRole == .parcel ? .bold : .semibold
                    )
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: UIColor.white
                    ]
                    let text = label.text as NSString
                    let textSize = text.size(withAttributes: attributes)
                    let paddingX = 5 * textScale
                    let paddingY = 3 * textScale
                    let center = CGPoint(
                        x: label.x * scaleX,
                        y: (label.y - label.screenYOffset) * scaleY
                    )
                    let rect = CGRect(
                        x: center.x - textSize.width / 2 - paddingX,
                        y: center.y - textSize.height / 2 - paddingY,
                        width: textSize.width + paddingX * 2,
                        height: textSize.height + paddingY * 2
                    )

                    let background: UIColor
                    if label.isSelected || label.text.hasPrefix("選択：") {
                        background = UIColor.systemRed.withAlphaComponent(0.78)
                    } else if label.labelRole == .parcel {
                        background = UIColor.systemBlue.withAlphaComponent(0.74)
                    } else {
                        background = UIColor.black.withAlphaComponent(0.62)
                    }

                    context.cgContext.saveGState()
                    context.cgContext.setAlpha(CGFloat(label.opacity))
                    background.setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: 6 * textScale).fill()
                    text.draw(
                        at: CGPoint(x: rect.minX + paddingX, y: rect.minY + paddingY),
                        withAttributes: attributes
                    )
                    context.cgContext.restoreGState()
                }
            }
        }

        private func archiveAndSavePhoto(_ image:UIImage,record:PhotoCaptureRecord,requestID:Int) {
            notifyPhotoCaptureSaving(requestID)
            schedulePhotoCaptureWatchdog(for:requestID,after:20,message:"写真の保存が時間内に完了しませんでした。撮影記録を確認してください")
            DispatchQueue.global(qos:.userInitiated).async {
                let result=Result { try PhotoArchive.save(image,record:record) }
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.activePhotoCaptureRequestID==requestID else { return }
                    switch result {
                    case .success(let package):self.savePhotoToLibrary(package,requestID:requestID)
                    case .failure(let error):self.completePhotoCapture(requestID:requestID,success:false,message:"撮影記録を保存できませんでした：\(error.localizedDescription)")
                    }
                }
            }
        }
        private func savePhotoToLibrary(_ package:PhotoArchive.Package, requestID: Int) {
            guard activePhotoCaptureRequestID == requestID else { return }
            PHPhotoLibrary.shared().performChanges {
                let request=PHAssetCreationRequest.forAsset()
                let options=PHAssetResourceCreationOptions();options.originalFilename=package.record.imageFileName
                request.creationDate=package.record.capturedAt
                request.addResource(with:.photo,data:package.jpeg,options:options)
            } completionHandler: { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self,
                          self.activePhotoCaptureRequestID == requestID else { return }
                    let message: String
                    if success {
                        message = package.record.selectedPositionUsable ? "写真と撮影座標を保存しました" : "写真を保存・撮影座標は確認待ち"
                    } else {
                        message = "撮影記録は端末内に保存済みです。写真アプリへの保存エラー：\(error?.localizedDescription ?? "不明なエラー")"
                    }
                    self.completePhotoCapture(requestID: requestID, success: success, message: message)
                }
            }
        }

        private func updateProjectedLabels(force: Bool = false) {
            guard isSessionActive else { return }
            guard let arView, let root = rootAnchor else { return }
            let now = CACurrentMediaTime()
            guard force || now - lastProjectionTime > 0.10 else { return }
            lastProjectionTime = now

            let visibleBounds = arView.bounds.insetBy(dx: -70, dy: -70)
            let parcelExtendedBounds = arView.bounds.insetBy(dx: -180, dy: -180)
            let cameraMatrix = arView.cameraTransform.matrix
            let cameraPosition = SIMD3<Float>(
                cameraMatrix.columns.3.x,
                cameraMatrix.columns.3.y,
                cameraMatrix.columns.3.z
            )
            let cameraForward = -SIMD3<Float>(
                cameraMatrix.columns.2.x,
                cameraMatrix.columns.2.y,
                cameraMatrix.columns.2.z
            )

            var projected: [ScreenLabel] = []

            for label in currentLabels {
                let worldPosition = root.convert(position: label.position, to: nil)

                // カメラの背面にある点は arView.project の結果が上下左右反転して見えることがある。
                // 一部ラベルだけ高さ方向が逆に動くように見える主因になり得るため、前方だけ投影する。
                let toLabel = worldPosition - cameraPosition
                guard simd_dot(toLabel, cameraForward) > 0.05 else { continue }

                guard let point = arView.project(worldPosition), point.x.isFinite, point.y.isFinite else { continue }

                let isParcelLabel = label.labelRole == .parcel
                if isParcelLabel {
                    guard parcelExtendedBounds.contains(point) else { continue }
                } else {
                    guard visibleBounds.contains(point) else { continue }
                }

                let text: String
                if currentShowDistance {
                    text = "\(label.text)  \(formatDistance(label.distance))"
                } else {
                    text = label.text
                }

                let x: CGFloat
                let y: CGFloat
                if isParcelLabel {
                    x = min(max(point.x, 24), max(24, arView.bounds.width - 24))
                    y = min(max(point.y, 84), max(84, arView.bounds.height - 92))
                } else {
                    x = point.x
                    y = point.y
                }

                projected.append(
                    ScreenLabel(
                        id: label.id,
                        text: text,
                        x: x,
                        y: y,
                        distance: label.distance,
                        labelRole: label.labelRole,
                        isSelected: label.isSelected,
                        screenYOffset: label.screenYOffset,
                        opacity: labelOpacityByID[label.id] ?? 1
                    )
                )
            }

            // Segment differences use saved metre coordinates; root alignment is rigid yaw/translation.
            var occupied: [CGPoint] = []
            for distance in drawingDistances {
                let world = root.convert(position:distance.midpoint,to:nil)
                guard simd_dot(world-cameraPosition,cameraForward)>0.05,
                      let point=arView.project(world), point.x.isFinite, point.y.isFinite,
                      arView.bounds.contains(point) else { continue }
                let text = distance.text(in:drawingDistanceMode)
                let textWidth = (text as NSString).size(withAttributes:[.font:UIFont.preferredFont(forTextStyle:.caption2)]).width + 14
                let margin = min(textWidth/2,arView.bounds.width/2)
                let position = CGPoint(x:max(margin,min(arView.bounds.width-margin,point.x)),y:point.y)
                guard !occupied.contains(where:{ hypot($0.x-position.x,$0.y-position.y)<45 }) else { continue }
                projected.append(ScreenLabel(id:distance.id,text:text,x:position.x,y:position.y,distance:distance.metres,screenYOffset:0,opacity:labelOpacityByID[distance.id] ?? 1))
                occupied.append(position)
                if occupied.count >= 40 { break }
            }

            var treeLabelCount=0
            // Stage feedback wins the label budget over nearby saved records and scale ticks.
            for label in treeDirectionLabels+treeExtraLabels {
                let world=root.convert(position:label.position,to:nil)
                guard simd_dot(world-cameraPosition,cameraForward)>0.05,let point=arView.project(world),arView.bounds.contains(point),treeLabelCount<TreeDisplayBudget.maximumLabels else {continue}
                projected.append(ScreenLabel(id:label.id,text:label.text,x:point.x,y:point.y,distance:simd_length(world-cameraPosition),screenYOffset:-18,opacity:1));treeLabelCount+=1
            }
            for tree in treeLabels {
                let world=root.convert(position:tree.position,to:nil)
                guard simd_dot(world-cameraPosition,cameraForward)>0.05,
                      let point=arView.project(world),arView.bounds.contains(point),treeLabelCount<TreeDisplayBudget.maximumLabels else {continue}
                projected.append(ScreenLabel(id:tree.id,text:tree.color.title+" "+tree.number+((tree.radius.isFinite && tree.radius>0) ? String(format:"\n直径 %.1f cm",Double(tree.radius)*200):"\n直径 未測定"),x:point.x,y:point.y,distance:simd_length(world-cameraPosition),screenYOffset:-12,opacity:1,maximumLines:2));treeLabelCount+=1
            }

            for marker in treeMarkerLabels where treeLabelCount<TreeDisplayBudget.maximumLabels {
                let world=root.convert(position:marker.position,to:nil)
                guard simd_dot(world-cameraPosition,cameraForward)>0.05,
                      let point=arView.project(world),arView.bounds.contains(point) else {continue}
                projected.append(ScreenLabel(id:marker.id,text:String(marker.number),x:point.x,y:point.y,distance:simd_length(world-cameraPosition),screenYOffset:-22,opacity:1));treeLabelCount+=1
            }

            if projected != lastProjectedLabels {
                lastProjectedLabels = projected
                Task { @MainActor [uiBridge] in
                    uiBridge.updateLabels(projected)
                }
            }
        }

        private func formatDistance(_ meters: Float) -> String {
            if meters >= 1000 {
                return String(format: "%.1fkm", meters / 1000)
            }
            if meters >= 100 {
                return String(format: "%.0fm", meters)
            }
            return String(format: "%.1fm", meters)
        }

        private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            simd_length(a - b)
        }

        private func setARStatus(_ message: String) {
            Task { @MainActor [uiBridge] in
                uiBridge.updateStatus(message)
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // pause直後にキュー済みのフレームが届いても、読込・設定・地図表示中は
            // 方位、深度、ラベルを一切更新しない。
            guard isSessionActive else { return }
            MainActor.assumeIsolated {
                if let input=scanInput,input.isRecording,let view=arView {
                    if let model=uiBridge.model,!model.arCameraActive || model.treeSurvey.active || model.drawing.active || model.drawingSelectionMode {
                        scanCapture?.stop(reason:"他の測定モード")
                    } else {
                        let orientation=view.window?.windowScene?.interfaceOrientation ?? .unknown
                        if let snapshot=GCPARFrameAdapter.snapshot(frame,viewport:view.bounds.size,orientation:orientation) {
                            scanCapture?.receive(snapshot) {
                                try ScanLiveAdapter.capture(frame,snapshot:snapshot,limits:scanCapture?.limits ?? ScanLimits())
                            }
                        } else {input.cancelRequest(reason:.viewChanged)}
                    }
                }
                if let capture=scanCapture,let view=arView {capture.synchronizePreviewContext();scanPreviewRenderer.update(capture,view:view,frame:frame)}
                if let model=uiBridge.model {updateTreeDisplay(model:model)}
            }
            hasReceivedActiveFrame = true
            let normal: Bool
            if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
            Task { @MainActor in self.updateDrogger(using:frame,normal:normal) }
            let depthReady = requestedLiDAREnabled && normal && frame.sceneDepth?.confidenceMap != nil
            Task { @MainActor [uiBridge] in uiBridge.model?.reportLiDARDepth(depthReady) }

            if let requestID = activePhotoCaptureRequestID,
               photoCaptureInProgress,
               !photoSnapshotStarted,
               let arView {
                let photoAuthorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                if photoAuthorization == .authorized || photoAuthorization == .limited {
                    beginPhotoSnapshotIfReady(requestID: requestID, from: arView)
                }
            }
            updateHorizontalScreenBasis(using: frame)
            updateHeadingStabilization(using: frame)
            updateLiDAROcclusion(using: frame)
            updateProjectedLabels()
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            MainActor.assumeIsolated {scanCapture?.stop(reason:"ARセッション中断");scanCapture?.invalidatePreview()}
            observationEpoch += 1
            Task { @MainActor [uiBridge] in uiBridge.model?.reportLiDARDepth(false); uiBridge.model?.drogger.suspendAR() }
            let message = error.localizedDescription

            // gravityAndHeading が端末状態・方位センサー状態によって失敗した場合でも、
            // カメラAR自体は使えることがある。その場合はコンパス連携を捨て、重力基準で再起動する。
            if currentAlignment == .gravityAndHeading, !fallbackToGravityUsed, let arView {
                fallbackToGravityUsed = true
                // 遅延実行中に画面が停止されても、次回復帰では安全なgravity基準を使う。
                currentAlignment = .gravity
                setARStatus("方位センサー失敗。重力基準で再起動")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak arView] in
                    guard let self, let arView else { return }
                    guard self.isSessionActive else { return }
                    self.runARSession(on: arView, alignment: .gravity, resetTracking: true)
                }
                return
            }

            setARStatus("ARエラー：\(message)")
        }

        func sessionWasInterrupted(_ session: ARSession) {
            MainActor.assumeIsolated {scanCapture?.stop(reason:"ARセッション中断");scanCapture?.invalidatePreview()}
            Task { @MainActor [uiBridge] in uiBridge.model?.reportLiDARDepth(false); uiBridge.model?.drogger.suspendAR() }
            observationEpoch += 1
            Task { @MainActor in self.clearObservation(); self.uiBridge.model?.treeSurvey.invalidateObservations("AR追跡が変わりました") }
            setARStatus("AR一時停止中")
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            setARStatus("AR再開")
            if isSessionActive, let arView {
                runARSession(on: arView, alignment: currentAlignment, resetTracking: true)
            }
        }

        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            MainActor.assumeIsolated {
                scanInput?.trackingChanged(GCPARFrameAdapter.tracking(camera.trackingState))
                if let capture=scanCapture,let view=arView {capture.synchronizePreviewContext();scanPreviewRenderer.update(capture,view:view,frame:view.session.currentFrame)}
            }
            let lidarText = requestedLiDAREnabled ? " / LiDAR補助" : ""
            switch camera.trackingState {
            case .normal:
                if currentAlignment == .gravity {
                    setARStatus("AR追跡中：方位なし\(lidarText)")
                } else {
                    setARStatus("AR追跡中\(lidarText)")
                }
            case .notAvailable:
                Task { @MainActor [uiBridge] in uiBridge.model?.reportLiDARDepth(false); uiBridge.model?.drogger.suspendAR() }
                observationEpoch += 1
                Task { @MainActor in self.clearObservation(); self.uiBridge.model?.treeSurvey.invalidateObservations("AR追跡が変わりました") }
                setARStatus("AR追跡不可")
            case .limited(let reason):
                Task { @MainActor [uiBridge] in uiBridge.model?.reportLiDARDepth(false); uiBridge.model?.drogger.suspendAR() }
                observationEpoch += 1
                Task { @MainActor in self.clearObservation(); self.uiBridge.model?.treeSurvey.invalidateObservations("AR追跡が変わりました") }
                switch reason {
                case .initializing:
                    setARStatus("AR初期化中")
                case .excessiveMotion:
                    setARStatus("AR制限：動き大")
                case .insufficientFeatures:
                    setARStatus("AR制限：特徴点不足")
                case .relocalizing:
                    setARStatus("AR再認識中")
                @unknown default:
                    setARStatus("AR制限中")
                }
            }
        }
    }
}
