import SwiftUI
import RealityKit
import ARKit
import AVFoundation
import UIKit

struct ARRendererView: UIViewRepresentable {
    @EnvironmentObject var model: AppModel

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
        arView.session.delegate = context.coordinator
        context.coordinator.model = model
        context.coordinator.arView = arView

        context.coordinator.rootAnchor = AnchorEntity(world: .zero)
        if let root = context.coordinator.rootAnchor {
            arView.scene.addAnchor(root)
        }

        context.coordinator.setSessionActive(model.arCameraActive, on: arView)
        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.model = model
        context.coordinator.arView = arView
        context.coordinator.setSessionActive(model.arCameraActive, on: arView)
        guard model.arCameraActive else { return }
        context.coordinator.setLiDARPreference(model.lidarEnabled, on: arView)
        guard let root = context.coordinator.rootAnchor else { return }

        // 画面ドラッグによる方位・高さ補正は、全Entityの再生成ではなくルートEntityの変換で処理する。
        // これにより、ドラッグ中の描画負荷を抑える。
        root.position = SIMD3<Float>(Float(model.planePanEastMeters), Float(model.displayPlaneOffsetMeters), Float(-model.planePanNorthMeters))
        root.orientation = simd_quatf(angle: Float(model.headingOffsetDegrees * .pi / 180.0), axis: SIMD3<Float>(0, 1, 0))

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
        weak var model: AppModel?
        weak var arView: ARView?
        var rootAnchor: AnchorEntity?

        private var fallbackToGravityUsed = false
        private var currentAlignment: ARConfiguration.WorldAlignment = .gravityAndHeading
        private var lastRenderSignature: Int = 0
        private var textureCache: [UUID: TextureResource] = [:]
        private var requestedLiDAREnabled = false
        private var lastAppliedLiDAREnabled: Bool?
        private var isSessionActive = false
        private var currentLabels: [RenderLabel] = []
        private var currentShowDistance = false
        private var lastProjectionTime: CFTimeInterval = 0
        private var lastProjectedLabels: [ScreenLabel] = []

        private struct LineSegment {
            var start: SIMD3<Float>
            var end: SIMD3<Float>
            var width: Float
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

