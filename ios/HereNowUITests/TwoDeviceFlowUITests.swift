import XCTest

/// End-to-end flow across two simulators that share the real sync service.
/// Run `scripts/e2e-two-devices.sh`; it starts the caregiver test on an iPhone and the display test on an iPad.
/// The two tests hand over the pairing code through a file in /tmp, which simulator processes can read.
final class TwoDeviceFlowUITests: XCTestCase {
    static let handoff = URL(fileURLWithPath: "/tmp/herenow-e2e")

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetForUITests"]
        app.launchEnvironment["TZ"] = "Asia/Shanghai"
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        var attempts = 0
        while !(element.exists && element.isHittable) && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.exists, "missing \(element)", file: file, line: line)
    }

    private func type(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        reveal(field, in: app)
        field.tap()
        field.typeText(text)
    }

    private func flip(_ toggle: XCUIElement, app: XCUIApplication) {
        reveal(toggle, in: app)
        let control = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    func testCaregiverCreatesFamilyPublishesAndApprovesDisplay() throws {
        try? FileManager.default.removeItem(at: Self.handoff)
        try FileManager.default.createDirectory(at: Self.handoff, withIntermediateDirectories: true)
        let app = launch()

        app.buttons["welcome.createFamily"].tap()
        flip(app.switches["onboarding.explained"], app: app)
        flip(app.switches["onboarding.authorized"], app: app)
        app.buttons["onboarding.next"].tap()

        type("妈妈", into: app.textFields["onboarding.callName"], app: app)
        type("妈妈的家", into: app.textFields["onboarding.familyName"], app: app)
        flip(app.switches["显示地点提示"], app: app)
        type("这里是家里的客厅", into: app.textFields["onboarding.placeLine"], app: app)
        app.buttons["onboarding.next"].tap()

        flip(app.switches["onboarding.segmentsConfirmed"], app: app)
        app.buttons["onboarding.next"].tap()
        flip(app.switches["没有家人录音时，用系统声音朗读短句"], app: app)
        app.buttons["onboarding.next"].tap()

        XCTAssertTrue(app.staticTexts["recoveryKey"].waitForExistence(timeout: 15))
        flip(app.switches["recovery.saved"], app: app)
        app.buttons["recovery.continue"].tap()

        app.tabBars.buttons["内容"].tap()
        app.buttons["editor.addEvent"].tap()
        type("小雨\n", into: app.textFields["event.person"], app: app)
        reveal(app.buttons["event.until.2h"], in: app)
        app.buttons["event.until.2h"].tap()
        app.buttons["event.save"].tap()
        app.buttons["editor.review"].tap()
        let publish = app.buttons["review.publish"]
        reveal(publish, in: app)
        publish.tap()

        app.tabBars.buttons["设备"].tap()
        app.buttons["devices.pair"].tap()
        let code = app.staticTexts["pairing.code"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        try code.label.write(to: Self.handoff.appendingPathComponent("code.txt"), atomically: true, encoding: .utf8)

        let approve = app.buttons["claim.approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 240), "the iPad never asked to join")
        XCTAssertEqual(app.staticTexts["claim.title"].firstMatch.label, "「患者的 iPad」请求加入「妈妈的家」")
        approve.tap()
        XCTAssertTrue(app.buttons["pairing.done"].waitForExistence(timeout: 30))
        app.buttons["pairing.done"].tap()

        app.tabBars.buttons["此刻"].tap()
        let applied = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "第 1 版 · 设备已接收并应用")).firstMatch
        XCTAssertTrue(applied.waitForExistence(timeout: 240), "the iPad never reported applying version 1")
    }

    func testDisplayPairsWithCodeAndShowsPublishedContent() throws {
        let codeFile = Self.handoff.appendingPathComponent("code.txt")
        var code: String?
        for _ in 0..<240 {
            code = try? String(contentsOf: codeFile, encoding: .utf8)
            if code != nil { break }
            Thread.sleep(forTimeInterval: 1)
        }
        let pairingCode = try XCTUnwrap(code, "the caregiver test did not publish a pairing code")
        let app = launch()

        app.buttons["welcome.pairDisplay"].tap()
        let field = app.textFields["pair.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(pairingCode)
        app.buttons["pair.next"].tap()
        XCTAssertTrue(app.staticTexts["加入「妈妈的家」？"].waitForExistence(timeout: 15))
        app.buttons["pair.confirm"].tap()

        XCTAssertTrue(app.buttons["pin.1"].waitForExistence(timeout: 240), "the caregiver never approved")
        for _ in 0..<2 { for digit in ["1", "2", "3", "4", "5", "6"] { app.buttons["pin.\(digit)"].tap() } }

        let card = app.staticTexts["patient.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 60))
        let deadline = Date().addingTimeInterval(60)
        while !card.label.contains("小雨计划"), Date() < deadline { Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(card.label.contains("小雨计划"), "card shows \(card.label)")
        XCTAssertTrue(app.buttons["patient.sound"].exists)
        XCTAssertFalse(app.buttons["编辑"].exists)
    }
}
