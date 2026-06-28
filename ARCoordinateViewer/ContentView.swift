import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

private enum ARAdjustmentAxis {
    case heading
    case height
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var locationManager: LocationManager

    @State private var showImporter = false
    @State private var showLatLonInput = false
    @State private var showPlaneInput = false
    @State private var showPointSelection = false
    @State private var showPlanMap = false
    @State private var showSettings = false
    @State private var showLayerManager = false
    @State private var showHelp = false
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
    @State private var horizontalPadDragOffset: CGSize = .zero
    @State private var horizontalPadIsDragging = false

    private var supportedImportTypes: [UTType] {
        [
            UTType(filenameExtension: "kml") ?? .xml,
            UTType(filenameExtension: "kmz") ?? .data,
            UTType(filenameExtension: "sim") ?? .plainText,
            UTType(filenameExtension: "sima") ?? .plainText,
            UTType(filenameExtension: "tif") ?? .tiff,
            UTType(filenameExtension: "tiff") ?? .tiff,
            .commaSeparatedText,
            .plainText,
            .text,
            .xml,
            .tiff,
            .data
        ]
    }

    var body: some View {
        ZStack {
            ARRendererView()
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(arAdjustmentGesture)

            screenLabelsOverlay

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    horizontalMovePad
                        .padding(.leading, 12)
                        .padding(.bottom, 58)
                    Spacer()
                }
            }

