import XCTest

final class ARDrawingUITests:XCTestCase {
    /// Exercise the production ContentView under standard, unoptimised Debug.
    /// The fixture replaces only the camera/observations and owns its sandbox.
    @MainActor func testStandardDebugStartupAndViewBoundaries() {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchEnvironment["AR_DRAWING_UI_TEST"]="1"
        app.launchArguments=["-AppleLanguages","(ja)","-AppleLocale","ja_JP"]
        app.launch()
        let counts=app.descendants(matching:.any).matching(identifier:"fixture.counts").firstMatch
        XCTAssertTrue(counts.waitForExistence(timeout:20))
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertTrue(app.buttons["photo.mode"].waitForExistence(timeout:10))
        app.buttons["drawing.toggle"].tap()
        XCTAssertTrue(app.buttons["drawing.line"].waitForExistence(timeout:5))
        for _ in 0..<3 {
            app.buttons["操作UIを隠す"].firstMatch.tap()
            XCTAssertTrue(app.buttons["操作UIを表示"].waitForExistence(timeout:5))
            app.buttons["操作UIを表示"].tap()
            XCTAssertTrue(app.buttons["drawing.line"].waitForExistence(timeout:5))
            XCTAssertTrue(app.buttons["photo.mode"].exists)
        }
        app.buttons["photo.mode"].tap()
        app.buttons["写真の座標"].tap()
        XCTAssertTrue(app.switches["photo.source"].waitForExistence(timeout:5))
        app.buttons["photo.close"].tap()
        app.buttons["データ"].tap()
        XCTAssertTrue(app.buttons["データを追加"].waitForExistence(timeout:5))
        app.buttons["AR"].tap()
        XCTAssertTrue(app.buttons["drawing.line"].waitForExistence(timeout:5))
        let screenshot=XCTAttachment(screenshot:app.screenshot())
        screenshot.name="standard-debug-startup";screenshot.lifetime = .keepAlways;add(screenshot)
        app.terminate();app.launch()
        XCTAssertTrue(counts.waitForExistence(timeout:20))
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertTrue(app.buttons["photo.mode"].waitForExistence(timeout:5))
    }

