import SwiftUI

/// The capture action stays at the trailing edge, separated from undo.
/// Captured geometry never depends on these panel states.
struct DrawingControlsView: View {
    @EnvironmentObject private var model:AppModel
    @Binding var expanded:Bool
    var export:()->Void
    var compactOnly=false
    @State private var showingWidth=false
    @State private var showingNewLayer=false
    @State private var newLayerName=""
    @State private var deletingAll=false
    @State private var confirmingDeletion=false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasGeometry:Bool { !model.drawing.completed.isEmpty || !model.drawing.draft.points.isEmpty }
    private var canUndoDeletion:Bool { !(model.drawing.deleted ?? []).isEmpty && !model.drawing.active }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            DroggerStatusView(receiver:model.drogger)
            if expanded && !compactOnly {
                Menu {
                    ForEach(model.drawing.drawingLayers) { layer in
                        Button { model.selectDrawingLayer(layer.id) } label: {
                            if layer.id == model.drawing.currentLayerID { Label(layer.name,systemImage:"checkmark") }
                            else { Text(layer.name) }
                        }
                    }
                    Button("作図レイヤーを追加",systemImage:"plus") { newLayerName=""; showingNewLayer=true }
                } label: { Label(model.drawing.currentLayerName,systemImage:"square.3.layers.3d") }
                .accessibilityIdentifier("drawing.layer")
            }
            if expanded && !compactOnly && showingWidth { DrawingWidthControl() }
            if model.drawing.active {
                DrawingCaptureActionRow(undo:undo,options:more,snap:snap,status:status,save:saveLine,confirm:confirm)
            } else if !expanded || compactOnly {
                HStack(spacing:5) {
                    if !compactOnly {toggle}
                    if model.drawing.active || model.drawingSelectionMode {
                        status
                        Spacer(minLength:0)
                        confirm
                        if model.drawing.active {undo}
                        more
                    }
                }
            } else if model.drawingSelectionMode {
                HStack(spacing:5) {
                    toggle
                    confirm
                    Button("削除",role:.destructive) { model.deleteSelectedDrawing() }
                        .disabled(model.selectedDrawingID == nil)
                        .accessibilityIdentifier("drawing.delete")
                    Button("戻す") { model.undoDrawingDeletion() }
                        .disabled(!canUndoDeletion)
                        .accessibilityIdentifier("drawing.restoreDeleted")
                    Button("終了") { model.endDrawingSelection() }
                        .accessibilityIdentifier("drawing.endSelection")
                    Spacer(minLength:0)
                }
                status
            } else {
                ViewThatFits(in:.horizontal) {
                    idleRow(showResume:true)
                    idleRow(showResume:false)
                }
                .frame(maxWidth:.infinity,alignment:.leading)
            }
            if model.workSaveMessage.contains("失敗") {
                HStack {
                    Label("保存失敗",systemImage:"exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                    Button("再試行") { model.retryWorkSave() }
                }
            } else if model.workRecoveredFromPreviousGeneration {
                Text("前の保存から復旧").font(.caption).foregroundStyle(.orange)
            }
        }
        .buttonStyle(DrawingActionStyle())
        .padding(.horizontal,10).padding(.bottom,8)
        .alert("作図レイヤーを追加",isPresented:$showingNewLayer) {
            TextField("レイヤー名",text:$newLayerName)
                .accessibilityIdentifier("drawing.newLayerName")
            Button("追加") { model.addDrawingLayer(name:newLayerName) }
            Button("取消",role:.cancel) { }
        } message: { Text("入力中の点列は、線を保存するか入力をクリアしてから切り替えてください。") }
        .confirmationDialog(deletingAll ? "全レイヤーの作図を削除しますか？" : "このレイヤーの作図を削除しますか？",isPresented:$confirmingDeletion,titleVisibility:.visible) {
            Button("作図を削除",role:.destructive) { model.deleteDrawingPaths(all:deletingAll) }
        } message: { Text("読み込んだ元図面は保持します。「削除を戻す」で復元できます。") }
    }
    @ViewBuilder private var confirm:some View {
        if model.drawing.active {confirmButton.buttonStyle(DrawingConfirmButtonStyle())}
        else {confirmButton}
    }
    private var confirmButton:some View {
        Button {model.requestDrawingCapture()} label: {
            HStack(spacing:8) {
                if model.drawingCapturePending {ProgressView().tint(.black)}
                else if model.drawing.active && !dynamicTypeSize.isAccessibilitySize {Image(systemName:"checkmark")}
                Text(model.drawingSelectionMode ? "選択":"点を追加")
            }
        }.disabled(!model.canRequestDrawingCapture)
            .accessibilityLabel(model.drawingSelectionMode ? "画面中央で作図を選択":"画面中央の点を入力点列に追加")
            .accessibilityIdentifier("drawing.confirmCenter")
    }
    private var undo:some View {
        Button("1点戻す") {model.undoDrawing()}
            .buttonStyle(DrawingSecondaryButtonStyle(width:88))
            .disabled(!model.canEditWork || (model.drawing.draft.points.isEmpty && !model.drawingHasObservation && !model.drawingCapturePending))
            .accessibilityLabel("入力点列の最後の1点を戻す").accessibilityIdentifier("drawing.undo")
    }
    private var saveLine:some View {
        Button {
            model.finishDrawing()
        } label:{Text(model.drawingSavePending ? "保存中…":(model.drawing.draft.isPointCollection ? "点を保存":"線を保存"))}
            .buttonStyle(DrawingSecondaryButtonStyle(width:112,save:true))
            .disabled(!model.canSaveDrawingLine)
            .accessibilityHint("入力中の点列を保存し、新しい入力を続けます。失敗時は点列を保持します。")
            .accessibilityIdentifier("drawing.finish")
    }
    private var snap:some View {
        Button {model.setDrawingSnapEnabled(!model.drawingSnapEnabled)} label:{
            DrawingSnapButtonLabel(enabled:model.drawingSnapEnabled)
        }.buttonStyle(.plain).disabled(!model.canEditWork)
            .accessibilityLabel("図形へのスナップ").accessibilityValue(model.drawingSnapEnabled ? "オン":"オフ")
            .accessibilityHint("オフでは照準の実物をLiDARまたは2視点で測定します")
            .accessibilityIdentifier("drawing.snap")
    }
    private var toggle:some View {
        Button { withAnimation(.easeInOut(duration:0.15)) { expanded.toggle() } } label: {
            HStack(spacing:4) {
                Text("作図")
                Image(systemName:expanded ? "chevron.down" : "chevron.up").font(.caption2)
            }
        }
        .buttonStyle(DrawingActionStyle(selected:expanded))
        .accessibilityIdentifier("drawing.toggle")
        .accessibilityValue(expanded ? "開いています" : "閉じています")
    }
    private func idleRow(showResume:Bool) -> some View {
        HStack(spacing:5) {
            toggle
            Button("線") { model.startDrawing() }
                .accessibilityLabel("線を追加").accessibilityIdentifier("drawing.line")
            Button("点") { model.startDrawing(kind:.points) }
                .accessibilityLabel("単独点を追加").accessibilityIdentifier("drawing.point")
            if showResume && model.drawing.resumableID != nil {
                Button("再開") { model.resumeDrawing() }.accessibilityIdentifier("drawing.resume")
            }
            Button("書き出し",action:export).disabled(!hasGeometry)
                .accessibilityIdentifier("drawing.export")
            more
        }
    }
    private var more:some View {
        Menu {
            if model.drawing.active {
                Button("入力をクリア",role:.destructive) {model.clearDrawingInput()}
                    .disabled(!model.canEditWork).accessibilityIdentifier("drawing.clearInput")
                Button("作図をやめる",role:.destructive) {model.cancelDrawing()}
                    .disabled(!model.canEditWork)
                    .accessibilityIdentifier("drawing.cancel")
                Button(expanded ? "作図パネルを閉じる":"作図パネルを開く") {expanded.toggle()}
            }
            if model.drawingSelectionMode {
                Button("選択した作図を削除",role:.destructive) {model.deleteSelectedDrawing()}.disabled(model.selectedDrawingID==nil)
                Button("選択を終了") {model.endDrawingSelection()}
            }
            Picker("線分の距離表示",selection:$model.settings.drawingDistanceMode) {
                ForEach(DrawingDistanceMode.allCases,id:\.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("drawing.distanceMode")
            if !model.drawing.active {
                Button("最後の線を再開") { model.resumeDrawing() }
                    .disabled(model.drawing.resumableID == nil)
                Button("選んで削除",systemImage:"cursorarrow.click") { model.beginDrawingSelection() }
                    .disabled(model.drawing.completed.isEmpty)
                Button("削除を戻す",systemImage:"arrow.uturn.backward") { model.undoDrawingDeletion() }
                    .disabled(!canUndoDeletion)
                Button("このレイヤーの作図を削除",role:.destructive) { deletingAll=false; confirmingDeletion=true }
                    .disabled(model.drawing.currentPaths.isEmpty)
                Button("全作図を削除",role:.destructive) { deletingAll=true; confirmingDeletion=true }
                    .disabled(model.drawing.completed.isEmpty)
            }
            Button(showingWidth ? "線幅を閉じる" : "線幅を調整",systemImage:"lineweight") { showingWidth.toggle() }
            if model.drawing.active { Button("書き出し",systemImage:"square.and.arrow.up",action:export).disabled(!hasGeometry) }
        } label: { Image(systemName:"ellipsis").font(.system(size:18,weight:.semibold)) }
        .accessibilityLabel(model.drawing.active ? "入力のクリア・作図の終了と編集":"作図の編集と線幅").accessibilityIdentifier("drawing.more")
        .disabled(model.drawingSavePending)
    }
    private var status:some View {
        VStack(alignment:.leading,spacing:2) {
            if model.drawing.active {
                Text("入力中 \(model.drawing.draft.points.count)点").monospacedDigit().lineLimit(1)
                Text("保存済 \(model.drawing.completed.count)件").font(.caption2).monospacedDigit().lineLimit(1)
                Text(model.drawingMessage).font(.caption2).lineLimit(2)
            } else { Text(model.drawingMessage).lineLimit(2) }
        }
        .font(.caption).foregroundStyle(.white)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .shadow(color:.black.opacity(0.85),radius:2)
        .accessibilityElement(children:.combine)
        .accessibilityIdentifier("drawing.status")
    }
}

// BEGIN PORTABLE DRAWING CAPTURE CONTROLS
/// A single 60pt row when feedback fits; narrow screens move only feedback above it.
/// Undo and confirm retain the same left/right positions in both arrangements.
struct DrawingCaptureActionRow<Undo:View,Options:View,Snap:View,Status:View,Save:View,Confirm:View>:View {
    var undo:Undo
    var options:Options
    var snap:Snap
    var status:Status
    var save:Save
    var confirm:Confirm
    var body:some View {
        ViewThatFits(in:.horizontal) {
            row(showStatus:true)
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:8) {undo;options;Spacer(minLength:24);save}
                HStack(spacing:8) {snap;status;Spacer(minLength:0);confirm.layoutPriority(1)}
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func row(showStatus:Bool)->some View {
        HStack(spacing:8) {
            undo
            options
            snap
            if showStatus {status.fixedSize(horizontal:true,vertical:false)}
            save
            Spacer(minLength:24)
            confirm.layoutPriority(1)
        }
    }
}

struct DrawingSnapButtonLabel:View {
    var enabled:Bool
    var body:some View {
        VStack(spacing:1) {
            Text("スナップ").font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            Text(enabled ? "ON":"OFF").font(.subheadline.bold()).lineLimit(1)
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(width:88,height:44)
            .foregroundStyle(enabled ? Color.black:Color.white)
            .background(enabled ? Color.cyan:Color.black.opacity(0.7),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(enabled ? Color.cyan:Color.white.opacity(0.7),lineWidth:1.5))
    }
}

struct DrawingSecondaryButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var width:CGFloat
    var save=false
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.3)
            .frame(width:width-16,height:28).padding(8)
            .foregroundStyle(enabled ? Color.white:Color.white.opacity(0.5))
            .background(Color.black.opacity(configuration.isPressed ? 0.7:0.5),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(save ? Color.green:Color.white.opacity(0.3),lineWidth:save ? 2:1))
            .contentShape(RoundedRectangle(cornerRadius:14))
    }
}

