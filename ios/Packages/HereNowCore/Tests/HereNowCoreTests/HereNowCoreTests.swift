import XCTest
@testable import HereNowCore

final class MomentResolverTests: XCTestCase {
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func snapshot(events: [ScheduleEvent] = [], place: PlacePrompt = .init()) -> FamilySnapshot {
        FamilySnapshot(profile: .init(callName: "妈妈", timeZoneID: "Asia/Shanghai"), place: place, events: events)
    }

    func event(_ id: String, start: String, until: String, from: String? = nil, preferred: Bool = false) -> ScheduleEvent {
        ScheduleEvent(id: id, personName: id, line: "\(id)计划来", start: date(start),
                      showFrom: date(from ?? "2026-11-22T00:00:00+08:00"), showUntil: date(until), preferredOnTie: preferred)
    }

    func testSegmentUsesPatientTimeZoneNotDeviceTimeZone() {
        // 06:30 UTC is 14:30 in Shanghai; a caregiver phone in London must still see 下午.
        let moment = MomentResolver.resolve(.init(snapshot: snapshot(), now: date("2026-11-22T06:30:00Z")))
        XCTAssertEqual(moment.segmentName, "下午")
        let beforeMidnight = MomentResolver.resolve(.init(snapshot: snapshot(), now: date("2026-11-22T15:59:00Z")))
        let afterMidnight = MomentResolver.resolve(.init(snapshot: snapshot(), now: date("2026-11-22T16:01:00Z")))
        XCTAssertEqual(beforeMidnight.segmentName, "夜里")
        XCTAssertEqual(afterMidnight.segmentName, "夜里", "00:01 precedes 清晨 and wraps to the last segment")
        XCTAssertEqual(MomentResolver.dateLine(date("2026-11-22T16:01:00Z"), in: shanghai), "11月23日 星期一")
    }