    /// Idle controls stay at the edges; entering an infrequent task is
    /// deliberate, while active tree capture never becomes folded away.
    @MainActor func testCompactDrawingAndTreeEntryControls() {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchEnvironment["AR_DRAWING_UI_TEST"]="1"
        app.launchArguments=["-AppleLanguages","(ja)","-AppleLocale","ja_JP"]
        app.launch()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"fixture.counts").firstMatch.waitForExistence(timeout:20))
        let drawing=app.buttons["drawing.toggle"]
        let tree=app.buttons["tree.toggle"]
        XCTAssertTrue(drawing.waitForExistence(timeout:5))
        XCTAssertTrue(tree.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["tree.start"].exists)
        XCTAssertFalse(app.buttons["tree.savedRecords"].exists)
        XCTAssertFalse(app.buttons["drawing.line"].exists)
        XCTAssertLessThan(drawing.frame.width,180)
        XCTAssertLessThan(drawing.frame.midX,app.frame.midX)
        // The button is above the existing adjustment controls, rather than
        // occupying a separate full-width row below them.
        let adjustment=app.buttons["ar.displayAdjustment"]
        XCTAssertTrue(adjustment.exists)
        XCTAssertLessThanOrEqual(drawing.frame.maxY,adjustment.frame.minY)
        for _ in 0..<3 {
            tree.tap()
            XCTAssertTrue(app.buttons["tree.start"].waitForExistence(timeout:5))
            XCTAssertTrue(app.buttons["tree.savedRecords"].exists)
            tree.tap()
            XCTAssertFalse(app.buttons["tree.start"].exists)
        }
        tree.tap()
        let entries=app.scrollViews["ar.entryControls"]
        let saved=app.buttons["tree.savedRecords"]
        if !saved.isHittable {entries.swipeLeft()}
        saved.tap()
        XCTAssertTrue(app.navigationBars["樹木の記録"].waitForExistence(timeout:5))
        app.buttons["閉じる"].tap()
        if !tree.isHittable {entries.swipeRight()}
        tree.tap()
        XCTAssertFalse(app.buttons["tree.start"].exists)
        app.buttons["操作UIを隠す"].firstMatch.tap()
        app.buttons["操作UIを表示"].tap()
        XCTAssertTrue(tree.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["tree.start"].exists)
        let screenshot=XCTAttachment(screenshot:app.screenshot())
        screenshot.name="compact-drawing-tree-controls";screenshot.lifetime = .keepAlways;add(screenshot)
        tree.tap()
        let start=app.buttons["tree.start"]
        if !start.isHittable {entries.swipeLeft()}
        XCTAssertTrue(start.isEnabled)
        start.tap()
        XCTAssertTrue(app.buttons["tree.confirmCenter"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["tree.toggle"].exists)
        XCTAssertFalse(app.buttons["drawing.toggle"].exists)
        app.buttons["tree.options"].tap()
        app.buttons["測定を終了"].tap()
        XCTAssertTrue(tree.waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["tree.start"].exists)
        app.terminate();app.launch()
        XCTAssertTrue(tree.waitForExistence(timeout:20))
        XCTAssertFalse(app.buttons["tree.start"].exists)
    }

    /// Opt-in screenshots of the production views. No DrawingUITestCanvas or
    /// simulated AR observations are used; the input is a small synthetic DXF.
    @MainActor func testStoreScreenshots() throws {
        let root="/tmp/ar-store-sample"
        guard FileManager.default.fileExists(atPath:root+"/Samples/Generated/survey_100mb.dxf") else { throw XCTSkip("Prepare the release screenshot sample first") }
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchEnvironment["AR_SURVEY_VALIDATION_ROOT"]=root
        app.launchArguments=["-AppleLanguages","(ja)","-AppleLocale","ja_JP"]
        app.launch()
        XCTAssertTrue(app.buttons["全体"].waitForExistence(timeout:20))
        let restored=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.staticTexts["前回作業を復元中"])
        XCTAssertEqual(XCTWaiter.wait(for:[restored],timeout:20),.completed)
        // Map tiles arrive asynchronously. This delay is only for screenshot capture.
        Thread.sleep(forTimeInterval:5)
        func photo(_ name:String) { let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a) }
        photo("store-map")
        app.buttons["データ"].tap()
        XCTAssertTrue(app.buttons["データを追加"].waitForExistence(timeout:10))
        photo("store-data")
        app.buttons["AR"].tap()
        let mode=app.buttons["photo.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout:10));mode.tap()
        app.buttons["写真の座標"].tap()
        XCTAssertTrue(app.switches["photo.source"].waitForExistence(timeout:10))
        photo("store-photo-coordinates")
    }

    @MainActor func testDrawingWorkflow() {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchEnvironment["AR_DRAWING_UI_TEST"]="1"
        app.launchArguments=["-AppleLanguages","(ja)","-AppleLocale","ja_JP"]
        func element(_ id:String) -> XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
        func tap(_ id:String) {
            // Capture keeps secondary actions in the menu to separate undo from confirm.
            if ["drawing.finish","drawing.cancel"].contains(id),!element(id).exists {element("drawing.more").tap()}
            let item=element(id)
            XCTAssertTrue(item.exists || item.waitForExistence(timeout:10),id)
            if !item.isHittable {
                let ready=XCTNSPredicateExpectation(predicate:NSPredicate(format:"hittable == true"),object:item)
                XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:5),.completed,id)
            }
            item.tap()
        }
        func label(_ id:String,contains text:String) {
            if element(id).label.contains(text) { return }
            let expected=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@",text),object:element(id))
            XCTAssertEqual(XCTWaiter.wait(for:[expected],timeout:10),.completed,"\(id): \(text)")
        }
        func menu(_ text:String) { tap("drawing.more"); XCTAssertTrue(app.buttons[text].exists || app.buttons[text].waitForExistence(timeout:5)); app.buttons[text].tap() }
        func counts(_ value:String) { label("fixture.counts",contains:value) }
        func saved() { label("fixture.save",contains:"自動保存済み") }
        func photo(_ name:String) { let a=XCTAttachment(screenshot:app.screenshot()); a.name=name; a.lifetime = .keepAlways; add(a) }
        app.launch()
        XCTAssertTrue(element("fixture.counts").waitForExistence(timeout:15))
        counts("線:0 点:0 下書き:0")
        label("fixture.width",contains:"width=0.008")
        tap("drawing.toggle")
        for _ in 0..<3 { tap("drawing.toggle"); XCTAssertFalse(element("drawing.line").exists); tap("drawing.toggle"); XCTAssertTrue(element("drawing.line").isHittable) }
        photo("idle-controls")
        tap("drawing.line"); tap("fixture.capture"); tap("fixture.capture")
        counts("下書き:2"); tap("drawing.finish"); counts("線:1 点:0 下書き:0"); menu("作図をやめる")
        tap("drawing.point"); tap("fixture.capture"); XCTAssertTrue(element("drawing.finish").isEnabled)
        tap("drawing.finish"); counts("線:1 点:1 下書き:0"); menu("作図をやめる")
        tap("drawing.resume"); counts("下書き:2"); tap("fixture.capture"); counts("下書き:3"); tap("drawing.cancel")
        tap("drawing.resume"); counts("下書き:2"); tap("drawing.cancel")
        menu("選んで削除"); tap("fixture.pickLine"); label("drawing.status",contains:"線全体")
        photo("selected-polyline")
        tap("drawing.delete"); counts("線:0 点:1 下書き:0")
        tap("drawing.restoreDeleted"); counts("線:1 点:1 下書き:0")
        tap("fixture.pickPoint"); tap("drawing.delete"); counts("線:1 点:0 下書き:0"); saved()
        app.terminate(); app.launch()
        counts("線:1 点:0 下書き:0"); tap("drawing.toggle"); menu("削除を戻す")
        counts("線:1 点:1 下書き:0")
        menu("線幅を調整")
        XCTAssertTrue(app.sliders["drawing.width"].waitForExistence(timeout:5))
        app.sliders["drawing.width"].adjust(toNormalizedSliderPosition:0.6)
        tap("drawing.toggle"); saved()
        let width=element("fixture.width").label
        XCTAssertNotEqual(width,"width=0.008")
        app.terminate(); app.launch(); label("fixture.width",contains:width)
        tap("drawing.toggle"); tap("drawing.export")
        tap("export.document"); app.buttons["標高図面.dxf"].tap()
        tap("export.coordinates")
        // SwiftUI DisclosureGroup propagates its identifier to child controls.
        // Locate the pickers by their visible, localized labels instead.
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","平面直角座標系")).firstMatch.tap()
        app.buttons["8系"].tap()
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","DXFの軸")).firstMatch.tap()
        app.buttons["X=北・Y=東"].tap()
        photo("edited-export-settings")
        tap("export.close"); saved(); tap("drawing.export")
        XCTAssertTrue(app.staticTexts["8系・m・X=北"].waitForExistence(timeout:5))
        tap("export.document"); app.buttons["平面図面.dxf"].tap()
        XCTAssertTrue(app.staticTexts["7系・mm・X=北"].waitForExistence(timeout:5))
        label("export.heightSummary",contains:"Z=0")
        photo("export-document-settings")
        tap("export.save")
        // The Files view is hosted by an OS process; verify presentation and
        // interruption/recovery without depending on its transient AX button type.
        XCTAssertTrue(app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].waitForExistence(timeout:10))
        photo("file-exporter")
        app.terminate(); app.launch(); tap("drawing.toggle"); tap("drawing.export")
        XCTAssertTrue(app.staticTexts["7系・mm・X=北"].waitForExistence(timeout:5))
        tap("export.document"); app.buttons["標高図面.dxf"].tap()
        XCTAssertTrue(app.staticTexts["8系・m・X=北"].waitForExistence(timeout:5))
        tap("export.close"); counts("線:1 点:1 下書き:0")
        photo("final-controls")
        tap("photo.mode");app.buttons["写真のみ"].tap();label("photo.mode",contains:"写真のみ")
        tap("photo.mode");app.buttons["写真の座標"].tap()
        XCTAssertTrue(app.switches["photo.source"].waitForExistence(timeout:5))
        XCTAssertEqual(app.switches["photo.source"].value as? String,"1")
        app.switches["photo.source"].coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        let sourceOff=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","0"),object:app.switches["photo.source"])
        XCTAssertEqual(XCTWaiter.wait(for:[sourceOff],timeout:5),.completed)
        photo("photo-source-off");tap("photo.close");saved()
        app.terminate();app.launch();label("photo.mode",contains:"写真のみ")
        tap("photo.mode");app.buttons["写真の座標"].tap()
        XCTAssertEqual(app.switches["photo.source"].value as? String,"0")
        photo("photo-coordinate-settings")
        app.switches["photo.source"].tap();tap("photo.close")
        app.buttons["地図"].tap()
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let denyLocation=springboard.alerts.buttons["許可しない"]
        if denyLocation.waitForExistence(timeout:2) { denyLocation.tap() }
        else if springboard.alerts.buttons["Don't Allow"].exists { springboard.alerts.buttons["Don't Allow"].tap() }
        tap("map.fit")
        let background=element("map.background")
        let previousBackground=background.value as? String
        XCTAssertTrue(["表示","非表示"].contains(previousBackground ?? ""))
        tap("map.background")
        let newBackground=background.value as? String
        XCTAssertNotEqual(newBackground,previousBackground)
        photo("map-background-toggle")
        app.terminate();app.launch();app.buttons["地図"].tap()
        XCTAssertEqual(element("map.background").value as? String,newBackground)
        tap("map.fit");tap("map.background")
        XCTAssertEqual(element("map.background").value as? String,previousBackground)
        photo("map-background-restored")
        app.buttons["AR"].tap(); tap("drawing.toggle")
        let imported=element("fixture.importedLayers").label
        tap("drawing.line"); tap("fixture.capture"); tap("fixture.capture")
        tap("drawing.layer"); app.buttons["作図レイヤーを追加"].tap()
        let name=app.textFields["drawing.newLayerName"]
        XCTAssertTrue(name.waitForExistence(timeout:5)); name.tap(); name.typeText("検証レイヤー2")
        app.alerts.buttons["追加"].tap()
        counts("線:2 点:1 下書き:0"); label("drawing.layer",contains:"検証レイヤー2")
        tap("fixture.capture"); counts("下書き:1")
        tap("drawing.layer"); app.buttons["作図1"].tap()
        counts("線:2 点:2 下書き:0"); tap("drawing.cancel")
        tap("drawing.layer"); app.buttons["検証レイヤー2"].tap()
        menu("このレイヤーの作図を削除"); app.buttons["作図を削除"].tap()
        counts("線:2 点:1 下書き:0"); menu("削除を戻す")
        counts("線:2 点:2 下書き:0"); saved()
        app.terminate();app.launch();tap("drawing.toggle")
        label("drawing.layer",contains:"検証レイヤー2")
        menu("全作図を削除"); app.buttons["作図を削除"].tap()
        counts("線:0 点:0 下書き:0")
        label("fixture.importedLayers",contains:imported)
        menu("削除を戻す"); counts("線:2 点:2 下書き:0");saved()
        label("fixture.importedLayers",contains:imported)
        photo("layers-undo-restored")
        print("AR_DRAWING_UI_WORKFLOW_PASS: open/close, line, point, resume/cancel, selection/delete/undo/relaunch, width, per-document export settings, interrupted export recovery, photo mode/source restart, layer create/switch/mid-line split/single-vertex retention/restart, layer/all delete Undo, imported drawings retained")
    }
}