struct DrawingConfirmButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.3)
            .frame(height:36)
            .padding(.horizontal,12).padding(.vertical,12)
            .frame(width:128).frame(minHeight:60)
            .foregroundStyle(enabled ? Color.black:Color.white.opacity(0.7))
            .background(enabled ? Color.cyan.opacity(configuration.isPressed ? 0.7:1):Color.gray.opacity(0.5),in:RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).strokeBorder(.white.opacity(enabled ? 0.65:0.3),lineWidth:1))
            .contentShape(RoundedRectangle(cornerRadius:20))
    }
}
// END PORTABLE DRAWING CAPTURE CONTROLS

/// Plain alpha compositing: the live camera is never blurred by a Material.
extension View {
    func arControlSurface<S:Shape>(in shape:S) -> some View {
        self.foregroundStyle(.white)
            .shadow(color:.black.opacity(0.95),radius:1,x:0,y:1)
            .background(Color.black.opacity(0.5),in:shape)
            .overlay(shape.stroke(Color.white.opacity(0.3),lineWidth:1))
    }
}

struct DrawingActionStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var selected=false
    func makeBody(configuration:Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold)).lineLimit(1).fixedSize(horizontal:true,vertical:false)
            .padding(.horizontal,10).frame(minWidth:44,minHeight:44)
            .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.55))
            .shadow(color:.black,radius:1,x:0,y:1)
            .background(Color.black.opacity(configuration.isPressed ? 0.65 : 0.5),in:Capsule())
            .overlay(Capsule().strokeBorder(configuration.role == .destructive ? Color.red : (selected ? Color.cyan : Color.white.opacity(0.3)),lineWidth:selected ? 2 : 1))
    }
}

