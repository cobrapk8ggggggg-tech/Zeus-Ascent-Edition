import XCTest

final class ImageTranslationJourneyTests: XCTestCase {
    func testImageTranslationStartsFromOriginalToolsMenu() { startFromMenu("original") }
    func testImageTranslationStartsFromDualBarsToolsMenu() { startFromMenu("dualBars") }
    func testImageTranslationStartsFromICabToolsMenu() { startFromMenu("icab") }

    func testImageTranslationSettingsOpenDirectlyFromTools() {
        let app = launch("dualBars")
        openTools(app, layout: "dualBars")
        let settings = app.buttons["menu-imageTranslationSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        XCTAssertTrue(app.buttons["startImageTranslation"].waitForExistence(timeout: 10))
        capture("image-translation-settings-from-tools")
    }

    func testImageTranslationHasItsOwnMainSettingsCategory() {
        let app = launch("dualBars")
        openTools(app, layout: "dualBars")
        app.buttons["group-account"].tap()
        app.buttons["menu-settingsButton"].tap()
        let category = app.descendants(matching: .any).matching(identifier: "category-imageTranslation").firstMatch
        // Compact settings start at the categories; iPad keeps them in the sidebar.
        for _ in 0..<8 {
            if category.exists && category.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(category.waitForExistence(timeout: 5)); category.tap()
        XCTAssertTrue(app.buttons["startImageTranslation"].waitForExistence(timeout: 10))
        // SwiftUI may expose the switch with its state appended to its label,
        // and Form realizes offscreen rows lazily. Find the named control after
        // navigation settles, then prove that it actually changes the setting.
        let automatic=app.switches.matching(NSPredicate(format:"label CONTAINS %@","ترجمة الصور")).firstMatch
        for _ in 0..<6 {
            if automatic.waitForExistence(timeout:2) && automatic.isHittable {break}
            app.swipeUp()
        }
        let hierarchy=XCTAttachment(string:app.debugDescription)
        hierarchy.name="Image translation main settings accessibility";hierarchy.lifetime = .keepAlways;add(hierarchy)
        XCTAssertTrue(automatic.waitForExistence(timeout:5));XCTAssertTrue(automatic.isHittable)
        // iOS 26 exposes both a full-width Switch row and its UISwitch child.
        // Tapping the row's center hits blank space, not the RTL thumb.
        let thumb=automatic.switches.firstMatch
        let control=thumb.exists ? thumb:automatic
        XCTAssertTrue(control.isHittable)
        if control.value as? String != "1" {control.tap()}
        XCTAssertEqual(control.value as? String,"1")
        control.tap();XCTAssertEqual(control.value as? String,"0")
        capture("image-translation-main-settings-category")
    }

    func testAppearanceShowsRendererPreviewAndFontControls() {
        let app=launch("dualBars")
        openTools(app,layout:"dualBars")
        app.buttons["menu-imageTranslationSettings"].tap()
        let appearance=app.segmentedControls.buttons["المظهر"]
        XCTAssertTrue(appearance.waitForExistence(timeout:10));appearance.tap()
        app.swipeUp()
        let preview=app.descendants(matching:.any).matching(identifier:"comicLetteringPreview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout:10))
        capture("image-translation-lettering-preview")
        app.swipeUp()
        XCTAssertTrue(app.sliders["حجم خط الصور"].waitForExistence(timeout:5))
        capture("image-translation-typography-controls")
    }

    func testActualVioletChapterRendersWithRestorationDisabled(){
        let app=XCUIApplication();app.launchArguments=["--uitesting","--layout=dualBars","--comic-violet-fixture"];app.launch()
        let search=app.textFields["homeSearchField"];XCTAssertTrue(search.waitForExistence(timeout:20));search.tap();search.typeText("http://127.0.0.1:8765/comic-violet/?page=1\n")
        XCTAssertTrue(app.webViews.staticTexts["Violet real chapter"].waitForExistence(timeout:30))
        openTools(app,layout:"dualBars");app.buttons["menu-translateImagesButton"].firstMatch.tap()
        let translated=app.buttons.matching(NSPredicate(format:"label == %@","حالة ترجمة الصور وتفاصيلها")).firstMatch
        let ready=NSPredicate{_,_ in
            guard translated.exists else{return false}
            let values=(translated.value as? String ?? "").components(separatedBy:"·").last ?? ""
            let digits=values.compactMap{$0.wholeNumberValue};return digits.reduce(0){$0*10+$1}>=4
        }
        expectation(for:ready,evaluatedWith:nil);waitForExpectations(timeout:85)
        let hierarchy=XCTAttachment(string:app.debugDescription);hierarchy.name="Violet actual app - fastest, auto language, restoration off";hierarchy.lifetime = .keepAlways;add(hierarchy)
        capture("Violet real chapter translated in running app with restoration off")
    }
    private func startFromMenu(_ layout: String) {
        let app = launch(layout)
        let search = app.textFields["homeSearchField"]
        search.tap(); search.typeText("http://127.0.0.1:8765/\n")
        XCTAssertTrue(app.webViews.staticTexts["ZEUS integration fixture"].waitForExistence(timeout: 30))
        openTools(app, layout: layout)
        let translate = app.buttons["menu-translateImagesButton"].firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        capture(layout + "-image-translation-visible-menu")
        translate.tap()
        let card = app.descendants(matching: .any).matching(identifier: "imageTranslationCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The visible menu must activate the image session, not page translation")
        capture(layout + "-image-translation-started")
    }
    private func launch(_ layout: String) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--layout=" + layout]
        app.launch(); XCTAssertTrue(app.textFields["homeSearchField"].waitForExistence(timeout: 20)); return app
    }
    private func openTools(_ app: XCUIApplication, layout: String) {
        if layout == "original" {
            let edge = app.otherElements["toolbarEdge"]; XCTAssertTrue(edge.waitForExistence(timeout: 10)); edge.tap()
        }
        let tools = app.buttons["toolsButton"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10)); tools.tap()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
