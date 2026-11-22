import XCTest

final class PatientScreenUITests: XCTestCase {
    func testFreshInstallShowsSetupWithoutAnyPatientContent() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetForUITests"]
        app.launch()
        XCTAssertTrue(app.buttons["welcome.createFamily"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["patient.card"].exists)
        XCTAssertFalse(app.staticTexts["patient.card"].exists)
    }
}
