import SwiftUI
import RealityKit
import ARKit
import AVFoundation
import Photos
import UIKit

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
        model?.lidarSupported = supported
        if disableRequestedSetting {
            model?.lidarEnabled = false
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
    func photoCaptureSucceeded(_ requestID: Int) {
        model?.photoCaptureSucceeded(requestID: requestID)
    }

    @MainActor
    func photoCaptureFailed(_ requestID: Int, message: String) {
        model?.photoCaptureFailed(requestID: requestID, message: message)
    }
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
        context.coordinator.setSessionActive(model.arCameraActive, on: arView)
        context.coordinator.setLiDARPreference(model.lidarEnabled, on: arView)
        context.coordinator.setLiDARFadePreference(
            enabled: model.settings.lidarFadeBehindObjectsEnabled,
            behindOpacity: Float(model.settings.lidarBehindOpacity)
        )
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
        model.updateRenderedTransform(
            panEastMeters: model.planePanEastMeters,
            panNorthMeters: model.planePanNorthMeters,
            rootHeightMeters: Double(renderedRootHeight),
            totalHeadingDegrees: renderedTotalHeading
        )

        // 撮影要求は、表示要素が多い場合の再描画判定より先に受け付ける。
        // タップ後の反応を遅らせず、Coordinator側の監視タイマーもすぐ開始する。
        // AppModel側ですでにタイムアウト／失敗になった古い要求を、画面復帰後に
        // 遅れて撮影しない。要求が有効な撮影待ち状態の間だけCoordinatorへ渡す。
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
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        fileprivate let uiBridge = ARRendererUIBridge()
        weak var arView: ARView?
        var rootAnchor: AnchorEntity?

        private var fallbackToGravityUsed = false
        private var currentAlignment: ARConfiguration.WorldAlignment = .gravityAndHeading
        private var lastRenderSignature: Int = 0
        private var textureCache: [UUID: TextureResource] = [:]
        private var requestedLiDAREnabled = false
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
        private var lidarBehindOpacity: Float = 0.28
        private var lastDepthUpdateTime: CFTimeInterval = 0
        private var depthWasAvailable = false

        private var lastHandledPhotoCaptureRequestID = 0
        private var photoCaptureInProgress = false
        private var activePhotoCaptureRequestID: Int?
        private var photoSnapshotStarted = false
        private var photoCaptureWatchdog: DispatchWorkItem?

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
            )
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

        func setLiDARPreference(_ enabled: Bool, on arView: ARView) {
            let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            let effectiveEnabled = enabled && supported
            Task { @MainActor [uiBridge] in
                uiBridge.updateLiDARSupport(supported, disableRequestedSetting: enabled && !supported)
            }

            requestedLiDAREnabled = effectiveEnabled
            if !effectiveEnabled {
                if lidarFadeEffectiveActive {
                    resetOcclusionOpacity()
                }
                lidarFadeEffectiveActive = false
            }

            guard isSessionActive else { return }
            guard lastAppliedLiDAREnabled != effectiveEnabled else { return }
            lastAppliedLiDAREnabled = effectiveEnabled
            if enabled && !supported {
                setARStatus("LiDAR非対応端末です")
            }
            runARSession(on: arView, alignment: currentAlignment, resetTracking: false)
        }

        private func runARSession(on arView: ARView, alignment: ARConfiguration.WorldAlignment, resetTracking: Bool) {
            currentAlignment = alignment
            arView.environment.background = .cameraFeed(exposureCompensation: 0.45)
            arView.isOpaque = false
            arView.backgroundColor = .clear

            let config = ARWorldTrackingConfiguration()
            config.worldAlignment = alignment
            config.planeDetection = []
            config.isLightEstimationEnabled = true

            if requestedLiDAREnabled {
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth)
                }
                // 今回の前後判定はsceneDepthを直接使う。再構成メッシュは参照しないため、
                // 有効化せずLiDAR処理の余分な負荷を避ける。
            }

            let options: ARSession.RunOptions = resetTracking ? [.resetTracking, .removeExistingAnchors] : []
            arView.session.run(config, options: options)
            isSessionActive = true
            hasReceivedActiveFrame = false
            resetHeadingStabilization(clearCorrection: true)

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
            let validLabelIDs = Set(labels.map(\.id))
            labelOpacityByID = labelOpacityByID.filter { validLabelIDs.contains($0.key) }
            updateProjectedLabels(force: true)

            let signature = renderSignature(features: features, rasters: rasters, labels: labels, selectedPosition: selectedPosition, style: style, showPillars: showPillars)
            guard signature != lastRenderSignature else { return }
            lastRenderSignature = signature

            root.children.removeAll()
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
            var pillarSegments: [LineSegment] = []

            for feature in features {
                switch feature.kind {
                case .point:
                    for position in feature.positions {
                        addPoint(
                            position,
                            radius: effectivePointRadius(at: position, style: style),
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
            }

            addSegmentMesh(
                lineSegments,
                material: lineMaterial,
                registerForOcclusion: useDepthFadeGeometry,
                preferredOcclusionPieceLength: 0.30,
                into: root
            )
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

            let center = (raster.positions[0] + raster.positions[1] + raster.positions[2] + raster.positions[3]) / 4
            let edge = simd_normalize(topRight - topLeft)
            let yaw = atan2(-edge.z, edge.x)

            let texture: TextureResource
            if let cached = textureCache[raster.id] {
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

            let plane = ModelEntity(mesh: .generatePlane(width: width, depth: depth), materials: [material])
            plane.position = center + SIMD3<Float>(0, -0.02, 0)
            plane.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
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
            showPillar: Bool,
            registerForOcclusion: Bool,
            to root: Entity
        ) {
            // 点は薄い板状だと真横から見えにくくなるため、球体表示に戻す。
            // 点数は表示制限で絞られるため、負荷の主因になりやすい線分より影響は小さい。
            let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [pointMaterial])
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
            let midpoints = segments.map { ($0.start + $0.end) / 2 }
            let centroid = midpoints.reduce(SIMD3<Float>.zero) { $0 + $1 } / Float(midpoints.count)
            var samples: [SIMD3<Float>] = []
            samples.reserveCapacity(9)

            func appendUnique(_ candidate: SIMD3<Float>) {
                guard !samples.contains(where: { simd_length($0 - candidate) < 0.01 }) else { return }
                samples.append(candidate)
            }

            appendUnique(centroid)
            appendUnique(segments[0].start)
            appendUnique(segments[segments.count - 1].end)

            if let value = midpoints.min(by: { $0.x < $1.x }) { appendUnique(value) }
            if let value = midpoints.max(by: { $0.x < $1.x }) { appendUnique(value) }
            if let value = midpoints.min(by: { $0.y < $1.y }) { appendUnique(value) }
            if let value = midpoints.max(by: { $0.y < $1.y }) { appendUnique(value) }
            if let value = midpoints.min(by: { $0.z < $1.z }) { appendUnique(value) }
            if let value = midpoints.max(by: { $0.z < $1.z }) { appendUnique(value) }

            if samples.count < 9 {
                let remaining = 9 - samples.count
                for index in 0..<remaining {
                    let fraction = Float(index + 1) / Float(remaining + 1)
                    let midpointIndex = min(midpoints.count - 1, Int(fraction * Float(midpoints.count)))
                    appendUnique(midpoints[midpointIndex])
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

            guard let depthData = frame.sceneDepth,
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

            guard let depthBase = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self) else { return }
            let depthWidth = CVPixelBufferGetWidth(depthMap)
            let depthHeight = CVPixelBufferGetHeight(depthMap)
            let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

            let confidenceBase = confidenceMap.flatMap {
                CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self)
            }
            let confidenceWidth = confidenceMap.map { CVPixelBufferGetWidth($0) } ?? 0
            let confidenceHeight = confidenceMap.map { CVPixelBufferGetHeight($0) } ?? 0
            let confidenceStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

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
                var samples: [Float] = []
                samples.reserveCapacity(offsets.count)

                for (dx, dy) in offsets {
                    let x = min(depthWidth - 1, max(0, centerX + dx))
                    let y = min(depthHeight - 1, max(0, centerY + dy))

                    if let confidenceBase, confidenceWidth > 0, confidenceHeight > 0 {
                        let cx = min(confidenceWidth - 1, max(0, x * confidenceWidth / max(depthWidth, 1)))
                        let cy = min(confidenceHeight - 1, max(0, y * confidenceHeight / max(depthHeight, 1)))
                        let confidence = confidenceBase[cy * confidenceStride + cx]
                        // low confidenceは除外し、medium/highだけを使う。
                        guard confidence >= UInt8(clamping: ARConfidenceLevel.medium.rawValue) else { continue }
                    }

                    let value = depthBase[y * depthStride + x]
                    if value.isFinite, value > 0.10, value < 20 {
                        samples.append(value)
                    }
                }

                guard !samples.isEmpty else { return nil }
                samples.sort()
                // 中央値だけだと、手の輪郭で「近い画素2・背景3」の場合に背景側を選び、
                // 細い遮蔽物を見落としやすい。近い側から2番目を使い、単発ノイズだけ除外する。
                return samples[samples.count >= 3 ? 1 : 0]
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
                let virtualDepth = -cameraPosition.z
                guard virtualDepth.isFinite, virtualDepth > 0.05 else { return nil }

                // 1つの閾値で急に切り替えず、深度ノイズを吸収する18cm幅の遷移帯を設ける。
                let delta = virtualDepth - realDepth
                let transitionStart: Float = 0.12
                let transitionEnd: Float = 0.30
                return max(0, min(1, (delta - transitionStart) / (transitionEnd - transitionStart)))
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
                        // 約30cm片では境界サンプル1点だけが手に隠れる場合も視認できる強さにする。
                        behindCoverage = max(averageCoverage, strongestBehindWeight * 0.80)
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
            photoSnapshotStarted = true
            notifyPhotoCaptureStarted(requestID)
            schedulePhotoCaptureWatchdog(
                for: requestID,
                after: 12,
                message: "AR写真の作成が時間内に完了しませんでした。もう一度お試しください"
            )
            let labels = lastProjectedLabels
            let viewSize = arView.bounds.size

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

                    let composite = self.compositeImage(image, labels: labels, viewSize: viewSize)
                    self.notifyPhotoCaptureSaving(requestID)
                    self.schedulePhotoCaptureWatchdog(
                        for: requestID,
                        after: 15,
                        message: "写真アプリへの保存が時間内に完了しませんでした。もう一度お試しください"
                    )
                    self.savePhotoToLibrary(composite, requestID: requestID)
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
                    uiBridge.photoCaptureSucceeded(requestID)
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

        private func savePhotoToLibrary(_ image: UIImage, requestID: Int) {
            guard activePhotoCaptureRequestID == requestID else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self,
                          self.activePhotoCaptureRequestID == requestID else { return }
                    let message: String
                    if success {
                        message = "AR写真を写真アプリへ保存しました"
                    } else {
                        message = "AR写真の保存エラー：\(error?.localizedDescription ?? "不明なエラー")"
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
            hasReceivedActiveFrame = true

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
            setARStatus("AR一時停止中")
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            setARStatus("AR再開")
            if isSessionActive, let arView {
                runARSession(on: arView, alignment: currentAlignment, resetTracking: true)
            }
        }

        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            let lidarText = requestedLiDAREnabled ? " / LiDAR補助" : ""
            switch camera.trackingState {
            case .normal:
                if currentAlignment == .gravity {
                    setARStatus("AR追跡中：方位なし\(lidarText)")
                } else {
                    setARStatus("AR追跡中\(lidarText)")
                }
            case .notAvailable:
                setARStatus("AR追跡不可")
            case .limited(let reason):
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
