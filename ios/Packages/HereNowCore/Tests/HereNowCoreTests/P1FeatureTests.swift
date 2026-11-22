import XCTest
@testable import HereNowCore

final class P1FeatureTests: XCTestCase {
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func snapshot() -> FamilySnapshot {
        FamilySnapshot(profile: .init(callName: "妈妈", timeZoneID: "Asia/Shanghai"))
    }

    // 2026-11-28 is a Saturday.
    func saturdayVisit(skipped: [String] = []) -> RecurringEvent {
        RecurringEvent(id: "visit", personName: "小雨", line: "小雨计划下午 3 点来", weekdays: [7], startMinute: 15 * 60,
                       showForMinutes: 120, firstDay: "2026-11-01", skippedDays: skipped)
    }

    func testRecurringOccurrenceShowsOnItsDayInPatientZoneOnly() {
        var s = snapshot()
        s.recurring = [saturdayVisit()]
        let saturdayMorning = date("2026-11-28T09:00:00+08:00")
        XCTAssertEqual(MomentResolver.resolve(.init(snapshot: s, now: saturdayMorning)).card?.kind, .event(id: "visit@2026-11-28"))
        XCTAssertNil(MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-27T20:00:00+08:00"))).card,
                     "Friday evening in Shanghai is still before the Saturday occurrence starts showing")
        XCTAssertNil(MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-28T17:00:00+08:00"))).card)
    }

    func testSkippingOneDayAndCancellingThePlan() {
        var s = snapshot()
        s.recurring = [saturdayVisit(skipped: ["2026-11-28"])]
        XCTAssertNil(MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-28T09:00:00+08:00"))).card)
        XCTAssertEqual(MomentResolver.resolve(.init(snapshot: s, now: date("2026-12-05T09:00:00+08:00"))).card?.kind,
                       .event(id: "visit@2026-12-05"))
        s.recurring[0].isCancelled = true
        XCTAssertNil(MomentResolver.resolve(.init(snapshot: s, now: date("2026-12-05T09:00:00+08:00"))).card)
    }

    func testEditingARecurringPlanMakesItsRecordingStale() {
        var plan = saturdayVisit()
        plan.recording = Recording(assetID: "r", speakerLabel: "小雨", recordedAt: Date(), durationSeconds: 4, confirmedFingerprint: plan.fingerprint)
        var s = snapshot()
        s.recurring = [plan]
        let now = date("2026-11-28T09:00:00+08:00")
        XCTAssertEqual(MomentResolver.resolve(.init(snapshot: s, now: now, availableAssets: ["r"])).audio,
                       .recording(assetID: "r", speakerLabel: "小雨"))
        s.recurring[0].startMinute = 16 * 60
        XCTAssertNil(MomentResolver.resolve(.init(snapshot: s, now: now, availableAssets: ["r"])).audio)
    }

    func testOldSnapshotsDecodeWithP1FeaturesOff() throws {
        let old = """
        {"schemaVersion":1,"profile":{"callName":"妈妈","timeZoneID":"Asia/Shanghai","languageCode":"zh-CN"},
        "segments":[],"night":{"startMinute":0,"endMinute":0,"hidePhoto":true},
        "display":{"showDate":false,"focus":"automatic","textScale":"standard","neutralLine":""},
        "voice":{"systemSpeechFallback":false,"addressByName":true},"place":{"enabled":false,"line":""},
        "events":[],"assetRefs":[]}
        """
        let decoded = try JSONDecoder().decode(FamilySnapshot.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.autoPlay.enabled)
        XCTAssertFalse(decoded.playLog.enabled)
        XCTAssertTrue(decoded.recurring.isEmpty)
    }

    // MARK: Greetings

    func greetingContext(now: Date, foregroundSince: Date, ledger: AutoPlayLedger = .init(),
                         controls: DeviceControls = .init()) -> AutoPlayPlanner.Context {
        var s = snapshot()
        s.voice.systemSpeechFallback = true
        s.autoPlay = AutoPlaySettings(enabled: true, leadMinutes: 30)
        s.events = [ScheduleEvent(id: "e", personName: "小雨", line: "小雨计划下午 3 点来", start: date("2026-11-22T15:00:00+08:00"),
                                  showFrom: date("2026-11-22T00:00:00+08:00"), showUntil: date("2026-11-22T17:00:00+08:00"))]
        let moment = MomentResolver.resolve(.init(snapshot: s, controls: controls, now: now))
        return .init(snapshot: s, moment: moment, controls: controls, now: now, foregroundSince: foregroundSince,
                     isPlaying: false, clockSuspect: false, ledger: ledger)
    }

    func testGreetingPlaysOnceWhenItsTimeArrivesInTheForeground() {
        let at = date("2026-11-22T14:30:30+08:00")
        let key = AutoPlayPlanner.trigger(greetingContext(now: at, foregroundSince: date("2026-11-22T13:00:00+08:00")))
        XCTAssertNotNil(key)
        var ledger = AutoPlayLedger()
        ledger.record(key!, at: at)
        XCTAssertNil(AutoPlayPlanner.trigger(greetingContext(now: at.addingTimeInterval(30), foregroundSince: date("2026-11-22T13:00:00+08:00"), ledger: ledger)))
    }

    func testGreetingMissedInBackgroundOrOfflineIsNeverPlayedLate() {
        let late = date("2026-11-22T14:40:00+08:00")
        XCTAssertNil(AutoPlayPlanner.trigger(greetingContext(now: late, foregroundSince: date("2026-11-22T13:00:00+08:00"))),
                     "ten minutes after the trigger is too late")
        let returned = date("2026-11-22T14:30:30+08:00")
        XCTAssertNil(AutoPlayPlanner.trigger(greetingContext(now: returned, foregroundSince: date("2026-11-22T14:30:10+08:00"))),
                     "the app came to the foreground after the trigger time")
    }

    func testPausedSoundBlocksGreeting() {
        let at = date("2026-11-22T14:30:30+08:00")
        XCTAssertNil(AutoPlayPlanner.trigger(greetingContext(now: at, foregroundSince: date("2026-11-22T13:00:00+08:00"),
                                                             controls: .init(soundPaused: true))))
    }

    // MARK: Play log

    func testPlayLogSeparatesNoUseFromNoCoverage() {
        let now = date("2026-11-22T20:00:00+08:00")
        let entries = [PlayLogEntry(at: date("2026-11-22T10:00:00+08:00"), kind: .started, trigger: .button, source: "rec"),
                       PlayLogEntry(at: date("2026-11-22T10:00:20+08:00"), kind: .finished, trigger: .button, source: "rec")]
        let coverage = [CoverageSpan(start: date("2026-11-22T09:00:00+08:00"), end: date("2026-11-22T11:00:00+08:00"))]
        let days = PlayLogSummary.days(entries: entries, coverage: coverage, zone: zone, endingAt: now, count: 2)
        XCTAssertEqual(days[0].buttonStarts, 1)
        XCTAssertEqual(days[0].coveredMinutes, 120)
        XCTAssertEqual(days[1].coveredMinutes, 0, "yesterday has no data, which must not read as zero use")
    }

    // MARK: Voice drafts

    let monday = ISO8601DateFormatter().date(from: "2026-11-23T09:00:00+08:00")!

    func testVoiceDraftParsesPersonDayAndTime() {
        let draft = VoiceDraftParser.parse("小雨明天下午三点来", now: monday, zone: zone)
        XCTAssertEqual(draft.personName, "小雨")
        XCTAssertEqual(draft.start, date("2026-11-24T15:00:00+08:00"))
        XCTAssertTrue(draft.issues.isEmpty, "\(draft.issues)")
    }

    func testVoiceDraftWeekdayAndHalfHour() {
        let draft = VoiceDraftParser.parse("周六上午十点半阿明会过来", now: monday, zone: zone)
        XCTAssertEqual(draft.personName, "阿明")
        XCTAssertEqual(draft.start, date("2026-11-28T10:30:00+08:00"))
    }

    func testVoiceDraftFlagsAmbiguityInsteadOfGuessingSilently() {
        let pronoun = VoiceDraftParser.parse("她晚一点来", now: monday, zone: zone)
        XCTAssertNil(pronoun.personName)
        XCTAssertNil(pronoun.start)
        XCTAssertTrue(pronoun.issues.contains { $0.contains("晚一点") })
        XCTAssertTrue(pronoun.issues.contains { $0.contains("是谁") })
        let bareHour = VoiceDraftParser.parse("小雨明天3点来", now: monday, zone: zone)
        XCTAssertTrue(bareHour.issues.contains { $0.contains("上午还是下午") })
    }
}