private struct DrawingWidthControl:View {
    @EnvironmentObject private var model:AppModel
    @State private var width=AppModel.defaultDrawingLineWidth
    @State private var pending:Task<Void,Never>?
    var body:some View {
        HStack(spacing:10) {
            VStack(alignment:.leading,spacing:2) {
                Text("線と点の太さ").font(.caption.bold())
                Text(String(format:"線幅 %.1f cm",width*100)).font(.caption2).monospacedDigit()
            }.frame(width:88,alignment:.leading)
            Slider(value:$width,in:0.004...0.08,step:0.001,onEditingChanged:{ active in
                if !active { pending?.cancel(); model.setDrawingLineWidth(width) }
            })
            .accessibilityLabel("作図の線幅").accessibilityIdentifier("drawing.width")
            .accessibilityHint("作図した点のサイズも一緒に変わります")
        }
        .padding(.horizontal,12).padding(.vertical,8)
        .arControlSurface(in:RoundedRectangle(cornerRadius:14))
        .onAppear { width=model.drawingLineWidth }
        .onChange(of:width) { _, value in
            pending?.cancel()
            pending=Task { @MainActor in
                try? await Task.sleep(for:.milliseconds(150))
                guard !Task.isCancelled else { return }
                model.setDrawingLineWidth(value)
            }
        }
        .onDisappear { pending?.cancel(); model.setDrawingLineWidth(width) }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// XCUITest sensor stand-in. Compiled out of all iPhone builds; UI actions and
/// persistence still run through the production model and views on a fresh simulator.
enum DrawingUIFixture {
    static var active:Bool { ProcessInfo.processInfo.environment["AR_DRAWING_UI_TEST"] == "1" }
    @MainActor static func prepare(_ model:AppModel) async {
        while model.isRestoringWork { try? await Task.sleep(for:.milliseconds(20)) }
        guard model.canEditWork else { return }
        model.arCameraActive=false
        if !model.layers.isEmpty { return }
        model.settings = .defaults
        model.settings.useRelativeAltitude=true
        model.settings.boundaryTerrainFollowEnabled=false
        var a=GeoCoordinate(name:"A",latitude:35,longitude:139,altitude:100.25); a.dxfAltitude=100.25
        var b=GeoCoordinate(name:"B",latitude:35.00001,longitude:139.00001,altitude:102.75); b.dxfAltitude=102.75
        let first=ImportedDataLayer(name:"標高図面.dxf",features:[GeoFeature(name:"fixture",kind:.line,coordinates:[a,b])],points:[],rasters:[],dxfReference:.init())
        a.altitude=nil; a.dxfAltitude=0; b.altitude=nil; b.dxfAltitude=0
        let second=ImportedDataLayer(name:"平面図面.dxf",features:[GeoFeature(name:"other",kind:.line,coordinates:[a,b])],points:[],rasters:[],dxfReference:.init(planeSystem:7,metersPerUnit:0.001,xIsEasting:false))
        model.layers=[first,second]; model.setLayerVisible(first.id,isVisible:true)
        model.setOrigin(latitude:35,longitude:139)
    }
}
struct DrawingUITestCanvas:View {
    @EnvironmentObject private var model:AppModel
    private var lineCount:Int { model.drawing.completed.filter { $0.points.count>1 }.count }
    private var pointCount:Int { model.drawing.completed.filter { $0.points.count==1 }.count }
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing:10) {
                Text("線:\(lineCount) 点:\(pointCount) 下書き:\(model.drawing.draft.points.count)")
                    .accessibilityIdentifier("fixture.counts")
                Text(model.workSaveMessage).accessibilityIdentifier("fixture.save")
                Text("元図面:\(model.layers.count)").accessibilityIdentifier("fixture.importedLayers")
                Text(String(format:"width=%.3f",model.drawingLineWidth)).accessibilityIdentifier("fixture.width")
                if model.drawing.active {
                    Button("観測点を入力") {
                        let n=model.drawing.completed.reduce(0) { $0+$1.points.count }+model.drawing.draft.points.count
                        model.addDrawingPoint(SIMD3(Float(n*3),Float(n),-3),sourceAltitude:100.25+Double(n))
                    }.accessibilityIdentifier("fixture.capture")
                }
                if model.drawingSelectionMode {
                    Button("線をピック") { pick(points:false) }.accessibilityIdentifier("fixture.pickLine")
                    Button("単独点をピック") { pick(points:true) }.accessibilityIdentifier("fixture.pickPoint")
                }
            }
            .font(.caption).foregroundStyle(.white).buttonStyle(.bordered)
        }
    }
    private func pick(points:Bool) {
        guard let path=model.drawing.currentPaths.first(where:{ ($0.points.count==1)==points }), let point=path.points.first else { return }
        let project:(SIMD3<Float>)->SIMD2<Float>? = { SIMD2($0.x*20,$0.y*20) }
        let id=DrawingSelection.hit(paths:model.drawing.currentPaths,tap:project(point)!,project:project)
        model.selectDrawing(id)
    }
}
#endif

/// Screen-space candidate glyphs cannot be mistaken for measured orange 3D points.
struct DrawingSnapIndicatorView:View {
    var indicator:DrawingSnapIndicator
    var body:some View {
        GeometryReader {proxy in
            VStack(spacing:3) {
                Image(systemName:"diamond").font(.system(size:32,weight:.bold)).frame(width:38,height:38)
                Text("吸着・"+indicator.title).font(.caption.bold()).padding(4).background(.black.opacity(0.8),in:Capsule())
            }.foregroundStyle(.cyan).shadow(color:.black,radius:2)
                .position(x:indicator.normalized.x*proxy.size.width,y:indicator.normalized.y*proxy.size.height+14)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
