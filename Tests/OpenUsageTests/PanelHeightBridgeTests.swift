import XCTest
@testable import OpenUsage

@MainActor
final class PanelHeightBridgeTests: XCTestCase {
    func testCoalescesBurstToNewestHeight() async {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        let firstApply = expectation(description: "applies coalesced height")
        let secondApply = expectation(description: "does not replay stale heights")
        secondApply.isInverted = true

        MenuBarPopover.applyHeight = { height in
            applied.append(height)
            if applied.count == 1 {
                firstApply.fulfill()
            } else {
                secondApply.fulfill()
            }
        }

        PanelHeightBridge.push(520)
        PanelHeightBridge.push(560)
        PanelHeightBridge.push(600)

        await fulfillment(of: [firstApply], timeout: 1)
        await fulfillment(of: [secondApply], timeout: 0.05)
        XCTAssertEqual(applied, [600])
    }

    func testInvalidateDropsQueuedHeight() async {
        resetBridge()
        defer { resetBridge() }

        let droppedApply = expectation(description: "drops queued height")
        droppedApply.isInverted = true
        MenuBarPopover.applyHeight = { _ in droppedApply.fulfill() }

        PanelHeightBridge.push(600)
        PanelHeightBridge.invalidate()

        await fulfillment(of: [droppedApply], timeout: 0.05)
    }

    private func resetBridge() {
        PanelHeightBridge.invalidate()
        MenuBarPopover.applyHeight = nil
    }
}
