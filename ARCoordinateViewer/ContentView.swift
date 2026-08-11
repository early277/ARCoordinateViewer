import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import ReplayKit
import UIKit

private enum ARAdjustmentAxis {
    case heading
    case height
}

private enum MainWorkspace: Hashable {
    case ar
    case map
    case data
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var locationManager: LocationManager
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var showImporter = false
    @State private var showLatLonInput = false
    @State private var showPlaneInput = false
    @State private var showPointSelection = false
    @State private var showPlanMap = false
    @State private var showSettings = false
    @State private var showLayerManager = false
    @State private var showHelp = false
    @State private var showAlignment = false
    @State private var showStatusDetails = false
    @State private var showCoordinateMenu = false
    @State private var showGeoTIFFCoordinateSheet = false
    @State private var showCSVImportSheet = false
    @State private var pendingCSVText = ""
    @State private var pendingCSVFileName = ""
    @State private var pendingGeoTIFFData: Data?
    @State private var pendingGeoTIFFFileName = ""
    @State private var torchEnabled = false
    @State private var adjustmentAxis: ARAdjustmentAxis?
    @State private var dragStartHeadingDegrees: Double = 0
    @State private var dragStartPlaneOffsetMeters: Double = -1.0
    @State private var horizontalPadFineMode = true
    @State private var horizontalPadDragStartEastMeters: Double = 0
    @State private var horizontalPadDragStartNorthMeters: Double = 0
    @State private var horizontalPadDragBasis: HorizontalScreenBasis?
    @State private var horizontalPadDragHeadingDegrees: Double = 0
    @State private var horizontalPadDragOffset: CGSize = .zero
    @State private var horizontalPadIsDragging = false
    @AppStorage("ARCoordinateViewer.HorizontalMovePadVisible")
    private var horizontalMovePadVisible = true
    @State private var presentationUIHidden = false
    @State private var recordingUIHidden = false
    @State private var recordingStarting = false
    @State private var isRecording = false
    @State private var replayPreview: ReplayPreviewItem?
    @State private var selectedWorkspace: MainWorkspace = .ar
    @State private var photoFlashVisible = false
    @State private var photoFailureMessage: String?
    @State private var captureFeedbackTrigger = 0

    private var supportedImportTypes: [UTType] {
        [
            UTType(filenameExtension: "kml") ?? .xml,
            UTType(filenameExtension: "kmz") ?? .data,
            UTType(filenameExtension: "sim") ?? .plainText,
            UTType(filenameExtension: "sima") ?? .plainText,
            UTType(filenameExtension: "tif") ?? .tiff,
            UTType(filenameExtension: "tiff") ?? .tiff,
            UTType(filenameExtension: "zip") ?? .data,
            .commaSeparatedText,
            .plainText,
            .text,
            .xml,
            .tiff,
            .data
        ]
    }

    var body: some View {
        lifecycleObserversView
    }

    // ContentViewには多数のsheet／onChangeがあるため、1本の巨大なView式にすると
    // Swiftコンパイラの型推論が時間切れになることがある。機能単位で式を分割し、
    // 各段階を個別に型チェックできるようにする。
    private var workspaceTabsView: some View {
        TabView(selection: $selectedWorkspace) {
            arWorkspace
                .tag(MainWorkspace.ar)
                .tabItem {
                    Label("AR", systemImage: "viewfinder")
                }

            PlanMapSheet(isEmbedded: true) {
                selectedWorkspace = .ar
            }
            .tag(MainWorkspace.map)
            .tabItem {
                Label("地図", systemImage: "map")
            }

            LayerManagerSheet(isEmbedded: true) {
                model.arCameraActive = false
                showImporter = true
            }
            .tag(MainWorkspace.data)
            .tabItem {
                Label("データ", systemImage: "square.stack.3d.up")
            }
        }
        .toolbar(recordingUIHidden || presentationUIHidden ? .hidden : .visible, for: .tabBar)
    }

