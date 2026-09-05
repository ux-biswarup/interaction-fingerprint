import XCTest

/// Drives the recording path end to end in the simulator.
///
/// ARKit does not run here, so the gaze side of a session is empty. The interaction side is
/// fully real: the touch observer, the recorder, the exporter and the file on disk. The
/// first recording on a device contained three purchases and no taps, and nothing short of
/// pressing real buttons through a real window would have caught that.
final class InteractionFingerprintUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTapsAreRecordedDuringAStudySession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-stimulusPreview", "-recording"]
        app.launch()

        let product = app.buttons["product_sku_101"]
        XCTAssertTrue(product.waitForExistence(timeout: 5), "product list did not appear")
        product.tap()

        let basket = app.buttons["add_to_basket"]
        XCTAssertTrue(basket.waitForExistence(timeout: 5), "detail screen did not appear")
        basket.tap()

        app.buttons["back_to_shop"].tap()
        XCTAssertTrue(product.waitForExistence(timeout: 5), "did not return to the list")

        app.buttons["finish_recording"].tap()

        let summary = app.staticTexts["export_summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "no export summary after finishing")
        let label = summary.label

        // Three presses happened while recording. Finish itself may or may not be counted,
        // depending on which recogniser reports first, so the bound is three.
        XCTAssertGreaterThanOrEqual(count(of: "tap", in: label), 3, label)
        XCTAssertEqual(count(of: "product_selected", in: label), 1, label)
        XCTAssertEqual(count(of: "back", in: label), 1, label)
        XCTAssertEqual(count(of: "session_start", in: label), 1, label)
        XCTAssertEqual(count(of: "session_end", in: label), 1, label)
    }

    /// Reads "kind N" out of the summary line.
    private func count(of kind: String, in label: String) -> Int {
        for part in label.components(separatedBy: " · ") {
            let pieces = part.split(separator: " ")
            if pieces.count == 2, pieces[0] == Substring(kind) { return Int(pieces[1]) ?? 0 }
        }
        return 0
    }
}
