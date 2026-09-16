import XCTest
@testable import MacBatteryCore

final class VersionCompareTests: XCTestCase {

    func testNewerPatchVersion() {
        XCTAssertTrue(VersionCompare.isNewer("1.1.12", than: "1.1.11"))
        XCTAssertFalse(VersionCompare.isNewer("1.1.11", than: "1.1.12"))
    }

    func testNumericComparisonNotStringComparison() {
        // 字符串比较会判错："10" < "9"。必须按数字段比较。
        XCTAssertTrue(VersionCompare.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(VersionCompare.isNewer("1.1.10", than: "1.1.9"))
    }

    func testVPrefixStripped() {
        XCTAssertTrue(VersionCompare.isNewer("v1.1.12", than: "1.1.11"))
        XCTAssertTrue(VersionCompare.isNewer("V1.1.12", than: "1.1.11"))
        XCTAssertFalse(VersionCompare.isNewer("v1.1.11", than: "1.1.11"))
    }

    func testNonNumericSuffixIgnored() {
        XCTAssertTrue(VersionCompare.isNewer("1.1.12-beta", than: "1.1.11"))
        XCTAssertFalse(VersionCompare.isNewer("1.1.11-beta", than: "1.1.12"))
    }

    func testEqualIsNotNewer() {
        XCTAssertFalse(VersionCompare.isNewer("1.1.11", than: "1.1.11"))
        // 段数不同但数值相等都视为同版本：1.1 == 1.1.0。
        XCTAssertFalse(VersionCompare.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(VersionCompare.isNewer("1.1.0", than: "1.1"))
    }

    func testGarbageIsNotNewer() {
        XCTAssertFalse(VersionCompare.isNewer("", than: "1.1.11"))
        XCTAssertFalse(VersionCompare.isNewer("latest", than: "1.1.11"))
    }
}