    private var fileImportView: some View {
        workspaceTabsView
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: supportedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { handleSelectedFile(url) }
            case .failure(let error):
                model.statusMessage = "ファイル選択エラー：\(error.localizedDescription)"
            }
            updateARCameraActivity()
        }
    }

    private var coordinateSheetsView: some View {
        fileImportView
        .sheet(isPresented: $showLatLonInput) {
            LatLonInputSheet { lat, lon in model.setOrigin(latitude: lat, longitude: lon) }
        }
        .sheet(isPresented: $showPlaneInput) {
            PlaneInputSheet(initialSystem: model.planeSystemNumber) { system, x, y in
                model.setOriginFromPlane(system: system, x: x, y: y)
            }
        }
        .sheet(isPresented: $showPointSelection) {
            PointSelectionSheet(points: model.importedPointList) { point in model.setOriginFromPoint(point) }
        }
        .sheet(isPresented: $showPlanMap) {
            PlanMapSheet()
        }
    }

    private var utilitySheetsView: some View {
        coordinateSheetsView
        .sheet(isPresented: $showSettings) {
            DisplaySettingsSheet()
        }
        .sheet(isPresented: $showLayerManager) {
            LayerManagerSheet()
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet()
        }
        .sheet(isPresented: $showAlignment) {
            alignmentSheet
        }
        .sheet(isPresented: $showStatusDetails) {
            statusDetailsSheet
        }
    }

    private var dataImportSheetsView: some View {
        utilitySheetsView
        .sheet(isPresented: $showGeoTIFFCoordinateSheet) {
            GeoTIFFCoordinateSheet(initialSystem: model.planeSystemNumber) { purpose, mode in
                if let data = pendingGeoTIFFData {
                    switch purpose {
                    case .backgroundImage:
                        model.importGeoTIFF(
                            data: data,
                            fileName: pendingGeoTIFFFileName,
                            coordinateMode: mode
                        )
                    case .elevationDEM:
                        model.importElevationGeoTIFF(
                            data: data,
                            fileName: pendingGeoTIFFFileName,
                            coordinateMode: mode
                        )
                    }
                }
                pendingGeoTIFFData = nil
                pendingGeoTIFFFileName = ""
            }
        }
        .sheet(isPresented: $showCSVImportSheet) {
            CSVImportSheet(
                fileName: pendingCSVFileName,
                csvText: pendingCSVText,
                defaultPlaneSystem: model.planeSystemNumber
            ) { mapping in
                model.importCSV(text: pendingCSVText, fileName: pendingCSVFileName, mapping: mapping)
                pendingCSVText = ""
                pendingCSVFileName = ""
            }
        }
    }

    private var replaySheetView: some View {
        dataImportSheetsView
        .sheet(item: $replayPreview, onDismiss: updateARCameraActivity) { item in
            ReplayPreviewSheet(previewController: item.controller) {
                replayPreview = nil
                updateARCameraActivity()
            }
        }
    }

    private var dialogsView: some View {
        replaySheetView
        .confirmationDialog("立ち位置の設定方法", isPresented: $showCoordinateMenu, titleVisibility: .visible) {
            Button("iPhoneの現在位置を使う") { locationManager.requestCurrentLocationOnce() }
            Button("読み込んだ点を立ち位置にする") { showPointSelection = true }
                .disabled(model.importedPointList.isEmpty)
            Button("緯度経度を入力") { showLatLonInput = true }
            Button("平面直角座標を入力") { showPlaneInput = true }
            Button("キャンセル", role: .cancel) { }
        }
    }

    private var photoFeedbackView: some View {
        dialogsView
        .alert(
            "写真を保存できませんでした",
            isPresented: photoFailurePresentedBinding
        ) {
            if photoFailureMessage?.contains("許可") == true {
                Button("iOSの設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            Button("閉じる", role: .cancel) {
                photoFailureMessage = nil
                model.dismissPhotoCaptureFeedback()
            }
        } message: {
            Text(photoFailureMessage ?? "写真の作成または保存に失敗しました")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: captureFeedbackTrigger)
    }

    private var primaryLifecycleObserversView: some View {
        photoFeedbackView
        .onAppear {
            locationManager.requestAuthorizationIfNeeded()
            updateARCameraActivity()
        }
        .onChange(of: showImporter) { updateARCameraActivity() }
        .onChange(of: showLatLonInput) { updateARCameraActivity() }
        .onChange(of: showPlaneInput) { updateARCameraActivity() }
        .onChange(of: showPointSelection) { updateARCameraActivity() }
        .onChange(of: showPlanMap) { updateARCameraActivity() }
        .onChange(of: showSettings) { updateARCameraActivity() }
        .onChange(of: showLayerManager) { updateARCameraActivity() }
        .onChange(of: showHelp) { updateARCameraActivity() }
    }

    private var secondaryLifecycleObserversView: some View {
        primaryLifecycleObserversView
        .onChange(of: showCoordinateMenu) { updateARCameraActivity() }
        .onChange(of: showGeoTIFFCoordinateSheet) { updateARCameraActivity() }
        .onChange(of: showCSVImportSheet) { updateARCameraActivity() }
        .onChange(of: replayPreview?.id) { updateARCameraActivity() }
        .onChange(of: showAlignment) { updateARCameraActivity() }
        .onChange(of: showStatusDetails) { updateARCameraActivity() }
        .onChange(of: selectedWorkspace) { updateARCameraActivity() }
        .onChange(of: scenePhase) { updateARCameraActivity() }
    }

    private var lifecycleObserversView: some View {
        secondaryLifecycleObserversView
        .onChange(of: model.photoCaptureState) { _, state in
            if case .failure(let message) = state {
                photoFailureMessage = message
            }
        }
    }

    private var photoFailurePresentedBinding: Binding<Bool> {
        Binding(
            get: { photoFailureMessage != nil },
            set: { isPresented in
                if !isPresented { photoFailureMessage = nil }
            }
        )
    }

    private var shouldPauseARCamera: Bool {
        scenePhase != .active || selectedWorkspace != .ar || showImporter || showLatLonInput || showPlaneInput || showPointSelection || showPlanMap || showSettings || showLayerManager || showHelp || showStatusDetails || showCoordinateMenu || showGeoTIFFCoordinateSheet || showCSVImportSheet || replayPreview != nil
    }

    private func updateARCameraActivity() {
        model.arCameraActive = !shouldPauseARCamera
        locationManager.setHeadingUpdatesActive(!shouldPauseARCamera)
    }

    private var effectiveDisplayHeightBinding: Binding<Double> {
        Binding(
            get: { model.effectiveDisplayPlaneOffsetMeters },
            set: { model.setEffectiveDisplayPlaneOffsetMeters($0) }
        )
    }

    private var arAdjustmentGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                if adjustmentAxis == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard max(dx, dy) >= 8 else { return }

                    // 斜めスワイプで方位と高さが同時に変わらないよう、
                    // 最初に優勢だった方向だけをこのドラッグの調整軸として固定する。
                    let lockRatio: CGFloat = 1.15
                    if dx >= dy * lockRatio {
                        adjustmentAxis = .heading
                    } else if dy >= dx * lockRatio {
                        adjustmentAxis = .height
                    } else {
                        return
                    }
                    dragStartHeadingDegrees = model.headingOffsetDegrees
                    dragStartPlaneOffsetMeters = model.effectiveDisplayPlaneOffsetMeters
                }

                guard let axis = adjustmentAxis else { return }
                switch axis {
                case .heading:
                    let sensitivityDegreesPerPoint = 0.18
                    model.headingOffsetDegrees = dragStartHeadingDegrees - Double(value.translation.width) * sensitivityDegreesPerPoint
                case .height:
                    let sensitivityMetersPerPoint = 0.012
                    let next = dragStartPlaneOffsetMeters - Double(value.translation.height) * sensitivityMetersPerPoint
                    model.setEffectiveDisplayPlaneOffsetMeters(next)
                }
            }
            .onEnded { _ in
                if let axis = adjustmentAxis {
                    switch axis {
                    case .heading:
                        model.statusMessage = "方位補正：\(model.displayHeadingOffsetDegrees.formatted(.number.precision(.fractionLength(1))))°"
                    case .height:
                        model.statusMessage = "表示高さ：\(model.effectiveDisplayPlaneOffsetMeters.formatted(.number.precision(.fractionLength(2))))m"
                    }
                }
                adjustmentAxis = nil
            }
    }


    private func adjustedLabelY(for label: ScreenLabel) -> CGFloat {
        max(16, label.y - label.screenYOffset)
    }

    private func labelBackground(for label: ScreenLabel) -> Color {
        if label.isSelected || label.text.hasPrefix("選択：") {
            return .red.opacity(0.78)
        }
        switch label.labelRole {
        case .parcel:
            return .blue.opacity(0.74)
        case .point:
            return .black.opacity(0.62)
        case .none:
            return .black.opacity(0.62)
        }
    }

    private var screenLabelsOverlay: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.screenLabels) { label in
                Text(label.text)
                    .font(.caption2.weight(label.labelRole == .parcel ? .bold : .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(labelBackground(for: label), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        if label.labelRole == .parcel {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.white.opacity(0.85), lineWidth: 1)
                        }
                    }
                    .foregroundStyle(.white)
                    .opacity(label.opacity)
                    .position(x: label.x, y: adjustedLabelY(for: label))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var arWorkspace: some View {
        ZStack {
            ARRendererView()
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(arAdjustmentGesture)

            screenLabelsOverlay

            if photoFlashVisible {
                Color.white
                    .opacity(0.72)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if recordingStarting || isRecording {
                recordingStopOverlay
            } else if presentationUIHidden {
                restoreARUIControl
            } else if !recordingUIHidden {
                arControlsOverlay
            }
        }
    }

    private var arControlsOverlay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                arStatusButton
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        presentationUIHidden = true
                    }
                } label: {
                    Image(systemName: "eye.slash.fill")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("操作UIを隠す")

                arUtilityMenu
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Spacer(minLength: 0)

            photoStatusBanner

            HStack(alignment: .bottom, spacing: 8) {
                if horizontalMovePadVisible {
                    compactHorizontalMovePad
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Spacer(minLength: 4)

                compactCaptureControls
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private var restoreARUIControl: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        presentationUIHidden = false
                    }
                } label: {
                    Label("操作を表示", systemImage: "eye.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("操作UIを表示")
                .padding(.trailing, 10)
                .padding(.top, 6)
            }
            Spacer()
        }
    }

    private var arStatusButton: some View {
        Button(action: performStatusAction) {
            HStack(spacing: 7) {
                Image(systemName: arStatusIcon)
                    .foregroundStyle(arStatusTint)
                Text(arStatusText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(arStatusAccessibilityHint)
    }

    private var arStatusText: String {
        if model.features.isEmpty && model.rasters.isEmpty && model.elevationGrids.isEmpty {
            return "データを追加してください"
        }
        if model.origin == nil {
            return "立ち位置を設定してください"
        }
        if let selectedName = model.selectedPoint?.name, !selectedName.isEmpty {
            return "\(model.arStatusMessage)・目標 \(selectedName)"
        }
        return model.arStatusMessage
    }

    private var arStatusIcon: String {
        if model.features.isEmpty && model.rasters.isEmpty && model.elevationGrids.isEmpty { return "doc.badge.plus" }
        if model.origin == nil { return "location.slash" }
        if model.arStatusMessage.contains("失敗") || model.arStatusMessage.contains("エラー") {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var arStatusTint: Color {
        if model.features.isEmpty && model.rasters.isEmpty && model.elevationGrids.isEmpty { return .orange }
        if model.origin == nil { return .orange }
        if model.arStatusMessage.contains("失敗") || model.arStatusMessage.contains("エラー") {
            return .red
        }
        return .green
    }

    private var arStatusAccessibilityHint: String {
        if model.features.isEmpty && model.rasters.isEmpty && model.elevationGrids.isEmpty { return "データ画面を開きます" }
        if model.origin == nil { return "立ち位置の設定方法を表示します" }
        return "ARの詳しい状態を表示します"
    }

    private func performStatusAction() {
        if model.features.isEmpty && model.rasters.isEmpty && model.elevationGrids.isEmpty {
            selectedWorkspace = .data
        } else if model.origin == nil {
            showCoordinateMenu = true
        } else {
            showStatusDetails = true
        }
    }

    private var arUtilityMenu: some View {
        Menu {
            Button {
                showCoordinateMenu = true
            } label: {
                Label("立ち位置を設定", systemImage: "location")
            }

            Button {
                selectedWorkspace = .data
            } label: {
                Label("読み込んだデータ", systemImage: "square.stack.3d.up")
            }

            Button {
                showSettings = true
            } label: {
                Label("詳細設定", systemImage: "gearshape")
            }

            Button(action: toggleTorch) {
                Label(torchEnabled ? "ライトを消す" : "ライトをつける", systemImage: torchEnabled ? "flashlight.off.fill" : "flashlight.on.fill")
            }

            Divider()

            Toggle("前後左右パッドを表示", isOn: $horizontalMovePadVisible)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    presentationUIHidden = true
                }
            } label: {
                Label("操作UIを隠す", systemImage: "eye.slash")
            }

            Divider()

            Button {
                showHelp = true
            } label: {
                Label("使い方・ヘルプ", systemImage: "questionmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .foregroundStyle(.primary)
                .padding(5)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("その他の操作")
    }

    private var compactHorizontalMovePad: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text("位置調整")
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 2)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        horizontalMovePadVisible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("前後左右パッドを隠す")
            }

            HStack(spacing: 4) {
                Button(horizontalPadFineMode ? "微" : "大") {
                    horizontalPadFineMode.toggle()
                    model.statusMessage = horizontalPadFineMode ? "水平移動：微調整モード" : "水平移動：大移動モード"
                }
                .font(.caption2.weight(.bold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(horizontalPadFineMode ? .cyan : .orange)
                .disabled(model.origin == nil)
                .accessibilityLabel("移動感度を切り替え")
                .accessibilityValue(horizontalPadFineMode ? "微調整、1センチ" : "大移動、8センチ")

                Button("中心を更新") {
                    model.updateOriginToCurrentPanCenter()
                }
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(model.origin == nil)
                .accessibilityLabel("現在の表示中心と高さを新しい基準にする")
            }

            ZStack {
                Circle()
                    .fill(.black.opacity(0.12))
                    .overlay(Circle().stroke(.white.opacity(0.58), lineWidth: 1))
                    .frame(width: 82, height: 82)

                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Circle()
                    .fill(horizontalPadFineMode ? Color.cyan.opacity(0.82) : Color.orange.opacity(0.84))
                    .overlay(Circle().stroke(.white.opacity(0.86), lineWidth: 1))
                    .frame(width: 30, height: 30)
                    .offset(clampedHorizontalPadOffset)
                    .shadow(radius: 2)
            }
            .frame(width: 82, height: 82)
            .contentShape(Circle())
            .gesture(horizontalPadGesture)
            .opacity(model.origin == nil ? 0.45 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("前後左右の位置調整パッド")
            .accessibilityValue(horizontalPadFineMode ? "微調整、1センチ" : "大移動、8センチ")
            .accessibilityHint("動かしたい方向へドラッグします")

            HStack(spacing: 5) {
                Text(horizontalPadFineMode ? "1cm" : "8cm")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("0") {
                    model.resetPlanePan()
                    model.statusMessage = "水平移動をリセットしました"
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(model.origin == nil)
                .accessibilityLabel("前後左右の調整を0に戻す")
            }
        }
        .padding(6)
        .frame(width: 112)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var clampedHorizontalPadOffset: CGSize {
        let maxRadius: CGFloat = 27
        let length = hypot(horizontalPadDragOffset.width, horizontalPadDragOffset.height)
        guard length > maxRadius else { return horizontalPadDragOffset }
        let scale = maxRadius / length
        return CGSize(
            width: horizontalPadDragOffset.width * scale,
            height: horizontalPadDragOffset.height * scale
        )
    }

    private var horizontalPadGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard model.origin != nil else { return }
                if !horizontalPadIsDragging {
                    guard let screenBasis = model.currentHorizontalScreenBasis() else {
                        model.statusMessage = "ARの正面方向を取得中です。少し待ってから操作してください"
                        return
                    }
                    horizontalPadIsDragging = true
                    horizontalPadDragStartEastMeters = model.planePanEastMeters
                    horizontalPadDragStartNorthMeters = model.planePanNorthMeters
                    horizontalPadDragBasis = screenBasis
                    horizontalPadDragHeadingDegrees = model.currentRenderedTotalHeadingDegrees()
                }
                guard let screenBasis = horizontalPadDragBasis else { return }
                horizontalPadDragOffset = value.translation
                let metersPerPoint = horizontalPadFineMode ? 0.01 : 0.08
                model.setPlanePanFromScreenDrag(
                    startEast: horizontalPadDragStartEastMeters,
                    startNorth: horizontalPadDragStartNorthMeters,
                    translation: value.translation,
                    metersPerPoint: metersPerPoint,
                    screenBasis: screenBasis,
                    totalHeadingDegrees: horizontalPadDragHeadingDegrees
                )
            }
            .onEnded { _ in
                guard horizontalPadIsDragging else { return }
                model.statusMessage = "水平移動：東西 \(model.planePanEastMeters.formatted(.number.precision(.fractionLength(2))))m / 南北 \(model.planePanNorthMeters.formatted(.number.precision(.fractionLength(2))))m"
                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                    horizontalPadDragOffset = .zero
                }
                horizontalPadIsDragging = false
                horizontalPadDragBasis = nil
                horizontalPadDragHeadingDegrees = 0
            }
    }

    private var compactCaptureControls: some View {
        HStack(spacing: 8) {
            Button {
                showAlignment = true
            } label: {
                Image(systemName: "move.3d")
                    .font(.title3)
                    .frame(width: 38, height: 38)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("位置合わせの詳細")

            photoCaptureButton
            videoCaptureButton
            displayItemsMenu
        }
        .padding(7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var photoCaptureButton: some View {
        Button(action: performPhotoCapture) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 48, height: 48)
                Circle()
                    .stroke(.black.opacity(0.18), lineWidth: 1)
                    .frame(width: 48, height: 48)

                if photoCaptureIsBusy {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                        .foregroundStyle(.black)
                }
            }
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .disabled(captureButtonDisabled)
        .accessibilityLabel("AR写真を撮る")
    }

    private var videoCaptureButton: some View {
        Button(action: startARRecording) {
            Image(systemName: "video.fill")
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.red.opacity(0.90), in: Circle())
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .disabled(captureButtonDisabled)
        .accessibilityLabel("AR動画の録画を開始")
    }

    private var displayItemsMenu: some View {
        Menu {
            Toggle("点を表示", isOn: $model.settings.showPoints)
            Toggle("線を表示", isOn: $model.settings.showLines)
            Toggle("点名を表示", isOn: $model.settings.showLabels)
            Toggle("距離を表示", isOn: $model.distancesEnabled)
            Toggle("柱を表示", isOn: $model.pillarsEnabled)
            Toggle("GeoTIFF画像を表示", isOn: $model.rastersEnabled)
                .disabled(model.rasters.isEmpty)
            Toggle("境界線をDEMの地形に沿わせる", isOn: $model.settings.boundaryTerrainFollowEnabled)
                .disabled(!model.hasElevationDEM)

            Divider()

            Toggle("前後左右パッドを表示", isOn: $horizontalMovePadVisible)

            Divider()

            Toggle("LiDARを使用", isOn: $model.lidarEnabled)
            Toggle("物体の後ろを薄く表示", isOn: $model.settings.lidarFadeBehindObjectsEnabled)
                .disabled(!model.lidarEnabled)

            Divider()

            Button {
                showSettings = true
            } label: {
                Label("詳しい表示設定", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "eye")
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("表示項目")
    }

    private func performPhotoCapture() {
        captureFeedbackTrigger &+= 1
        withAnimation(.easeOut(duration: 0.04)) {
            photoFlashVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.18)) {
                photoFlashVisible = false
            }
        }
        model.requestARPhotoCapture()
    }

    private var captureButtonDisabled: Bool {
        recordingStarting || isRecording || photoCaptureIsBusy
    }

    private var photoCaptureIsBusy: Bool {
        model.photoCaptureState.isBusy
    }

    @ViewBuilder
    private var photoStatusBanner: some View {
        switch model.photoCaptureState {
        case .idle:
            EmptyView()
        case .capturing:
            captureStatusPill(icon: "camera.viewfinder", text: "AR写真を作成中…", tint: .blue, showsProgress: true)
        case .saving:
            captureStatusPill(icon: "square.and.arrow.down", text: "写真アプリへ保存中…", tint: .blue, showsProgress: true)
        case .success:
            captureStatusPill(icon: "checkmark.circle.fill", text: "写真アプリに保存しました", tint: .green)
        case .failure(let message):
            captureStatusPill(icon: "exclamationmark.triangle.fill", text: message, tint: .red)
        }
    }

    private func captureStatusPill(icon: String, text: String, tint: Color, showsProgress: Bool = false) -> some View {
        HStack(spacing: 7) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 20)
    }

    private var alignmentSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("立ち位置") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.origin?.name ?? "未設定")
                                .font(.subheadline.weight(.semibold))
                            Text("AR表示の基準となる、現在立っている位置です。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("立ち位置を設定・変更") {
                                showAlignment = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    showCoordinateMenu = true
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("表示位置を前後左右に合わせる") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("AR画面に前後左右パッドを表示", isOn: $horizontalMovePadVisible)

                            Text("ゲームの移動パッドと同じように、丸いパッドを現在位置を移動したい方向へ倒します。上へ倒すと前進し、地物表示は反対へ動きます。「微／大」で感度を切り替え、位置と高さが合ったら「中心を更新」で新しい基準を確定します。「0」は水平調整だけをリセットします。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            LabeledContent(
                                "現在の補正",
                                value: "東西 \(model.planePanEastMeters.formatted(.number.precision(.fractionLength(2))))m / 南北 \(model.planePanNorthMeters.formatted(.number.precision(.fractionLength(2))))m"
                            )
                            .font(.caption)

                            HStack {
                                Button("前後左右をリセット") {
                                    model.resetPlanePan()
                                    model.statusMessage = "前後左右の調整をリセットしました"
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button("この位置と高さを基準にする") {
                                    model.updateOriginToCurrentPanCenter()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .font(.caption)
                        }
                    }

                    GroupBox("方位と高さ") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("方位の補正")
                                Spacer()
                                Text("\(model.displayHeadingOffsetDegrees, specifier: "%+.1f")°")
                                    .monospacedDigit()
                            }
                            Slider(value: $model.headingOffsetDegrees, in: -180...180, step: 0.5)

                            HStack {
                                Text("表示する高さ")
                                Spacer()
                                Text("\(model.effectiveDisplayPlaneOffsetMeters, specifier: "%+.1f")m")
                                    .monospacedDigit()
                            }
                            Slider(value: effectiveDisplayHeightBinding, in: -100...100, step: 0.1)

                            HStack {
                                Button("方位をリセット") {
                                    model.headingOffsetDegrees = 0
                                }
                                .buttonStyle(.bordered)

                                Button("高さを初期値へ") {
                                    model.resetDisplayHeight()
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption)

                            Text("AR画面では、横スワイプでも方位、縦スワイプでも高さを調整できます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("位置合わせ")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showAlignment = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var statusDetailsSheet: some View {
        NavigationStack {
            Form {
                Section("ARの状態") {
                    LabeledContent("追跡", value: model.arStatusMessage)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("立ち位置") {
                    if let origin = model.origin {
                        LabeledContent("名称", value: origin.name ?? "設定済み")
                        LabeledContent("緯度", value: origin.latitude.formatted(.number.precision(.fractionLength(7))))
                        LabeledContent("経度", value: origin.longitude.formatted(.number.precision(.fractionLength(7))))
                    } else {
                        Text("未設定")
                            .foregroundStyle(.secondary)
                    }
                    Button("立ち位置を設定・変更") {
                        showStatusDetails = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showCoordinateMenu = true
                        }
                    }
                }

                Section("表示") {
                    Text("点\(model.settings.showPoints ? "ON" : "OFF")・線\(model.settings.showLines ? "ON" : "OFF")・点名\(model.settings.showLabels ? "ON" : "OFF")・距離\(model.distancesEnabled ? "ON" : "OFF")")
                    if let selectedName = model.selectedPoint?.name {
                        LabeledContent("目標点", value: selectedName)
                    }
                    Text(model.renderLimitMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent(
                        "標高DEM",
                        value: model.hasElevationDEM ? "使用可能" : "未読込"
                    )
                    if model.hasElevationDEM {
                        Text(model.elevationDEMSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("位置合わせの値") {
                    LabeledContent("方位", value: String(format: "%+.1f°", model.displayHeadingOffsetDegrees))
                    LabeledContent("方位安定化", value: String(format: "%+.1f°", model.automaticHeadingCorrectionDegrees))
                    LabeledContent("高さ", value: String(format: "%+.2fm", model.effectiveDisplayPlaneOffsetMeters))
                    LabeledContent("東西", value: String(format: "%+.2fm", model.planePanEastMeters))
                    LabeledContent("南北", value: String(format: "%+.2fm", model.planePanNorthMeters))
                }
            }
            .navigationTitle("詳しい状態")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showStatusDetails = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var recordingStopOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    stopARRecording()
                } label: {
                    HStack(spacing: 7) {
                        if recordingStarting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text(recordingStarting ? "録画準備中" : "録画停止")
                    }
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.88), in: Capsule())
                }
                .disabled(recordingStarting)
                .padding(.trailing, 14)
                .padding(.bottom, 18)
            }
        }
    }

    private func startARRecording() {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            model.statusMessage = "この端末では画面録画を開始できません"
            return
        }

        recorder.isMicrophoneEnabled = false
        recordingUIHidden = true
        recordingStarting = true
        model.statusMessage = "AR動画の録画を準備中…"

        // 通常の操作UIが画面から消えた次の描画後にReplayKitを開始する。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            recorder.startRecording { error in
                DispatchQueue.main.async {
                    recordingStarting = false
                    if let error {
                        recordingUIHidden = false
                        isRecording = false
                        model.statusMessage = "録画開始エラー：\(error.localizedDescription)"
                    } else {
                        isRecording = true
                        model.statusMessage = "AR動画を録画中"
                    }
                }
            }
        }
    }

    private func stopARRecording() {
        guard isRecording else { return }
        RPScreenRecorder.shared().stopRecording { previewController, error in
            DispatchQueue.main.async {
                isRecording = false
                recordingStarting = false
                recordingUIHidden = false

                if let error {
                    model.statusMessage = "録画停止エラー：\(error.localizedDescription)"
                    return
                }

                if let previewController {
                    replayPreview = ReplayPreviewItem(controller: previewController)
                    updateARCameraActivity()
                    model.statusMessage = "録画完了：保存または共有を選択してください"
                } else {
                    model.statusMessage = "録画は終了しましたが、保存・共有画面を開けませんでした"
                }
            }
        }
    }

    private func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            model.statusMessage = "ライト非対応端末です"
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if torchEnabled {
                device.torchMode = .off
                torchEnabled = false
                model.statusMessage = "ライトOFF"
            } else if device.isTorchModeSupported(.on) {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                torchEnabled = true
                model.statusMessage = "ライトON"
            }
        } catch {
            model.statusMessage = "ライト切替エラー：\(error.localizedDescription)"
        }
    }

    private func handleSelectedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent

        if ext == "tif" || ext == "tiff" {
            model.statusMessage = "GeoTIFF読込準備中：\(fileName)"
            DispatchQueue.global(qos: .userInitiated).async {
                let started = url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }

                do {
                    let data = try Data(contentsOf: url)
                    DispatchQueue.main.async {
                        pendingGeoTIFFData = data
                        pendingGeoTIFFFileName = fileName
                        showGeoTIFFCoordinateSheet = true
                    }
                } catch {
                    DispatchQueue.main.async {
                        model.statusMessage = "GeoTIFF読込準備エラー：\(error.localizedDescription)"
                    }
                }
            }
        } else if ext == "csv" || ext == "txt" || ext == "text" {
            model.statusMessage = "CSV読込準備中：\(fileName)"
            DispatchQueue.global(qos: .userInitiated).async {
                let started = url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }

                do {
                    let data = try Data(contentsOf: url)
                    let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .shiftJIS)
                        ?? ""
                    DispatchQueue.main.async {
                        if SIMAParser.looksLikeSIMA(text) {
                            model.importFile(url: url)
                        } else {
                            pendingCSVText = text
                            pendingCSVFileName = fileName
                            showCSVImportSheet = true
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        model.statusMessage = "CSV読込準備エラー：\(error.localizedDescription)"
                    }
                }
            }
        } else {
            model.importFile(url: url)
        }
    }

}

