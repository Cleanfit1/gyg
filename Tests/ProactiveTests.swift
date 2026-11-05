import XCTest
@testable import Xiaopihai

final class ProactiveTests: XCTestCase {
    func testNoDuplicateOrEmptyCandidates() {
        let now = Date(timeIntervalSince1970: 1_793_836_800)
        let plan = ProactivePlanner.plan(texts: ["", " 去吃饭 ", "去吃饭", "学完了吗", "早点睡", "第四条"], now: now)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(Set(plan.map(\.content)).count, 3)
        for (index, item) in plan.enumerated() {
            XCTAssertGreaterThan(item.fireAt, now)
            XCTAssertLessThanOrEqual(item.fireAt.timeIntervalSince(now), 24 * 3600)
            if index > 0 { XCTAssertGreaterThanOrEqual(item.fireAt.timeIntervalSince(plan[index - 1].fireAt), 90 * 60) }
        }
    }

    func testQuietHoursAcrossDifferentStartTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for hour in 0..<24 {
            let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: hour))!
            for item in ProactivePlanner.plan(texts: ["第一条", "第二条", "第三条"], now: start) {
                let pieces = calendar.dateComponents([.hour, .minute], from: item.fireAt)
                let minute = pieces.hour! * 60 + pieces.minute!
                XCTAssertTrue((9 * 60 ... 21 * 60 + 30).contains(minute))
            }
        }
    }

    func testDueMessageDoesNotCreateNewNotification() {
        let now = Date()
        let past = ScheduledMessage(content: "过期消息", fireAt: now.addingTimeInterval(-10))
        XCTAssertNil(ProactivePlanner.notification(for: past, now: now))
        let future = ScheduledMessage(content: "未来消息", fireAt: now.addingTimeInterval(3600))
        let request = ProactivePlanner.notification(for: future, now: now)
        XCTAssertEqual(request?.identifier, future.id.uuidString)
        XCTAssertEqual(request?.content.body, future.content)
    }

    func testOldArchiveMigratesWithoutLosingData() throws {
        let legacy: [String: Any] = ["schemaVersion": 1, "memories": [], "messages": [],
            "settings": ["relationship": "分手后", "proactivity": 0.55, "emotionalVariation": 0.55,
                         "intimacy": 0.35, "notifications": false]]
        let archive = try JSONDecoder().decode(LocalArchive.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(archive.schemaVersion, 2)
        XCTAssertTrue(archive.scheduledMessages.isEmpty)
        XCTAssertNil(archive.model)
        let roundtrip = try JSONDecoder().decode(LocalArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(roundtrip.settings.relationship, "分手后")
    }

    func testFutureArchiveIsNotSilentlyOverwritten() throws {
        let future = Data("{\"schemaVersion\":99}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalArchive.self, from: future))
    }
}