            VStack(spacing: 0) {
                miniTopHUD
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                quickGuideCard
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                Spacer(minLength: 0)

                compactBottomBar
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
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
        .sheet(isPresented: $showSettings) {
            DisplaySettingsSheet()
        }
        .sheet(isPresented: $showLayerManager) {
            LayerManagerSheet()
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet()
        }
        .sheet(isPresented: $showGeoTIFFCoordinateSheet) {
            GeoTIFFCoordinateSheet(initialSystem: model.planeSystemNumber) { mode in
                if let data = pendingGeoTIFFData {
                    model.importGeoTIFF(data: data, fileName: pendingGeoTIFFFileName, coordinateMode: mode)
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
        .confirmationDialog("現在地の指定方法", isPresented: $showCoordinateMenu, titleVisibility: .visible) {
            Button("緯度経度を手入力") { showLatLonInput = true }
            Button("平面直角座標を手入力") { showPlaneInput = true }
            Button("キャンセル", role: .cancel) { }
        }
        .onAppear {
            locationManager.requestAuthorizationIfNeeded()
            updateARCameraActivity()
        }
        .onChange(of: showImporter) { _ in updateARCameraActivity() }
        .onChange(of: showLatLonInput) { _ in updateARCameraActivity() }
        .onChange(of: showPlaneInput) { _ in updateARCameraActivity() }
        .onChange(of: showPointSelection) { _ in updateARCameraActivity() }
        .onChange(of: showPlanMap) { _ in updateARCameraActivity() }
        .onChange(of: showSettings) { _ in updateARCameraActivity() }
        .onChange(of: showLayerManager) { _ in updateARCameraActivity() }
        .onChange(of: showHelp) { _ in updateARCameraActivity() }
        .onChange(of: showCoordinateMenu) { _ in updateARCameraActivity() }
        .onChange(of: showGeoTIFFCoordinateSheet) { _ in updateARCameraActivity() }
        .onChange(of: showCSVImportSheet) { _ in updateARCameraActivity() }
    }

    private var shouldPauseARCamera: Bool {
        showImporter || showLatLonInput || showPlaneInput || showPointSelection || showPlanMap || showSettings || showLayerManager || showHelp || showCoordinateMenu || showGeoTIFFCoordinateSheet || showCSVImportSheet
    }

    private func updateARCameraActivity() {
        model.arCameraActive = !shouldPauseARCamera
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
                    dragStartPlaneOffsetMeters = model.displayPlaneOffsetMeters
                }

                guard let axis = adjustmentAxis else { return }
                switch axis {
                case .heading:
                    let sensitivityDegreesPerPoint = 0.18
                    model.setHeadingOffsetPreservingCurrentCenter(dragStartHeadingDegrees - Double(value.translation.width) * sensitivityDegreesPerPoint)
                case .height:
                    let sensitivityMetersPerPoint = 0.012
                    let next = dragStartPlaneOffsetMeters - Double(value.translation.height) * sensitivityMetersPerPoint
                    model.displayPlaneOffsetMeters = min(100.0, max(-100.0, next))
                }
            }
            .onEnded { _ in
                if let axis = adjustmentAxis {
                    switch axis {
                    case .heading:
                        model.statusMessage = "方位補正：\(model.displayHeadingOffsetDegrees.formatted(.number.precision(.fractionLength(1))))°"
                    case .height:
                        model.statusMessage = "表示高さ：\(model.displayPlaneOffsetMeters.formatted(.number.precision(.fractionLength(2))))m"
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
                    .position(x: label.x, y: adjustedLabelY(for: label))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var miniTopHUD: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("AR地図")
                        .font(.caption.bold())
                    Text(model.arStatusMessage)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Text(topStatusText)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(.secondary)

                Text("点\(model.settings.showPoints ? "ON" : "OFF") / 線\(model.settings.showLines ? "ON" : "OFF") / 点名\(model.settings.showLabels ? "ON" : "OFF") / 距離\(model.distancesEnabled ? "ON" : "OFF")")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(.secondary)


                Text("補正：方位 \(model.displayHeadingOffsetDegrees, specifier: "%+.1f")° / 高さ \(model.displayPlaneOffsetMeters, specifier: "%+.2f")m")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var topStatusText: String {
        if let origin = model.origin {
            let lat = origin.latitude.formatted(.number.precision(.fractionLength(7)))
            let lon = origin.longitude.formatted(.number.precision(.fractionLength(7)))
            let renderText = model.renderLimitMessage.isEmpty ? model.statusMessage : model.renderLimitMessage
            let rasterText = model.rasters.isEmpty ? "" : " / 画像\(model.rastersEnabled ? "ON" : "OFF")"
            let selected = model.selectedPoint?.name.map { " / 選択：\($0)" } ?? ""
            return "現在地：\(origin.name ?? "設定済み")  \(lat), \(lon) / \(renderText)\(rasterText)\(selected)"
        } else {
            return "現在地未設定 / \(model.statusMessage)"
        }
    }

    private var quickGuideCard: some View {
        HStack(spacing: 8) {
            Image(systemName: quickGuideIcon)
                .font(.caption.weight(.semibold))
            Text(quickGuideText)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.74)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var quickGuideIcon: String {
        if model.features.isEmpty && model.rasters.isEmpty { return "1.circle" }
        if model.origin == nil { return "2.circle" }
        if model.selectedPoint == nil && !model.importedPointList.isEmpty { return "3.circle" }
        return "checkmark.circle"
    }

    private var quickGuideText: String {
        if model.features.isEmpty && model.rasters.isEmpty {
            return "次の操作：読込を押してKML・KMZ・CSV・SIMA・GeoTIFFを選びます。"
        }
        if model.origin == nil {
            return "次の操作：現在地取得、座標指定、または点から現在地を設定します。"
        }
        if model.selectedPoint == nil && !model.importedPointList.isEmpty {
            return "次の操作：平面図で確認し、目標点をタップしてARへ適用できます。"
        }
        return "AR表示中：左下パッドで水平移動、横スワイプで方位、縦スワイプで高さを調整できます。"
    }

    private var horizontalMovePad: some View {
        VStack(alignment: .center, spacing: 5) {
            HStack(spacing: 4) {
                Button(horizontalPadFineMode ? "微" : "大") {
                    horizontalPadFineMode.toggle()
                    model.statusMessage = horizontalPadFineMode ? "水平移動：微調整モード" : "水平移動：大移動モード"
                }
                .font(.caption2.weight(.bold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)

                Button("中心") {
                    model.updateOriginToCurrentPanCenter()
                }
                .font(.caption2.weight(.bold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            ZStack {
                Circle()
                    .fill(.black.opacity(0.10))
                    .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
                    .frame(width: 82, height: 82)

                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))

                Circle()
                    .fill(horizontalPadFineMode ? Color.cyan.opacity(0.72) : Color.orange.opacity(0.76))
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    .frame(width: 28, height: 28)
                    .offset(clampedHorizontalPadOffset)
                    .shadow(radius: 2)
            }
            .gesture(horizontalPadGesture)

            HStack(spacing: 4) {
                Text(horizontalPadFineMode ? "1cm" : "8cm")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.82))
                Button("0") {
                    model.resetPlanePan()
                    model.statusMessage = "水平移動をリセットしました"
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .frame(width: 96)
        .padding(6)
        .background(Color.clear, in: RoundedRectangle(cornerRadius: 12))
    }

    private var clampedHorizontalPadOffset: CGSize {
        let maxRadius: CGFloat = 27
        let length = hypot(horizontalPadDragOffset.width, horizontalPadDragOffset.height)
        guard length > maxRadius else { return horizontalPadDragOffset }
        let scale = maxRadius / length
        return CGSize(width: horizontalPadDragOffset.width * scale, height: horizontalPadDragOffset.height * scale)
    }

    private var horizontalPadGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !horizontalPadIsDragging {
                    horizontalPadIsDragging = true
                    horizontalPadDragStartEastMeters = model.planePanEastMeters
                    horizontalPadDragStartNorthMeters = model.planePanNorthMeters
                }
                horizontalPadDragOffset = value.translation
                let metersPerPoint = horizontalPadFineMode ? 0.01 : 0.08
                model.setPlanePanFromScreenDrag(
                    startEast: horizontalPadDragStartEastMeters,
                    startNorth: horizontalPadDragStartNorthMeters,
                    translation: value.translation,
                    metersPerPoint: metersPerPoint
                )
            }
            .onEnded { _ in
                model.statusMessage = "水平移動：東西 \(model.planePanEastMeters.formatted(.number.precision(.fractionLength(2))))m / 南北 \(model.planePanNorthMeters.formatted(.number.precision(.fractionLength(2))))m"
                horizontalPadDragOffset = .zero
                horizontalPadIsDragging = false
            }
    }

    private var compactBottomBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Button("読込") {
                    model.arCameraActive = false
                    showImporter = true
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("現在地取得") { locationManager.requestCurrentLocationOnce() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("座標指定") { showCoordinateMenu = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("点から現在地") { showPointSelection = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.importedPointList.isEmpty)

                Button("平面図で選択") { showPlanMap = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.features.isEmpty && model.rasters.isEmpty)

                Button("レイヤー") { showLayerManager = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.layers.isEmpty)

                Button("設定") { showSettings = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Menu("表示") {
                    Toggle("ポイント表示", isOn: $model.settings.showPoints)
                    Toggle("ライン表示", isOn: $model.settings.showLines)
                    Toggle("点名表示", isOn: $model.settings.showLabels)
                    Toggle("距離表示", isOn: $model.distancesEnabled)
                    Toggle("柱表示", isOn: $model.pillarsEnabled)
                    Toggle("画像表示", isOn: $model.rastersEnabled).disabled(model.rasters.isEmpty)
                    Toggle("LiDAR補助", isOn: $model.lidarEnabled)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(torchEnabled ? "ライトON" : "ライト") { toggleTorch() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
                    Picker("座標形式", selection: $coordinateKind) {
                        ForEach(CSVCoordinateKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

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
    @State private var draftSelectedPoint: GeoCoordinate?
    @State private var planZoom: Double = 1.0
    @State private var planPan: CGSize = .zero
    @State private var dragStartPlanPan: CGSize = .zero
    @State private var lastMagnificationValue: CGFloat = 1.0

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
                    Text("点をタップして選択できます。AR強調表示または現在地として適用できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button("選択解除") { draftSelectedPoint = nil; model.selectedPoint = nil }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("現在地にする") {
                        if let p = draftSelectedPoint ?? model.selectedPoint {
                            model.setOriginFromPoint(p)
                        }
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .disabled((draftSelectedPoint ?? model.selectedPoint) == nil)

                    Button("ARへ適用") {
                        if let p = draftSelectedPoint ?? model.selectedPoint {
                            model.selectPointForAR(p)
                        }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((draftSelectedPoint ?? model.selectedPoint) == nil)
                }
            }
            .padding()
            .navigationTitle("平面図で選択")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .onAppear { draftSelectedPoint = model.selectedPoint }
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

    var body: some View {
        NavigationStack {
            List {
                if model.layers.isEmpty {
                    Section {
                        Text("読込済みデータはありません。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("読込済みデータ") {
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
                        Text("読み込んだファイルをレイヤーとして管理します。間違って読み込んだデータは削除できます。不要なデータは非表示にできます。表示制限・平面図・AR表示は、表示中のレイヤーだけを対象にします。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("レイヤー")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private func layerSummary(_ layer: ImportedDataLayer) -> String {
        var parts: [String] = []
        if layer.pointCount > 0 { parts.append("点\(layer.pointCount)") }
        if layer.lineCount > 0 { parts.append("線分\(layer.lineCount)") }
        if layer.rasterCount > 0 { parts.append("画像\(layer.rasterCount)") }
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
                    Picker("設定区分", selection: $settingsPage) {
                        Text("基本").tag(0)
                        Text("詳細").tag(1)
                    }
                    .pickerStyle(.segmented)
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

    @ViewBuilder
    private var basicSettings: some View {
        Section("基本：表示ON/OFF") {
            Toggle("ポイント表示", isOn: $model.settings.showPoints)
            Toggle("ライン表示", isOn: $model.settings.showLines)
            Toggle("点名表示", isOn: $model.settings.showLabels)
        }

        Section("基本：表示制限") {
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
    }

    @ViewBuilder
    private var detailedSettings: some View {
        Section("詳細：AR表示サイズ") {
            sliderRow(title: "点の大きさ", value: $model.settings.arPointSize, range: 0.03...1.0, step: 0.01, unit: "m")
            sliderRow(title: "選択点の球体", value: $model.settings.arSelectedSphereSize, range: 0.05...1.5, step: 0.01, unit: "m")
            sliderRow(title: "ラインの太さ", value: $model.settings.arLineWidth, range: 0.005...0.3, step: 0.005, unit: "m")
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
            Text("現在地付近を高さ0mとして、取り込んだ標高に合わせて点や線を上下に表示します。標高0・標高なしは読み込み時に近くの標高で概略補完します。AR表示中に近傍検索は行いません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("詳細：遠方要素の最小表示") {
            Toggle("遠方最小表示サイズを使う", isOn: $model.settings.farMinimumSizeEnabled)
            sliderRow(title: "遠方ポイント最小サイズ", value: $model.settings.farPointMinSize, range: 0.02...0.8, step: 0.01, unit: "m")
            sliderRow(title: "遠方ライン最小幅", value: $model.settings.farLineMinWidth, range: 0.005...0.25, step: 0.005, unit: "m")
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
                Section("現在地を緯度経度で指定") {
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
                Section("現在地を座標で指定") {
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
    @State private var usePlaneRectangular = true
    @State private var systemNumber: Int
    var onApply: (GeoTIFFCoordinateMode) -> Void

    init(initialSystem: Int, onApply: @escaping (GeoTIFFCoordinateMode) -> Void) {
        _systemNumber = State(initialValue: initialSystem)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Button("この座標系で読み込む") {
                        onApply(usePlaneRectangular ? .planeRectangular(system: systemNumber) : .geographic)
                        dismiss()
                    }
                }
            }
            .navigationTitle("GeoTIFF読込")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
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
            .navigationTitle("点から現在地選択")
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
                Section("仕様") {
                    Text("AR画面のスワイプは方位・高さの微調整だけに使います。横スワイプで方位、縦スワイプで高さを調整します。高さ範囲は-100m〜+100mです。斜めスワイプ時は、横または縦のどちらか一方だけが反映されます。")
                    Text("平面図ボタンから、読み込んだ点・線を平面的に確認し、点をタップしてAR上で強調表示できます。")
                    Text("大量データは表示数・表示半径・点名数で制限し、近い要素を優先して表示します。")
                    Text("設定はアプリ再起動後も保持されます。")
                    Text("高さは初期状態では使いません。表示設定で『高さ情報を使う（概略）』をONにした場合だけ、KML/CSV/SIMAの有効な標高を現在地付近からの高さ差としてAR表示に反映します。")
                }
                Section("対応データ") {
                    Text("KML / KMZ / CSV / SIMA / GeoTIFF")
                    Text("GeoTIFFは簡易対応です。読込時に座標系をユーザー指定します。大きな画像は表示用に最大辺2048px程度へ縮小します。設定画面の不透明度スライダーはAR上のGeoTIFF表示に反映されます。初期値は35%です。")
                    Text("高さは初期状態では使いません。必要な場合は表示設定で『高さ情報を使う（概略）』をONにします。現在地付近の標高を0mとして表示し、標高0・標高なしは読み込み時に近くの有効な標高で概略補完します。")
                }
                Section("表示設定") {
                    Text("ポイント・ライン・点名のON/OFF、最大表示数、表示半径、サイズ、線幅、遠方最小表示サイズを設定できます。")
                    Text("距離表示は表示メニューから任意でONにできます。")
                }
            }
            .navigationTitle("説明")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
