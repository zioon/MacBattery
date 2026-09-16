import XCTest
@testable import MacBatteryCore

final class SampleMergeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var t1: Date { t0.addingTimeInterval(60) }
    private var t2: Date { t0.addingTimeInterval(120) }
    private var t3: Date { t0.addingTimeInterval(180) }

    /// 带载荷的测试样本：用于验证「同时间戳 new 覆盖 history」这一文档承诺。
    private struct Sample {
        let t: Date
        let value: Int
    }

    func testMergesBothSidesSortedAscending() {
        let out = mergedByTimestamp(history: [t2, t0],          // 故意乱序
                                    new: [t1],
                                    timestamp: { $0 },
                                    capacity: 10)
        XCTAssertEqual(out, [t0, t1, t2])
    }

    func testSameTimestampNewWinsOverHistory() {
        let out = mergedByTimestamp(history: [Sample(t: t1, value: 1)],
                                    new: [Sample(t: t1, value: 2)],
                                    timestamp: { $0.t },
                                    capacity: 10)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.value, 2, "同时间戳时应由内存新采样覆盖磁盘历史")
    }

    func testNewOnly() {
        let out = mergedByTimestamp(history: [], new: [t1, t0], timestamp: { $0 }, capacity: 10)
        XCTAssertEqual(out, [t0, t1])
    }

    func testHistoryOnly() {
        let out = mergedByTimestamp(history: [t0], new: [], timestamp: { $0 }, capacity: 10)
        XCTAssertEqual(out, [t0])
    }

    func testEmpty() {
        XCTAssertTrue(mergedByTimestamp(history: [], new: [], timestamp: { $0 }, capacity: 10).isEmpty)
    }

    func testTrimsFromOldestEnd() {
        let out = mergedByTimestamp(history: [t0, t1, t2, t3], new: [], timestamp: { $0 }, capacity: 2)
        XCTAssertEqual(out, [t2, t3], "超出容量时应从最旧的一端裁剪")
    }

    func testCapacityNeverExceeded() {
        let out = mergedByTimestamp(history: [t0, t1, t2], new: [t3], timestamp: { $0 }, capacity: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out, [t1, t2, t3])
    }
}