final class ReplayPreviewItem: Identifiable {
    let id = UUID()
    let controller: RPPreviewViewController

    init(controller: RPPreviewViewController) {
        self.controller = controller
    }
}

struct ReplayPreviewSheet: UIViewControllerRepresentable {
    let previewController: RPPreviewViewController
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> RPPreviewViewController {
        previewController.previewControllerDelegate = context.coordinator
        return previewController
    }

    func updateUIViewController(_ uiViewController: RPPreviewViewController, context: Context) { }

    static func dismantleUIViewController(_ uiViewController: RPPreviewViewController, coordinator: Coordinator) {
        uiViewController.previewControllerDelegate = nil
    }

    final class Coordinator: NSObject, RPPreviewViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
            onFinish()
        }
    }
}



struct CSVImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let fileName: String
    let csvText: String
    let defaultPlaneSystem: Int
    var onApply: (CSVColumnMapping) -> Void

    private let preview: CSVPreviewData
    @State private var hasHeader: Bool
    @State private var coordinateKind: CSVCoordinateKind
    @State private var planeSystemNumber: Int
    @State private var nameColumn: Int
    @State private var firstCoordinateColumn: Int
    @State private var secondCoordinateColumn: Int
    @State private var altitudeColumn: Int

    init(fileName: String, csvText: String, defaultPlaneSystem: Int, onApply: @escaping (CSVColumnMapping) -> Void) {
        self.fileName = fileName
        self.csvText = csvText
        self.defaultPlaneSystem = defaultPlaneSystem
        self.onApply = onApply

        let preview = CSVParser.preview(text: csvText)
        self.preview = preview
        let guesses = Self.guessColumns(preview: preview)
        _hasHeader = State(initialValue: preview.hasHeader)
        _coordinateKind = State(initialValue: guesses.kind)
        _planeSystemNumber = State(initialValue: max(1, min(defaultPlaneSystem, 19)))
        _nameColumn = State(initialValue: guesses.name)
        _firstCoordinateColumn = State(initialValue: guesses.first)
        _secondCoordinateColumn = State(initialValue: guesses.second)
        _altitudeColumn = State(initialValue: guesses.altitude)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("CSV読込設定") {
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("1行目を見出しとして扱う", isOn: $hasHeader)
                    HStack(spacing: 10) {
                        ForEach(CSVCoordinateKind.allCases) { kind in
                            Button {
                                coordinateKind = kind
                            } label: {
                                HStack(spacing: 6) {
                                    if coordinateKind == kind {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                    Text(kind.label)
                                        .lineLimit(1)
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(coordinateKind == kind ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(
                                    coordinateKind == kind ? Color.accentColor : Color.secondary.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if coordinateKind == .planeXY {
                        Stepper("平面直角座標系：\(planeSystemNumber)系", value: $planeSystemNumber, in: 1...19)
                        Text("CSV全体を同じ系として扱います。列ごとには指定しません。Xは北方向、Yは東方向として扱います。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("列の割当") {
                    columnPicker(title: "点名", selection: $nameColumn, allowNone: true)
                    columnPicker(title: coordinateKind == .planeXY ? "X座標" : "緯度", selection: $firstCoordinateColumn, allowNone: false)
                    columnPicker(title: coordinateKind == .planeXY ? "Y座標" : "経度", selection: $secondCoordinateColumn, allowNone: false)
                    columnPicker(title: "標高", selection: $altitudeColumn, allowNone: true)
                }

                Section("プレビュー") {
                    if preview.rows.isEmpty {
                        Text("CSVに行がありません。")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hasHeader ? "1行目を見出しとして扱います。" : "見出しなしとして扱います。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(preview.rows.prefix(6).enumerated()), id: \.offset) { rowIndex, row in
                                    HStack(spacing: 6) {
                                        Text("\(rowIndex + 1)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, alignment: .trailing)
                                        ForEach(0..<preview.columnCount, id: \.self) { columnIndex in
                                            Text(columnIndex < row.count ? row[columnIndex] : "")
                                                .font(.caption2.monospaced())
                                                .lineLimit(1)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 3)
                                                .background(hasHeader && rowIndex == 0 ? Color.blue.opacity(0.18) : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("この割当で読み込む") {
                        let mapping = CSVColumnMapping(
                            hasHeader: hasHeader,
                            coordinateKind: coordinateKind,
                            planeSystemNumber: planeSystemNumber,
                            nameColumn: nameColumn >= 0 ? nameColumn : nil,
                            firstCoordinateColumn: firstCoordinateColumn,
                            secondCoordinateColumn: secondCoordinateColumn,
                            altitudeColumn: altitudeColumn >= 0 ? altitudeColumn : nil
                        )
                        onApply(mapping)
                        dismiss()
                    }
                    .disabled(!canApply)
                }
            }
            .navigationTitle("CSV読込")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private var canApply: Bool {
        preview.columnCount > 0
        && firstCoordinateColumn >= 0
        && secondCoordinateColumn >= 0
        && firstCoordinateColumn < preview.columnCount
        && secondCoordinateColumn < preview.columnCount
        && firstCoordinateColumn != secondCoordinateColumn
    }

    private func columnPicker(title: String, selection: Binding<Int>, allowNone: Bool) -> some View {
        Picker(title, selection: selection) {
            if allowNone {
                Text("なし").tag(-1)
            }
            ForEach(0..<preview.columnCount, id: \.self) { index in
                Text(columnLabel(index)).tag(index)
            }
        }
    }

    private func columnLabel(_ index: Int) -> String {
        guard index < preview.headers.count else { return "\(index + 1)列目" }
        return "\(index + 1)列目：\(preview.headers[index])"
    }

    private static func guessColumns(preview: CSVPreviewData) -> (kind: CSVCoordinateKind, name: Int, first: Int, second: Int, altitude: Int) {
        let headers = preview.headers.map { normalizeHeader($0) }
        func find(_ keys: [String]) -> Int? {
            for key in keys {
                if let exact = headers.firstIndex(of: key) { return exact }
            }
            for key in keys {
                if let contains = headers.firstIndex(where: { $0.contains(key) }) { return contains }
            }
            return nil
        }

        let name = find(["点名", "名称", "name", "point", "pointname", "点番号", "番号"]) ?? (preview.hasHeader ? -1 : 0)
        let altitude = find(["標高", "高さ", "高度", "alt", "altitude", "height", "z", "z座標"]) ?? (preview.columnCount >= 4 ? 3 : -1)

        if let lat = find(["緯度", "lat", "latitude"]), let lon = find(["経度", "lon", "lng", "longitude"]) {
            return (.latLon, name, lat, lon, altitude)
        }

        if let x = find(["x座標", "x", "north", "北"]), let y = find(["y座標", "y", "east", "東"]) {
            return (.planeXY, name, x, y, altitude)
        }

        if preview.hasHeader {
            let first = min(max(0, name == 0 ? 1 : 0), max(0, preview.columnCount - 1))
            let second = min(first + 1, max(0, preview.columnCount - 1))
            return (.planeXY, name, first, second, altitude)
        } else {
            if preview.columnCount >= 3 {
                return (.planeXY, 0, 1, 2, preview.columnCount >= 4 ? 3 : -1)
            } else if preview.columnCount >= 2 {
                return (.latLon, -1, 0, 1, -1)
            } else {
                return (.planeXY, -1, 0, 0, -1)
            }
        }
    }

    private static func normalizeHeader(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}


private struct PlanProjection {
    var reference: GeoCoordinate
    var centerEast: Double
    var centerNorth: Double
    var scale: Double
    var drawCenter: CGPoint

    func meters(for coordinate: GeoCoordinate) -> (east: Double, north: Double) {
        let enu = CoordinateConverter.enuMeters(from: coordinate, origin: reference)
        return (enu.east, enu.north)
    }

    func point(for coordinate: GeoCoordinate) -> CGPoint {
        let m = meters(for: coordinate)
        return CGPoint(
            x: drawCenter.x + CGFloat((m.east - centerEast) * scale),
            y: drawCenter.y - CGFloat((m.north - centerNorth) * scale)
        )
    }

    func coordinate(for point: CGPoint, name: String? = nil) -> GeoCoordinate {
        let east = (Double(point.x - drawCenter.x) / scale) + centerEast
        let north = (Double(drawCenter.y - point.y) / scale) + centerNorth
        return CoordinateConverter.coordinate(fromEast: east, north: north, origin: reference, name: name)
    }
}

struct PlanMapSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let isEmbedded: Bool
    var onReturnToAR: (() -> Void)?
    @State private var draftSelectedPoint: GeoCoordinate?
    @State private var planZoom: Double = 1.0
    @State private var planPan: CGSize = .zero
    @State private var dragStartPlanPan: CGSize = .zero
    @State private var lastMagnificationValue: CGFloat = 1.0

    init(isEmbedded: Bool = false, onReturnToAR: (() -> Void)? = nil) {
        self.isEmbedded = isEmbedded
        self.onReturnToAR = onReturnToAR
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack {
                        Canvas { context, size in
                            drawPlan(context: context, size: size)
                        }
                        .background(Color.black.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 5, coordinateSpace: .local)
                                .onChanged { value in
                                    planPan = CGSize(
                                        width: dragStartPlanPan.width + value.translation.width,
                                        height: dragStartPlanPan.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    dragStartPlanPan = planPan
                                }
                        )
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let delta = value / lastMagnificationValue
                                    planZoom = min(12.0, max(0.2, planZoom * Double(delta)))
                                    lastMagnificationValue = value
                                }
                                .onEnded { _ in
                                    lastMagnificationValue = 1.0
                                }
                        )
                        .simultaneousGesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    selectNearest(at: value.location, size: proxy.size)
                                }
                        )

                        VStack {
                            HStack {
                                planBadge
                                Spacer()
                                zoomControls
                            }
                            Spacer()
                        }
                        .padding(8)
                    }
                }
                .frame(minHeight: 360)

                VStack(alignment: .leading, spacing: 4) {
                    Text("選択中：\((draftSelectedPoint ?? model.selectedPoint)?.name ?? "なし")")
                        .font(.subheadline.weight(.semibold))
                    Text("点をタップし、目標点または現在の立ち位置として設定できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button("選択解除") { draftSelectedPoint = nil; model.selectedPoint = nil }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("立ち位置にする") {
                        if let p = draftSelectedPoint ?? model.selectedPoint {
                            model.setOriginFromPoint(p)
                        }
                        finishSelection()
                    }
                    .buttonStyle(.bordered)
                    .disabled((draftSelectedPoint ?? model.selectedPoint) == nil)

                    Button("目標点に設定") {
                        if let p = draftSelectedPoint ?? model.selectedPoint {
                            model.selectPointForAR(p)
                        }
                        finishSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((draftSelectedPoint ?? model.selectedPoint) == nil)
                }
            }
            .padding()
            .navigationTitle(isEmbedded ? "地図" : "地図で目標点を選ぶ")
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
            }
            .onAppear { draftSelectedPoint = model.selectedPoint }
        }
    }

    private func finishSelection() {
        if isEmbedded {
            onReturnToAR?()
        } else {
            dismiss()
        }
    }

    private var planBadge: some View {
        let limit = model.displayLimitResult
        let rasterText = model.rasters.isEmpty ? "" : "  画像\(model.rastersEnabled ? "ON" : "OFF")"
        return Text("表示 点\(limit.pointCount)/\(limit.totalPointCount)  線\(limit.lineCount)/\(limit.totalLineCount)  倍率\(planZoom, specifier: "%.1f")x  移動可\(rasterText)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button("−") { planZoom = max(0.2, planZoom / 1.4) }
            Button("＋") { planZoom = min(12.0, planZoom * 1.4) }
            Button("全体") { planZoom = 1.0; planPan = .zero; dragStartPlanPan = .zero }
        }
        .font(.caption2.bold())
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func projection(size: CGSize) -> PlanProjection? {
        let allCoords = model.planFeatures.flatMap { $0.coordinates } + model.rasters.flatMap { $0.corners }
        guard let reference = model.origin ?? allCoords.first else { return nil }
        var eastValues: [Double] = []
        var northValues: [Double] = []
        for coord in allCoords {
            let enu = CoordinateConverter.enuMeters(from: coord, origin: reference)
            eastValues.append(enu.east)
            northValues.append(enu.north)
        }
        if model.origin != nil {
            eastValues.append(0)
            northValues.append(0)
        }
        guard let minE = eastValues.min(), let maxE = eastValues.max(), let minN = northValues.min(), let maxN = northValues.max() else { return nil }
        let width = max(maxE - minE, 1)
        let height = max(maxN - minN, 1)
        let margin = 34.0
        let scaleX = max((Double(size.width) - margin * 2) / width, 0.01)
        let scaleY = max((Double(size.height) - margin * 2) / height, 0.01)
        return PlanProjection(
            reference: reference,
            centerEast: (minE + maxE) / 2,
            centerNorth: (minN + maxN) / 2,
            scale: min(scaleX, scaleY) * planZoom,
            drawCenter: CGPoint(x: size.width / 2 + planPan.width, y: size.height / 2 + planPan.height)
        )
    }

    private func drawPlan(context: GraphicsContext, size: CGSize) {
        guard let projection = projection(size: size) else {
            let text = Text("表示できる点・線がありません").font(.caption).foregroundColor(.white)
            context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
            return
        }

        drawRasters(context: context, projection: projection)

        for feature in model.planFeatures where feature.kind == .line || feature.kind == .polygon {
            let points = feature.coordinates.map { projection.point(for: $0) }
            guard points.count >= 2 else { continue }
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            if feature.kind == .polygon { path.closeSubpath() }
            context.stroke(path, with: .color(.cyan.opacity(0.86)), lineWidth: CGFloat(model.settings.planLineWidth))
        }

        for feature in model.planFeatures where feature.kind == .point {
            for coord in feature.coordinates {
                drawPoint(coord, projection: projection, context: context, color: .yellow, size: model.settings.planPointSize)
            }
        }

        // ライン・ポリゴンの頂点も選択しやすいよう小さく表示する。
        for feature in model.planFeatures where feature.kind != .point {
            for coord in feature.coordinates {
                drawPoint(coord, projection: projection, context: context, color: .white.opacity(0.72), size: max(model.settings.planPointSize * 0.65, 3))
            }
        }

        if let selected = draftSelectedPoint ?? model.selectedPoint {
            drawPoint(selected, projection: projection, context: context, color: .red, size: model.settings.planPointSize * 1.9)
            let p = projection.point(for: selected)
            context.draw(Text(selected.name ?? "選択点").font(.caption2.bold()).foregroundColor(.white), at: CGPoint(x: p.x + 8, y: p.y - 10), anchor: .leading)
        }

        if let origin = model.origin {
            let p = projection.point(for: origin)
            var cross = Path()
            cross.move(to: CGPoint(x: p.x - 8, y: p.y))
            cross.addLine(to: CGPoint(x: p.x + 8, y: p.y))
            cross.move(to: CGPoint(x: p.x, y: p.y - 8))
            cross.addLine(to: CGPoint(x: p.x, y: p.y + 8))
            context.stroke(cross, with: .color(.green), lineWidth: 2)
            context.draw(Text("現在地").font(.caption2.bold()).foregroundColor(.green), at: CGPoint(x: p.x + 8, y: p.y + 8), anchor: .topLeading)
        }
    }

    private func drawRasters(context: GraphicsContext, projection: PlanProjection) {
        guard model.rastersEnabled else { return }
        for raster in model.rasters {
            let points = raster.corners.map { projection.point(for: $0) }
            guard points.count == 4 else { continue }
            let minX = points.map(\.x).min() ?? 0
            let maxX = points.map(\.x).max() ?? 0
            let minY = points.map(\.y).min() ?? 0
            let maxY = points.map(\.y).max() ?? 0
            let rect = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
            context.draw(Image(uiImage: raster.image), in: rect)

            var outline = Path()
            outline.move(to: points[0])
            for point in points.dropFirst() { outline.addLine(to: point) }
            outline.closeSubpath()
            context.stroke(outline, with: .color(.orange.opacity(0.85)), lineWidth: 1.5)
        }
    }

    private func drawPoint(_ coord: GeoCoordinate, projection: PlanProjection, context: GraphicsContext, color: Color, size: Double) {
        let p = projection.point(for: coord)
        let r = CGFloat(size)
        context.fill(Path(ellipseIn: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r)), with: .color(color))
    }

    private func selectNearest(at location: CGPoint, size: CGSize) {
        guard let projection = projection(size: size) else { return }
        let candidates = model.planFeatures.flatMap { $0.coordinates }
        if candidates.isEmpty {
            if model.rastersEnabled, isInsideAnyRaster(location, projection: projection) {
                draftSelectedPoint = projection.coordinate(for: location, name: "GeoTIFF選択点")
            }
            return
        }
        let nearest = candidates.min { a, b in
            let pa = projection.point(for: a)
            let pb = projection.point(for: b)
            return hypot(pa.x - location.x, pa.y - location.y) < hypot(pb.x - location.x, pb.y - location.y)
        }
        guard let nearest else { return }
        let p = projection.point(for: nearest)
        let threshold = CGFloat(max(28.0, model.settings.planPointSize * 2.4))
        if hypot(p.x - location.x, p.y - location.y) <= threshold {
            draftSelectedPoint = nearest
        } else if model.rastersEnabled, isInsideAnyRaster(location, projection: projection) {
            draftSelectedPoint = projection.coordinate(for: location, name: "GeoTIFF選択点")
        }
    }

    private func isInsideAnyRaster(_ point: CGPoint, projection: PlanProjection) -> Bool {
        guard model.rastersEnabled else { return false }
        for raster in model.rasters {
            let points = raster.corners.map { projection.point(for: $0) }
            guard points.count == 4 else { continue }
            let minX = points.map(\.x).min() ?? 0
            let maxX = points.map(\.x).max() ?? 0
            let minY = points.map(\.y).min() ?? 0
            let maxY = points.map(\.y).max() ?? 0
            if CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -8, dy: -8).contains(point) {
                return true
            }
        }
        return false
    }
}


struct LayerManagerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let isEmbedded: Bool
    var onAddData: (() -> Void)?

    init(isEmbedded: Bool = false, onAddData: (() -> Void)? = nil) {
        self.isEmbedded = isEmbedded
        self.onAddData = onAddData
    }

    var body: some View {
        NavigationStack {
            List {
                if let onAddData {
                    Section {
                        Button(action: onAddData) {
                            Label("データを追加", systemImage: "doc.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowBackground(Color.clear)

                        Text("KML・KMZ・CSV・SIMA・GeoTIFF・基盤地図情報DEMに対応しています。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    }
                }

                if model.layers.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "読み込んだデータはありません",
                            systemImage: "square.stack.3d.up.slash",
                            description: Text("上の「データを追加」から、表示するファイルを選んでください。")
                        )
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("読み込んだデータ") {
                        ForEach(model.layers) { layer in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(layer.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(layerSummary(layer))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                Button(layer.isVisible ? "表示中" : "非表示") {
                                    model.setLayerVisible(layer.id, isVisible: !layer.isVisible)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("削除", role: .destructive) {
                                    model.deleteLayer(layer.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 3)
                        }
                    }

                    Section("説明") {
                        Text("読み込んだファイルをレイヤーとして管理します。間違って読み込んだデータは削除でき、不要なデータは非表示にできます。表示制限・地図・AR表示は、表示中のデータだけを対象にします。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isEmbedded ? "データ" : "読み込んだデータ")
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
            }
        }
    }

    private func layerSummary(_ layer: ImportedDataLayer) -> String {
        var parts: [String] = []
        if layer.pointCount > 0 { parts.append("点\(layer.pointCount)") }
        if layer.lineCount > 0 { parts.append("線分\(layer.lineCount)") }
        if layer.rasterCount > 0 { parts.append("画像\(layer.rasterCount)") }
        if layer.elevationGridCount > 0 { parts.append("DEM\(layer.elevationGridCount)") }
        return parts.isEmpty ? "要素なし" : parts.joined(separator: " / ")
    }
}

struct DisplaySettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var settingsPage: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        settingsPageButton(title: "基本", page: 0)
                        settingsPageButton(title: "詳細", page: 1)
                    }
                }

                if settingsPage == 0 {
                    basicSettings
                } else {
                    detailedSettings
                }

                Section {
                    Button("設定を初期値に戻す", role: .destructive) { model.resetDisplaySettings() }
                }
            }
            .navigationTitle("表示設定")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private func settingsPageButton(title: String, page: Int) -> some View {
        Button {
            settingsPage = page
        } label: {
            HStack(spacing: 6) {
                if settingsPage == page {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(settingsPage == page ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                settingsPage == page ? Color.accentColor : Color.secondary.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var basicSettings: some View {
        Section("表示するもの") {
            Toggle("点を表示", isOn: $model.settings.showPoints)
            Toggle("線を表示", isOn: $model.settings.showLines)
            Toggle("点名を表示", isOn: $model.settings.showLabels)
            Toggle("距離を表示", isOn: $model.distancesEnabled)
            Toggle("柱を表示", isOn: $model.pillarsEnabled)
            Toggle("GeoTIFF画像を表示", isOn: $model.rastersEnabled)
                .disabled(model.rasters.isEmpty)
        }

        Section("AR表示を安定させる") {
            Toggle("方位を安定させる（コンパス使用）", isOn: $model.settings.headingStabilizationEnabled)
            Text("森林や草地などで、端末を動かしていないのに表示が回る現象を軽減します。コンパスが乱れる場所ではOFFにできます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detailedSettings: some View {
        Section("詳細：表示範囲と件数") {
            Stepper("最大表示ポイント数：\(model.settings.maxDisplayPoints)", value: $model.settings.maxDisplayPoints, in: 0...10000, step: 50)
            Stepper("最大表示線分数：\(model.settings.maxDisplayLines)", value: $model.settings.maxDisplayLines, in: 0...5000, step: 25)
            Stepper("最大点名表示数：\(model.settings.maxLabelCount)", value: $model.settings.maxLabelCount, in: 0...500, step: 5)
            VStack(alignment: .leading) {
                Text(model.settings.displayRadiusMeters <= 0 ? "表示半径：制限なし" : "表示半径：\(Int(model.settings.displayRadiusMeters))m")
                Slider(value: $model.settings.displayRadiusMeters, in: 0...2000, step: 25)
            }
            VStack(alignment: .leading) {
                Text(model.settings.labelDistanceMeters <= 0 ? "点名表示距離：制限なし" : "点名表示距離：\(Int(model.settings.labelDistanceMeters))m")
                Slider(value: $model.settings.labelDistanceMeters, in: 0...1000, step: 10)
            }
        }

        Section("詳細：AR表示サイズ") {
            sliderRow(title: "点の大きさ", value: $model.settings.arPointSize, range: 0.005...1.0, step: 0.005, unit: "m")
            sliderRow(title: "選択点の球体", value: $model.settings.arSelectedSphereSize, range: 0.01...1.5, step: 0.005, unit: "m")
            sliderRow(title: "ラインの太さ", value: $model.settings.arLineWidth, range: 0.001...0.3, step: 0.001, unit: "m")
            Toggle("距離に応じて見やすい大きさにする", isOn: $model.settings.farMinimumSizeEnabled)
            sliderRow(title: "遠方ポイント最小サイズ", value: $model.settings.farPointMinSize, range: 0.005...0.8, step: 0.005, unit: "m")
                .disabled(!model.settings.farMinimumSizeEnabled)
            sliderRow(title: "遠方ライン最小幅", value: $model.settings.farLineMinWidth, range: 0.001...0.25, step: 0.001, unit: "m")
                .disabled(!model.settings.farMinimumSizeEnabled)
        }

        Section("詳細：平面図表示サイズ") {
            sliderRow(title: "平面図の点", value: $model.settings.planPointSize, range: 2...28, step: 1, unit: "pt")
            sliderRow(title: "平面図の線幅", value: $model.settings.planLineWidth, range: 0.5...8, step: 0.5, unit: "pt")
        }

        Section("詳細：GeoTIFF表示") {
            VStack(alignment: .leading) {
                Text("GeoTIFF不透明度：\(Int(model.settings.rasterOpacity * 100))%")
                Slider(value: $model.settings.rasterOpacity, in: 0...1, step: 0.05)
            }
            Text("GeoTIFF表示は簡易対応です。大きな画像は表示用に最大辺2048px程度へ縮小します。一部のGeoTIFFでは位置や表示が正しくない場合があります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("詳細：高さ") {
            Toggle("高さ情報を使う（概略）", isOn: $model.settings.useRelativeAltitude)
            VStack(alignment: .leading) {
                Text(model.settings.relativeAltitudeLimitMeters <= 0 ? "表示する高さ差：制限なし" : "表示する高さ差：±\(Int(model.settings.relativeAltitudeLimitMeters))mまで")
                Slider(value: $model.settings.relativeAltitudeLimitMeters, in: 0...300, step: 5)
            }

            Toggle("境界線をDEMの地形に沿わせる", isOn: $model.settings.boundaryTerrainFollowEnabled)
                .disabled(!model.hasElevationDEM)

            VStack(alignment: .leading, spacing: 6) {
                Text("境界線の標高を読む間隔：\(Int(model.settings.demSampleSpacingMeters))m")
                Slider(value: $model.settings.demSampleSpacingMeters, in: 1...50, step: 1)
            }
            .disabled(!model.hasElevationDEM || !model.settings.boundaryTerrainFollowEnabled)

            if model.hasElevationDEM {
                Text("ONにすると、境界線の途中にもDEMの標高を当てはめ、地形の起伏に沿って表示します。間隔を小さくすると細かな起伏を表現できますが、線が多い場合は処理が重くなります。通常は5mがおすすめです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("この機能を使うには、データ画面から標高GeoTIFF、または基盤地図情報のDEM（XML・ZIP）を追加してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("「高さ情報を使う」をONにすると、現在地付近を高さ0mとして点や線を上下に表示します。DEMがない場所では、ファイルに含まれる標高を使用します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("詳細：LiDAR") {
            Toggle("LiDAR補助", isOn: $model.lidarEnabled)
            Toggle("物体の後ろを薄く表示", isOn: $model.settings.lidarFadeBehindObjectsEnabled)
                .disabled(!model.lidarEnabled)
            VStack(alignment: .leading) {
                Text("物体の後ろの不透明度：\(Int(model.settings.lidarBehindOpacity * 100))%")
                Slider(value: $model.settings.lidarBehindOpacity, in: 0.05...0.85, step: 0.05)
            }
            .disabled(!model.lidarEnabled || !model.settings.lidarFadeBehindObjectsEnabled)
            Text(model.lidarSupported ? "深度判定は毎秒数回、要素を分割して処理します。深度を取得できない場所は通常表示です。" : "LiDAR非対応端末では自動的に無効になります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title)：\(value.wrappedValue, specifier: "%.2f")\(unit)")
            Slider(value: value, in: range, step: step)
        }
    }
}

struct LatLonInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    var onApply: (Double, Double) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("立ち位置を緯度経度で指定") {
                    TextField("緯度 例：36.321234", text: $latitudeText).keyboardType(.numbersAndPunctuation)
                    TextField("経度 例：139.012345", text: $longitudeText).keyboardType(.numbersAndPunctuation)
                }
                Section {
                    Button("適用") {
                        guard let lat = Double(latitudeText), let lon = Double(longitudeText) else { return }
                        onApply(lat, lon)
                        dismiss()
                    }
                }
            }
            .navigationTitle("緯度経度")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

struct PlaneInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var systemNumber: Int
    @State private var xText = ""
    @State private var yText = ""
    var onApply: (Int, Double, Double) -> Void

    init(initialSystem: Int, onApply: @escaping (Int, Double, Double) -> Void) {
        _systemNumber = State(initialValue: initialSystem)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("平面直角座標系") {
                    Stepper("系番号：\(systemNumber)系", value: $systemNumber, in: 1...19)
                    Text("プルダウンではなくステッパーで選択します。Xは北方向、Yは東方向として扱います。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("立ち位置を座標で指定") {
                    TextField("X座標 例：95487.627", text: $xText).keyboardType(.numbersAndPunctuation)
                    TextField("Y座標 例：-26767.103", text: $yText).keyboardType(.numbersAndPunctuation)
                }
                Section {
                    Button("適用") {
                        guard let x = Double(xText), let y = Double(yText) else { return }
                        onApply(systemNumber, x, y)
                        dismiss()
                    }
                }
            }
            .navigationTitle("平面直角座標")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

struct GeoTIFFCoordinateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var purpose: GeoTIFFImportPurpose = .backgroundImage
    @State private var usePlaneRectangular = true
    @State private var systemNumber: Int
    var onApply: (GeoTIFFImportPurpose, GeoTIFFCoordinateMode) -> Void

    init(initialSystem: Int, onApply: @escaping (GeoTIFFImportPurpose, GeoTIFFCoordinateMode) -> Void) {
        _systemNumber = State(initialValue: initialSystem)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("このGeoTIFFの用途") {
                    HStack(spacing: 10) {
                        geoTIFFPurposeButton(
                            title: "背景画像",
                            systemImage: "map",
                            value: .backgroundImage
                        )
                        geoTIFFPurposeButton(
                            title: "標高DEM",
                            systemImage: "mountain.2",
                            value: .elevationDEM
                        )
                    }

                    switch purpose {
                    case .backgroundImage:
                        Text("地図や航空写真などを、ARと平面図の背景画像として表示します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .elevationDEM:
                        Text("画素に記録された標高を読み取り、境界線を地形の起伏に沿わせます。通常の写真や地図画像はこちらを選ばないでください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("GeoTIFFの座標系") {
                    HStack(spacing: 8) {
                        Button("平面直角座標系") { usePlaneRectangular = true }
                            .buttonStyle(.borderedProminent)
                            .tint(usePlaneRectangular ? .blue : .gray)
                        Button("緯度経度") { usePlaneRectangular = false }
                            .buttonStyle(.borderedProminent)
                            .tint(usePlaneRectangular ? .gray : .blue)
                    }

                    if usePlaneRectangular {
                        Stepper("系番号：\(systemNumber)系", value: $systemNumber, in: 1...19)
                        Text("GeoTIFF内のEPSG情報は使わず、ここで指定した座標系として解釈します。GeoTIFFのX=東方向、Y=北方向として扱います。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("GeoTIFFのモデル座標を、X=経度、Y=緯度として扱います。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(purpose == .backgroundImage ? "背景画像として読み込む" : "標高DEMとして読み込む") {
                        onApply(
                            purpose,
                            usePlaneRectangular ? .planeRectangular(system: systemNumber) : .geographic
                        )
                        dismiss()
                    }
                }
            }
            .navigationTitle("GeoTIFF読込")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private func geoTIFFPurposeButton(
        title: String,
        systemImage: String,
        value: GeoTIFFImportPurpose
    ) -> some View {
        Button {
            purpose = value
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(purpose == value ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                purpose == value ? Color.accentColor : Color.secondary.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }
}

struct PointSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let points: [GeoCoordinate]
    var onSelect: (GeoCoordinate) -> Void
    @State private var searchText = ""

    private var filteredPoints: [GeoCoordinate] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return points }
        return points.filter { point in
            let name = point.name ?? ""
            return name.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredPoints) { point in
                Button {
                    onSelect(point)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(point.name ?? "名称なし")
                        Text("\(point.latitude.formatted(.number.precision(.fractionLength(7)))), \(point.longitude.formatted(.number.precision(.fractionLength(7))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "点名を検索")
            .navigationTitle("点から立ち位置を選ぶ")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .overlay {
                if filteredPoints.isEmpty {
                    ContentUnavailableView("該当する点名がありません", systemImage: "magnifyingglass")
                }
            }
        }
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("はじめて使う") {
                    Label("1. 「データ」で表示するファイルを追加します。", systemImage: "1.circle")
                    Label("2. AR画面で立ち位置を設定します。通常は「iPhoneの現在位置を使う」を選びます。", systemImage: "2.circle")
                    Label("3. 必要に応じて「地図」で目標点を選び、AR画面の「位置合わせ」で表示を調整します。", systemImage: "3.circle")
                }

                Section("3つの画面") {
                    Text("「AR」では現地映像に点・線・GeoTIFFを重ね、写真や動画を記録できます。")
                    Text("「地図」ではデータを平面的に確認し、目標点または立ち位置を選べます。")
                    Text("「データ」ではファイルの追加、表示・非表示、削除ができます。")
                }

                Section("位置合わせ") {
                    Text("「立ち位置」は、AR表示の基準となる現在立っている位置です。iPhoneの現在位置、読み込んだ点、緯度経度、平面直角座標から設定できます。")
                    Text("AR画面左下の丸いパッドを、現在位置を移動したい方向へ倒すと、ゲームの移動操作と同じ感覚で前後左右を調整できます。上へ倒すと前進し、地物表示は反対へ動きます。「微／大」で感度を切り替え、位置と高さが合ったら「中心を更新」を押します。表示を動かさず、現在の位置と高さが新しい基準として確定されます。「0」は水平調整だけをリセットします。")
                    Text("パッドは×で隠せます。「表示項目」または右上の「…」から再表示できます。方位はAR画面の横スワイプ、高さは縦スワイプでも調整できます。")
                }

                Section("画面を人に見せるとき") {
                    Text("右上の目に斜線が付いたボタンを押すと、タブバーや調整・撮影ボタンをまとめて隠せます。右上に残る小さな目のボタンで操作UIを戻します。")
                    Text("写真と動画は、AR画面右下の白いカメラボタンと赤い動画ボタンから直接操作します。横に滑らせる切替操作は使用しません。")
                }

                Section("対応データ") {
                    Text("KML / KMZ / CSV / SIMA / GeoTIFF / 基盤地図情報DEM")
                    Text("GeoTIFFを選ぶと、最初に用途を確認します。地図や航空写真は「背景画像」、標高値が入ったGeoTIFFは「標高DEM」を選んでください。背景画像は表示用に最大辺2048px程度へ縮小し、不透明度の初期値は35%です。")
                    Text("国土地理院の基盤地図情報DEMは、ダウンロードしたZIPのまま、または中のXMLを読み込めます。表示設定の「境界線をDEMの地形に沿わせる」をONにすると、境界線の途中にも標高を当てはめます。")
                    Text("高さは通常の初期状態では使いません。DEMを読み込むと自動でONになります。手動で使う場合は表示設定の「高さ情報を使う（概略）」をONにします。現在地付近の標高を0mとして表示し、DEMがない場所ではファイルに含まれる標高を使用します。")
                }

                Section("LiDARと方位安定化") {
                    Text("LiDAR対応端末では「物体の後ろを薄く表示」を利用できます。深度を取得できない場所は通常表示になります。")
                    Text("方位安定化は、コンパスを使って森林や草地での表示回転を軽減します。コンパスが乱れる場所ではOFFにできます。")
                }

                Section("表示が合わないとき") {
                    Text("まず立ち位置を確認し、その後に前後左右、方位、高さの順で調整してください。")
                    Text("大量データで動作が重い場合は、詳細設定で最大表示数や表示半径を小さくしてください。設定はアプリ再起動後も保持されます。")
                }

                Section("プライバシー") {
                    if let privacyPolicyURL = URL(string: "https://github.com/early277/ARCoordinateViewer/blob/main/PrivacyPolicy.md") {
                        Link(destination: privacyPolicyURL) {
                            Label("プライバシーポリシー", systemImage: "hand.raised")
                        }
                    }
                }
            }
            .navigationTitle("使い方・ヘルプ")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
