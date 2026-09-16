import XCTest
@testable import MacBatteryCore

final class PowerEstimateTests: XCTestCase {

    func testIdle() {
        // tdp=45, u=0 → 45×0.05 + 7 = 9.25
        XCTAssertEqual(PowerEstimate.watts(tdp: 45, usage: 0), 9.25, accuracy: 1e-9)
    }

    func testFullLoad() {
        // tdp=45, u=1 → 45×1.0 + 10 = 55
        XCTAssertEqual(PowerEstimate.watts(tdp: 45, usage: 1), 55, accuracy: 1e-9)
    }

    func testUsageClampedToUnitRange() {
        XCTAssertEqual(PowerEstimate.watts(tdp: 45, usage: -1),
                       PowerEstimate.watts(tdp: 45, usage: 0),
                       accuracy: 1e-9)
        XCTAssertEqual(PowerEstimate.watts(tdp: 45, usage: 2),
                       PowerEstimate.watts(tdp: 45, usage: 1),
                       accuracy: 1e-9)
    }

    func testMonotonicInUsage() {
        XCTAssertLessThan(PowerEstimate.watts(tdp: 45, usage: 0.3),
                          PowerEstimate.watts(tdp: 45, usage: 0.6))
    }

    func testZeroTdpStillHasPlatformPower() {
        XCTAssertEqual(PowerEstimate.watts(tdp: 0, usage: 0), 7, accuracy: 1e-9)
        XCTAssertEqual(PowerEstimate.watts(tdp: 0, usage: 1), 10, accuracy: 1e-9)
    }
}