        func setSessionActive(_ active: Bool, on arView: ARView) {
            if active {
                guard !isSessionActive else { return }
                isSessionActive = true
                startSession(on: arView)
            } else {
                guard isSessionActive else { return }
                arView.session.pause()
                isSessionActive = false
                lastProjectedLabels = []
                Task { @MainActor in
                    self.model?.screenLabels = []
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
                runARSession(on: arView, alignment: .gravityAndHeading, resetTracking: true)
            case .notDetermined:
                setARStatus("カメラ許可待ち")
                AVCaptureDevice.requestAccess(for: .video) { [weak self, weak arView] granted in
                    DispatchQueue.main.async {
                        guard let self, let arView else { return }
                        if granted {
                            self.runARSession(on: arView, alignment: .gravityAndHeading, resetTracking: true)
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
            requestedLiDAREnabled = enabled
            let supported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            Task { @MainActor in
                self.model?.lidarSupported = supported
            }

            guard isSessionActive else { return }
            guard lastAppliedLiDAREnabled != enabled else { return }
            lastAppliedLiDAREnabled = enabled
            if enabled && !supported {
                setARStatus("LiDAR非対応端末です")
                return
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

            if requestedLiDAREnabled && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }

            let options: ARSession.RunOptions = resetTracking ? [.resetTracking, .removeExistingAnchors] : []
            arView.session.run(config, options: options)
            isSessionActive = true

            let lidarText = requestedLiDAREnabled && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) ? " / LiDAR補助" : ""
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
            updateProjectedLabels(force: true)

            let signature = renderSignature(features: features, rasters: rasters, labels: labels, selectedPosition: selectedPosition, style: style, showPillars: showPillars)
            guard signature != lastRenderSignature else { return }
            lastRenderSignature = signature

            root.children.removeAll()
            guard !features.isEmpty || !rasters.isEmpty || selectedPosition != nil else { return }

            // GeoTIFFは先に置く。点・線はその上に描画する。
            for raster in rasters {
                addRaster(raster, opacity: style.rasterOpacity, to: root)
            }

            // 大量線分を1本ずつEntity化すると、RealityKit側のEntity数が増えて重くなる。
            // 線・柱は一度配列に集め、少数の結合メッシュとして追加する。
            var lineSegments: [LineSegment] = []
            var pillarSegments: [LineSegment] = []

            for feature in features {
                switch feature.kind {
                case .point:
                    for position in feature.positions {
                        addPoint(position, radius: effectivePointRadius(at: position, style: style), showPillar: false, to: root)
                        if showPillars {
                            appendPillar(at: position, to: &pillarSegments)
                        }
                    }
                case .line:
                    appendBoundaryLine(feature.positions, closed: false, style: style, showPillars: showPillars, lineSegments: &lineSegments, pillarSegments: &pillarSegments)
                case .polygon:
                    appendBoundaryLine(feature.positions, closed: true, style: style, showPillars: showPillars, lineSegments: &lineSegments, pillarSegments: &pillarSegments)
                }
            }

            addSegmentMesh(lineSegments, material: lineMaterial, into: root)
            addSegmentMesh(pillarSegments, material: pillarMaterial, into: root)

            if let selectedPosition {
                addSelectedPoint(selectedPosition, radius: style.selectedPointRadius, to: root)
            }
        }

        private func renderSignature(features: [RenderFeature], rasters: [RenderRaster], labels: [RenderLabel], selectedPosition: SIMD3<Float>?, style: RenderStyle, showPillars: Bool) -> Int {
            // 大量SIMA/KMLで毎回長大なStringを組み立てると、AR表示更新時のCPU負荷が出る。
            // Hashベースの軽量署名にして、標高ON時も不要な再生成を避ける。
            var hasher = Hasher()
            hasher.combine(showPillars)
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
                if let first = feature.positions.first { hashPosition(first, scale: 100, into: &hasher) }
                if let last = feature.positions.last { hashPosition(last, scale: 100, into: &hasher) }
            }

            return hasher.finalize()
        }

        private func hashPosition(_ position: SIMD3<Float>, scale: Float, into hasher: inout Hasher) {
            hasher.combine(Int((position.x * scale).rounded()))
            hasher.combine(Int((position.y * scale).rounded()))
            hasher.combine(Int((position.z * scale).rounded()))
        }

        private func addRaster(_ raster: RenderRaster, opacity: Float, to root: Entity) {
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
            } else if let generated = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
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
        }

        private func addPoint(_ position: SIMD3<Float>, radius: Float, showPillar: Bool, to root: Entity) {
            // 点は薄い板状だと真横から見えにくくなるため、球体表示に戻す。
            // 点数は表示制限で絞られるため、負荷の主因になりやすい線分より影響は小さい。
            let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [pointMaterial])
            sphere.position = position
            root.addChild(sphere)

            if showPillar {
                addPillar(at: position, to: root)
            }
        }

        private func addSelectedPoint(_ position: SIMD3<Float>, radius: Float, to root: Entity) {
            var material = UnlitMaterial()
            material.color = .init(tint: .systemRed)
            let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
            sphere.position = position + SIMD3<Float>(0, 0.05, 0)
            root.addChild(sphere)

            var pillarMaterial = UnlitMaterial()
            pillarMaterial.color = .init(tint: .systemRed.withAlphaComponent(0.75))
            addCylinder(from: position + SIMD3<Float>(0, -1.4, 0), to: position + SIMD3<Float>(0, 1.4, 0), radius: max(radius * 0.18, 0.025), material: pillarMaterial, into: root)
        }

        private func appendBoundaryLine(_ positions: [SIMD3<Float>], closed: Bool, style: RenderStyle, showPillars: Bool, lineSegments: inout [LineSegment], pillarSegments: inout [LineSegment]) {
            guard !positions.isEmpty else { return }

            if showPillars {
                for position in positions {
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
            guard style.farMinimumSizeEnabled else { return style.pointRadius }
            let d = simd_length(SIMD2<Float>(position.x, position.z))
            let scale = min(max(d / 35.0, 1.0), 4.0)
            return max(style.pointRadius, style.farPointMinRadius * scale)
        }

        private func effectiveLineRadius(from start: SIMD3<Float>, to end: SIMD3<Float>, style: RenderStyle) -> Float {
            guard style.farMinimumSizeEnabled else { return style.lineRadius }
            let mid = (start + end) / 2
            let d = simd_length(SIMD2<Float>(mid.x, mid.z))
            let scale = min(max(d / 35.0, 1.0), 3.5)
            return max(style.lineRadius, style.farLineMinRadius * scale)
        }

        private func appendPillar(at position: SIMD3<Float>, to segments: inout [LineSegment]) {
            let bottom = position + SIMD3<Float>(0, -5, 0)
            let top = position + SIMD3<Float>(0, 5, 0)
            appendSegment(from: bottom, to: top, radius: 0.035, to: &segments)
        }

        private func addPillar(at position: SIMD3<Float>, to root: Entity) {
            var segments: [LineSegment] = []
            appendPillar(at: position, to: &segments)
            addSegmentMesh(segments, material: pillarMaterial, into: root)
        }

        private func addCylinder(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, material: UnlitMaterial, into root: Entity) {
            var segments: [LineSegment] = []
            appendSegment(from: start, to: end, radius: radius, to: &segments)
            addSegmentMesh(segments, material: material, into: root)
        }

        private func appendSegment(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, to segments: inout [LineSegment]) {
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.001 else { return }
            let safeWidth = max(radius * 2.0, 0.003)
            segments.append(LineSegment(start: start, end: end, width: safeWidth))
        }

        private func addSegmentMesh(_ segments: [LineSegment], material: UnlitMaterial, into root: Entity) {
            guard !segments.isEmpty else { return }

            // 1メッシュが大きくなりすぎると環境差が出るため、適度な単位に分割する。
            let chunkSize = 1500
            var startIndex = 0
            while startIndex < segments.count {
                let endIndex = min(startIndex + chunkSize, segments.count)
                addSegmentMeshChunk(Array(segments[startIndex..<endIndex]), material: material, into: root)
                startIndex = endIndex
            }
        }

        private func addSegmentMeshChunk(_ segments: [LineSegment], material: UnlitMaterial, into root: Entity) {
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

        private func updateProjectedLabels(force: Bool = false) {
            guard let model, let arView, let root = rootAnchor else { return }
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

                projected.append(ScreenLabel(id: label.id, text: text, x: x, y: y, distance: label.distance, labelRole: label.labelRole, isSelected: label.isSelected, screenYOffset: label.screenYOffset))
            }

            if projected != lastProjectedLabels {
                lastProjectedLabels = projected
                Task { @MainActor in
                    model.screenLabels = projected
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
            Task { @MainActor in
                self.model?.arStatusMessage = message
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            updateProjectedLabels()
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            let message = error.localizedDescription

            // gravityAndHeading が端末状態・方位センサー状態によって失敗した場合でも、
            // カメラAR自体は使えることがある。その場合はコンパス連携を捨て、重力基準で再起動する。
            if currentAlignment == .gravityAndHeading, !fallbackToGravityUsed, let arView {
                fallbackToGravityUsed = true
                setARStatus("方位センサー失敗。重力基準で再起動")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak arView] in
                    guard let self, let arView else { return }
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
            let lidarText = requestedLiDAREnabled && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) ? " / LiDAR補助" : ""
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
