import XCTest
@testable import FormFlowCore

final class TrackingTests: XCTestCase {
    func testPartialBodyEditPreservesOtherReadingAndIdentity() throws {
        let day = try LocalTrainingDay(date: "2026-09-16", timeZoneID: "Asia/Singapore")
        var record = try BodyMeasurementRecord(day: day, weight: .init(value: 72.4, unit: .kg), waist: .init(value: 84, unit: .cm))
        let id = record.id
        try record.edit(waist: .set(.init(value: 83.5, unit: .cm)))
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.weight?.value, 72.4)
        XCTAssertEqual(record.waist?.value, 83.5)
        try record.edit(weight: .clear)
        XCTAssertNil(record.weight)
        XCTAssertThrowsError(try record.edit(waist: .clear))
        XCTAssertEqual(record.waist?.value, 83.5, "A rejected edit cannot partially mutate the record")
    }
    func testUnknownSleepIsNotZeroAndEditingKeepsIdentity() throws {
        let day = try LocalTrainingDay(date: "2026-09-16", timeZoneID: "America/New_York")
        var record = try ManualSleepRecord(day: day, hours: nil)
        let id = record.id
        var summary = try XCTUnwrap(TrackingSummary.sleepWeeks([record]).first)
        XCTAssertNil(summary.meanHours); XCTAssertEqual(summary.recordedNights, 0); XCTAssertEqual(summary.unknownNights, 1)
        try record.edit(day: day, hours: 7.5)
        summary = try XCTUnwrap(TrackingSummary.sleepWeeks([record]).first)
        XCTAssertEqual(record.id, id); XCTAssertEqual(summary.meanHours, 7.5)
        XCTAssertThrowsError(try record.edit(day: day, hours: 25))
        XCTAssertEqual(record.hours, 7.5)
    }
    func testLocalDayAndUnitsDoNotDependOnCurrentTimeZone() throws {
        XCTAssertThrowsError(try LocalTrainingDay(date: "2026-02-30", timeZoneID: "UTC"))
        XCTAssertThrowsError(try LocalTrainingDay(date: "2026-09-18", timeZoneID: "Not/AZone"))
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-17T20:00:00Z"))
        let day = LocalTrainingDay(instant: instant, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Singapore")))
        XCTAssertEqual(day.date, "2026-09-18")
        let body = try BodyMeasurementRecord(day: day, weight: .init(value: 100, unit: .lb), waist: .init(value: 30, unit: .inch))
        XCTAssertEqual(try XCTUnwrap(body.weightKilograms), 45.359237, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(body.waist?.centimeters), 76.2, accuracy: 0.000001)
    }
}