    func testShowsEarliestLiveEventAndRemovesItAtShowUntil() {
        let s = snapshot(events: [
            event("later", start: "2026-11-22T18:00:00+08:00", until: "2026-11-22T20:00:00+08:00"),
            event("soon", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T16:00:00+08:00"),
        ])
        let at1500 = MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-22T15:30:00+08:00")))
        XCTAssertEqual(at1500.card?.kind, .event(id: "soon"), "reaching start time does not complete or hide the event")
        let at1600 = MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-22T16:00:00+08:00")))
        XCTAssertEqual(at1600.card?.kind, .event(id: "later"))
    }

    func testRetiredEventsStayGoneAfterClockGoesBack() {
        let s = snapshot(events: [event("a", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T16:00:00+08:00")])
        let retired = MomentResolver.expiredEventIDs(in: s, now: date("2026-11-22T16:05:00+08:00"))
        XCTAssertEqual(retired, ["a"])
        let wound = MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-22T15:10:00+08:00"), retiredEventIDs: retired))
        XCTAssertNil(wound.card)
    }

    func testTieUsesCaregiverPreferenceAndValidatorBlocksUnresolvedTie() {
        let a = event("a", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T17:00:00+08:00")
        var b = event("b", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T17:00:00+08:00")
        let now = date("2026-11-22T10:00:00+08:00")
        let issues = PublishValidator.validate(snapshot(events: [a, b]), now: now) { _, _ in true }
        XCTAssertTrue(issues.contains { $0.id.hasPrefix("event.tie") && $0.severity == .blocking })
        b.preferredOnTie = true
        let resolved = snapshot(events: [a, b])
        XCTAssertFalse(PublishValidator.hasBlocking(PublishValidator.validate(resolved, now: now) { _, _ in true }))
        XCTAssertEqual(MomentResolver.currentEvent(in: resolved, now: now)?.id, "b")
    }

    func testValidatorRejectsShowUntilBeforeStartAndOverlongLines() {
        let bad = event("x", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T14:00:00+08:00")
        let issues = PublishValidator.validate(snapshot(events: [bad]), now: date("2026-11-22T10:00:00+08:00")) { _, _ in false }
        XCTAssertTrue(issues.contains { $0.id == "event.until.x" })
        XCTAssertTrue(issues.contains { $0.id == "event.fit.x" })
    }

    func testEditedEventDropsStaleRecordingAndFallsBackOnlyWhenAllowed() {
        var e = event("小雨", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T17:00:00+08:00")
        e.recording = Recording(assetID: "rec1", speakerLabel: "小雨", recordedAt: Date(), durationSeconds: 5,
                                confirmedFingerprint: e.fingerprint)
        var s = snapshot(events: [e])
        let now = date("2026-11-22T12:00:00+08:00")
        let fresh = MomentResolver.resolve(.init(snapshot: s, now: now, availableAssets: ["rec1"]))
        XCTAssertEqual(fresh.audio, .recording(assetID: "rec1", speakerLabel: "小雨"))

        s.events[0].start = date("2026-11-22T16:00:00+08:00")
        let stale = MomentResolver.resolve(.init(snapshot: s, now: now, availableAssets: ["rec1"]))
        XCTAssertNil(stale.audio, "a moved event must not keep playing the old recording, and speech is off by default")

        s.voice.systemSpeechFallback = true
        let spoken = MomentResolver.resolve(.init(snapshot: s, now: now, availableAssets: ["rec1"]))
        XCTAssertEqual(spoken.audio, .speech(text: "妈妈，小雨计划来", languageCode: "zh-CN"))
        let noVoice = MomentResolver.resolve(.init(snapshot: s, now: now, availableAssets: ["rec1"], speechAvailable: false))
        XCTAssertNil(noVoice.audio, "no button when nothing can actually play")
    }

    func testBrokenRecordingAndPausedSoundKeepTheText() {
        var e = event("a", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T17:00:00+08:00")
        e.recording = Recording(assetID: "r", speakerLabel: "", recordedAt: Date(), durationSeconds: 3, confirmedFingerprint: e.fingerprint)
        let s = snapshot(events: [e])
        let now = date("2026-11-22T12:00:00+08:00")
        let broken = MomentResolver.resolve(.init(snapshot: s, now: now, availableAssets: ["r"], brokenAssets: ["r"]))
        XCTAssertNil(broken.audio)
        XCTAssertEqual(broken.card?.line, "a计划来")
        let paused = MomentResolver.resolve(.init(snapshot: s, controls: .init(soundPaused: true), now: now, availableAssets: ["r"]))
        XCTAssertNil(paused.audio)
        XCTAssertNotNil(paused.card)
    }

    func testCancelledEventFallsBackToPlaceAndPlaceExpiresAtReview() {
        var e = event("a", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T17:00:00+08:00")
        e.isCancelled = true
        let place = PlacePrompt(enabled: true, line: "这里是家里的客厅", reviewBy: date("2026-11-30T00:00:00+08:00"))
        let s = snapshot(events: [e], place: place)
        XCTAssertEqual(MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-22T15:30:00+08:00"))).card?.kind, .place)
        XCTAssertNil(MomentResolver.resolve(.init(snapshot: s, now: date("2026-12-01T10:00:00+08:00"))).card)
    }

    func testLeaseExpiryAndPauseHideAllPersonalContent() {
        let s = snapshot(place: .init(enabled: true, line: "这里是家里的客厅", reviewBy: date("2027-01-01T00:00:00Z")))
        let now = date("2026-11-22T10:00:00+08:00")
        let expired = MomentResolver.resolve(.init(snapshot: s, now: now, leaseExpiresAt: now.addingTimeInterval(-1)))
        XCTAssertEqual(expired.mode, .neutral(.leaseExpired))
        XCTAssertNil(expired.card)
        XCTAssertNil(expired.audio)
        let paused = MomentResolver.resolve(.init(snapshot: s, controls: .init(displayPaused: true), now: now))
        XCTAssertEqual(paused.mode, .neutral(.paused))
        XCTAssertNil(paused.card)
    }

    func testClockSuspectSuspendsEventPrompts() {
        let s = snapshot(events: [event("a", start: "2026-11-22T15:00:00+08:00", until: "2026-11-22T17:00:00+08:00")])
        let moment = MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-22T15:30:00+08:00"), clockSuspect: true))
        XCTAssertNil(moment.card)
        XCTAssertEqual(moment.mode, .neutral(.clockSuspect))
    }

    func testNightHidesPhotoButKeepsSentence() {
        let place = PlacePrompt(enabled: true, line: "这里是家里的卧室", photoAssetID: "p", reviewBy: date("2027-01-01T00:00:00Z"))
        let s = snapshot(place: place)
        let night = MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-22T23:00:00+08:00"), availableAssets: ["p"]))
        XCTAssertEqual(night.palette, .night)
        XCTAssertNil(night.card?.photoAssetID)
        XCTAssertEqual(night.card?.line, "这里是家里的卧室")
        let day = MomentResolver.resolve(.init(snapshot: s, now: date("2026-11-22T10:00:00+08:00"), availableAssets: ["p"]))
        XCTAssertEqual(day.card?.photoAssetID, "p")
    }

    func testSuggestedLineUsesPatientSegments() {
        let s = snapshot()
        let start = date("2026-11-23T15:00:00+08:00")
        XCTAssertEqual(EventWording.suggestedLine(person: "小雨", start: start, showFrom: date("2026-11-23T00:00:00+08:00"), snapshot: s),
                       "小雨计划下午 3 点来")
        XCTAssertEqual(EventWording.suggestedLine(person: "小雨", start: start, showFrom: date("2026-11-22T00:00:00+08:00"), snapshot: s),
                       "小雨计划周一下午 3 点来")
    }
}

final class MergeAndClockTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testOtherDevicesCancellationIsNotRevivedByAStaleEdit() {
        let original = ScheduleEvent(id: "e", personName: "小雨", line: "小雨计划下午 3 点来", start: base,
                                     showFrom: base.addingTimeInterval(-3600), showUntil: base.addingTimeInterval(3600))
        let baseSnap = FamilySnapshot(profile: .init(callName: "妈妈", timeZoneID: "Asia/Shanghai"), events: [original])
        var mine = baseSnap
        mine.events[0].line = "小雨计划下午 4 点来"
        var theirs = baseSnap
        theirs.events[0].isCancelled = true
        let result = SnapshotMerger.merge(base: baseSnap, mine: mine, theirs: theirs)
        XCTAssertTrue(result.snapshot.events[0].isCancelled)
        XCTAssertEqual(result.notes.count, 1)
    }

    func testIndependentChangesBothSurvive() {
        let e = ScheduleEvent(id: "e", personName: "小雨", line: "x", start: base, showFrom: base, showUntil: base.addingTimeInterval(60))
        let baseSnap = FamilySnapshot(profile: .init(callName: "妈妈", timeZoneID: "Asia/Shanghai"), events: [e])
        var mine = baseSnap
        mine.display.showDate = true
        let added = ScheduleEvent(id: "new", personName: "阿明", line: "y", start: base, showFrom: base, showUntil: base.addingTimeInterval(60))
        mine.events.append(added)
        var theirs = baseSnap
        theirs.place = PlacePrompt(enabled: true, line: "这里是家", reviewBy: base)
        let result = SnapshotMerger.merge(base: baseSnap, mine: mine, theirs: theirs)
        XCTAssertTrue(result.snapshot.display.showDate)
        XCTAssertTrue(result.snapshot.place.enabled)
        XCTAssertEqual(result.snapshot.events.map(\.id), ["e", "new"])
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testClockGuardFlagsBackwardJumpAndServerClearsIt() {
        var guardian = ClockGuard()
        guardian.observe(wall: base, uptime: 1000)
        guardian.observe(wall: base.addingTimeInterval(60), uptime: 1060)
        XCTAssertFalse(guardian.suspect)
        guardian.observe(wall: base.addingTimeInterval(-3600), uptime: 1120)
        XCTAssertTrue(guardian.suspect)
        guardian.compare(serverTime: base.addingTimeInterval(-3590), deviceTime: base.addingTimeInterval(-3600), uptime: 1121)
        XCTAssertFalse(guardian.suspect)
        guardian.compare(serverTime: base, deviceTime: base.addingTimeInterval(900), uptime: 1122)
        XCTAssertTrue(guardian.suspect)
    }

    func testClockGuardAfterRebootComparesWithLatestSeenTime() {
        var guardian = ClockGuard()
        guardian.observe(wall: base, uptime: 50_000)
        guardian.observe(wall: base.addingTimeInterval(30), uptime: 20)
        XCTAssertFalse(guardian.suspect)
        guardian.observe(wall: base.addingTimeInterval(-86_400), uptime: 40)
        XCTAssertTrue(guardian.suspect)
    }

    func testPatientPalettesMeetContrastTargets() {
        for palette in [Moment.Palette.day, .evening, .night] {
            let p = PatientPalette.of(palette)
            for bg in [p.backgroundTop, p.backgroundBottom] {
                XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.timeText), RGB(hex: bg)), 4.5, "\(palette) time")
                XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.secondaryTimeText), RGB(hex: bg)), 4.5, "\(palette) date")
                XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.card), RGB(hex: bg)), 1.0)
            }
            XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.cardText), RGB(hex: p.card)), 4.5, "\(palette) card")
            XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.playText), RGB(hex: p.playFill)), 4.5, "\(palette) play label")
            XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.stopText), RGB(hex: p.stopFill)), 4.5, "\(palette) stop label")
            XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.playFill), RGB(hex: p.card)), 3, "\(palette) play boundary")
            XCTAssertGreaterThanOrEqual(RGB.contrast(RGB(hex: p.stopFill), RGB(hex: p.card)), 3, "\(palette) stop boundary")
        }
    }
}
