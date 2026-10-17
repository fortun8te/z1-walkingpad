import Foundation
import Z1Core

/// The build line shown in Settings and About, and the quiet-day reminder schedule.
public func appSupportTests(_ t: TestRunner) {
    t.suite("build-info") { t in
        let release = BuildInfo(info: ["CFBundleShortVersionString": "2.0", "CFBundleVersion": "202610131200"])
        t.expectEqual(release.line, "Z1 2.0 (build 202610131200)", "release build line")
        t.expectEqual(BuildInfo(info: nil).line, "Z1 (development build)", "no bundle, no numbers")
        t.expectEqual(
            BuildInfo(info: ["CFBundleShortVersionString": "2.0"]).line, "Z1 (development build)",
            "half a version is not shown"
        )
    }

    t.suite("walk-reminders") { t in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            // October 2026: the 12th is a Monday.
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        func due(_ now: Date, walk: Date? = nil, sent: [Date] = []) -> Bool {
            WalkReminderPolicy.isDue(now: now, lastWalkEnd: walk, reminders: sent, calendar: calendar)
        }
        func next(_ now: Date, walk: Date? = nil, sent: [Date] = []) -> Date {
            WalkReminderPolicy.nextCheck(after: now, lastWalkEnd: walk, reminders: sent, calendar: calendar)
        }

        t.check(due(at(13, 10), walk: at(13, 6)), "a quiet weekday morning is due")
        t.check(due(at(13, 10)), "no walk ever is quiet enough")
        t.check(!due(at(13, 10), walk: at(13, 8)), "two quiet hours are not enough")
        t.check(!due(at(17, 10), walk: at(16, 6)), "never on a weekend")
        t.check(!due(at(13, 8, 59)), "not before nine")
        t.check(!due(at(13, 18)), "not from six")
        t.check(!due(at(13, 15), sent: [at(13, 10), at(13, 12)]), "at most two a day")
        t.check(!due(at(13, 12), sent: [at(13, 10)]), "two hours after the last is too soon")
        t.check(due(at(13, 13, 30), sent: [at(13, 10)]), "three hours after the last is fine")
        t.check(due(at(14, 10), sent: [at(13, 10), at(13, 14)]), "yesterday's reminders do not count")

        t.expectEqual(next(at(13, 10), walk: at(13, 9, 30)), at(13, 12, 30), "waits for the quiet hours to pass")
        t.expectEqual(next(at(13, 10), walk: at(13, 5)), at(13, 10, 15), "otherwise looks again soon")
        t.expectEqual(next(at(13, 10), walk: at(13, 5), sent: [at(13, 9, 30)]), at(13, 12, 30), "and spaces reminders")
        t.expectEqual(next(at(16, 17, 50)), at(19, 9), "past six waits for the next working morning")
        t.expectEqual(next(at(17, 11)), at(19, 9), "a weekend waits for Monday")
        t.expectEqual(next(at(13, 16), sent: [at(13, 10), at(13, 14)]), at(14, 9), "two sent: tomorrow")
        t.expectEqual(next(at(13, 7)), at(13, 9), "before nine waits for nine")

        // Custom schedules. October 2026: 12 Mon, 13 Tue, 14 Wed, 17 Sat, 18 Sun.
        func dueOn(_ s: WalkReminderSchedule, _ now: Date, sent: [Date] = []) -> Bool {
            WalkReminderPolicy.isDue(now: now, lastWalkEnd: nil, reminders: sent, schedule: s, calendar: calendar)
        }
        func nextOn(_ s: WalkReminderSchedule, _ now: Date, sent: [Date] = []) -> Date {
            WalkReminderPolicy.nextCheck(after: now, lastWalkEnd: nil, reminders: sent, schedule: s, calendar: calendar)
        }
        t.expectEqual(WalkReminderSchedule.standard.summary, "Mon–Fri, 9:00–18:00, up to 2 a day", "default label")

        let weekend = WalkReminderSchedule(days: [7, 1], fromHour: 9, untilHour: 18, perDay: 2)
        t.check(dueOn(weekend, at(17, 10)), "custom days: Saturday is on")
        t.check(!dueOn(weekend, at(13, 10)), "custom days: Tuesday is off")
        t.expectEqual(nextOn(weekend, at(13, 10)), at(17, 9), "custom days: waits for Saturday")
        t.expectEqual(weekend.summary, "Sat, Sun, 9:00–18:00, up to 2 a day", "custom days label")
        t.expectEqual(
            WalkReminderSchedule(days: [2, 4, 5, 6, 7], fromHour: 9, untilHour: 18, perDay: 1).summary,
            "Mon, Wed–Sat, 9:00–18:00, up to 1 a day", "split run label"
        )
        t.expectEqual(
            WalkReminderSchedule(days: Set(1...7), fromHour: 8, untilHour: 24, perDay: 3).summary,
            "Every day, 8:00–0:00, up to 3 a day", "every day label"
        )

        let lunch = WalkReminderSchedule(days: [2, 3, 4, 5, 6], fromHour: 12, untilHour: 14, perDay: 2)
        t.check(dueOn(lunch, at(13, 12)) && dueOn(lunch, at(13, 13, 59)), "custom hours: inside")
        t.check(!dueOn(lunch, at(13, 11, 59)) && !dueOn(lunch, at(13, 14)), "custom hours: outside")
        t.expectEqual(nextOn(lunch, at(13, 15)), at(14, 12), "custom hours: next morning's opening")
        t.expectEqual(nextOn(lunch, at(13, 9)), at(13, 12), "custom hours: today's opening")

        // Overnight: 20:00 to 02:00, Mon and Fri only. The small hours belong to the evening before.
        let night = WalkReminderSchedule(days: [2, 6], fromHour: 20, untilHour: 2, perDay: 2)
        t.check(night.isOvernight, "20 to 2 is overnight")
        t.check(dueOn(night, at(12, 21)), "overnight: Monday evening")
        t.check(dueOn(night, at(13, 1)), "overnight: Tuesday 01:00 is Monday's tail")
        t.check(!dueOn(night, at(13, 2)), "overnight: ends at 02:00")
        t.check(!dueOn(night, at(12, 1)), "overnight: Monday 01:00 is Sunday's tail, which is off")
        t.check(!dueOn(night, at(13, 21)), "overnight: Tuesday evening is off")
        t.check(!dueOn(night, at(12, 19, 59)), "overnight: not before 20:00")
        t.expectEqual(nextOn(night, at(12, 22)), at(12, 22, 15), "overnight: inside the window looks again soon")
        t.expectEqual(nextOn(night, at(13, 3)), at(16, 20), "overnight: waits for Friday evening")

        // Until at or before From never makes an empty window; an all-off day set falls back.
        t.expectEqual(WalkReminderSchedule(days: [2], fromHour: 10, untilHour: 10, perDay: 2).untilHour, 11, "zero length widens to an hour")
        t.expectEqual(WalkReminderSchedule(days: [2], fromHour: 23, untilHour: 23, perDay: 2).untilHour, 24, "late zero length stops at midnight")
        t.expectEqual(WalkReminderSchedule(days: [], fromHour: 9, untilHour: 18, perDay: 2).days, [2, 3, 4, 5, 6], "no days falls back")
        t.expectEqual(WalkReminderSchedule(days: [9, 0], fromHour: 40, untilHour: -3, perDay: 9).perDay, 3, "out-of-range values clamp")

        // The cap.
        let once = WalkReminderSchedule(days: [2, 3, 4, 5, 6], fromHour: 9, untilHour: 18, perDay: 1)
        let thrice = WalkReminderSchedule(days: [2, 3, 4, 5, 6], fromHour: 6, untilHour: 24, perDay: 3)
        t.check(dueOn(once, at(13, 10)), "cap 1: first is due")
        t.check(!dueOn(once, at(13, 16), sent: [at(13, 10)]), "cap 1: second is not")
        t.expectEqual(nextOn(once, at(13, 10, 5), sent: [at(13, 10)]), at(14, 9), "cap 1: next is tomorrow")
        t.check(dueOn(thrice, at(13, 16), sent: [at(13, 7), at(13, 10)]), "cap 3: third is due")
        t.check(!dueOn(thrice, at(13, 22), sent: [at(13, 7), at(13, 10), at(13, 16)]), "cap 3: fourth is not")

        // Stored form survives a round trip, and an untouched store means the old behaviour.
        let suite = UserDefaults(suiteName: "z1.tests.reminder-schedule.\(UUID().uuidString)")!
        t.expectEqual(WalkReminderSchedule(defaults: suite), .standard, "nothing stored means the default schedule")
        night.save(to: suite)
        t.expectEqual(WalkReminderSchedule(defaults: suite), night, "schedule round-trips through defaults")
        suite.set([], forKey: WalkReminderSchedule.daysKey)
        t.expectEqual(WalkReminderSchedule(defaults: suite).days, [2, 3, 4, 5, 6], "corrupt empty days recover")
    }
}

/// How hard the app scans for a pad that is not connected.
public func reconnectPolicyTests(_ t: TestRunner) async {
    t.suite("reconnect-policy") { t in
        let launch = Date(timeIntervalSince1970: 2_000_000_000)
        func minutes(_ m: Double) -> Date { launch.addingTimeInterval(m * 60) }
        var policy = ReconnectPolicy(launchedAt: launch)

        t.expectEqual(policy.pace(at: minutes(0), watched: false), .fast, "fast right after launch")
        t.expectEqual(policy.pace(at: minutes(4.9), watched: false), .fast, "fast for five minutes after launch")
        t.expectEqual(policy.pace(at: minutes(5), watched: false), .slow, "slow once the launch window has passed")
        t.expectEqual(policy.pace(at: minutes(600), watched: false), .slow, "slow for the rest of the day")
        t.expectEqual(policy.pace(at: minutes(600), watched: true), .fast, "fast whenever the window is visible or the app is frontmost")

        policy.lastWake = minutes(600)
        t.expectEqual(policy.pace(at: minutes(602), watched: false), .fast, "fast after a wake")
        t.expectEqual(policy.pace(at: minutes(605), watched: false), .slow, "slow again five minutes after the wake")
        t.expectEqual(policy.pace(at: minutes(599), watched: false), .fast, "a clock set back counts as fast: that is the safe side")

        policy.lastLinkLoss = minutes(700)
        t.expectEqual(policy.pace(at: minutes(703), watched: false), .fast, "fast just after a link is lost")
        t.expectEqual(policy.pace(at: minutes(706), watched: false), .slow, "slow again once the loss is old")

        t.expectEqual(ReconnectPolicy.scanTimeout(for: .fast), Z1Constants.scanTimeout, "fast keeps the full scan")
        t.expectEqual(ReconnectPolicy.scanTimeout(for: .slow), 10, "slow scans for 10 s")
        t.expectEqual(ReconnectPolicy.slowScanTimeout + ReconnectPolicy.slowPause, 120, "a slow cycle is two minutes")
        t.expectEqual(ReconnectPolicy.pause(afterAttempt: 1, pace: .slow), 110, "slow pause, first try")
        t.expectEqual(ReconnectPolicy.pause(afterAttempt: 9, pace: .slow), 110, "slow pause stays flat")
        let fast = (1...7).map { ReconnectPolicy.pause(afterAttempt: $0, pace: .fast) }
        t.expectEqual(fast, [2, 4, 8, 16, 30, 30, 30], "fast backs off to 30 s")
        t.expectEqual(ReconnectPolicy.pause(afterAttempt: 0, pace: .fast), 2, "attempt zero is treated as the first")
    }

    await t.suite("reconnect-policy scan timeout reaches the transport") { t in
        let pad = ScriptedPad()
        let driver = Z1Treadmill(transport: pad, defaults: CountingDefaults.isolated())
        do {
            try await driver.connect(scanTimeout: ReconnectPolicy.slowScanTimeout)
            await driver.disconnect()
            try await driver.connect()
            await driver.disconnect()
        } catch { t.check(false, "scripted connect: \(error)") }
        t.expectEqual(pad.scanTimeouts, [10, Z1Constants.scanTimeout], "the caller's scan length is used, the default is the full scan")
    }
}

/// A remembered pad survives a connect that merely timed out.
public func rememberedPadTests(_ t: TestRunner) async {
    await t.suite("remembered-pad") { t in
        let key = "z1.knownPeripheralID"
        let id = UUID().uuidString
        for (error, kept, label) in [
            (BLETransportError.timeout as Error, true, "a timeout keeps the remembered pad"),
            (BLETransportError.notConnected as Error, false, "any other failure forgets it"),
        ] {
            let pad = ScriptedPad()
            pad.adoptedName = "KS-HD-Z1D"
            pad.connectError = error
            // The driver gets its own handle; the test reads the same domain.
            let suite = "z1tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(id, forKey: key)
            let driver = Z1Treadmill(transport: pad, defaults: UserDefaults(suiteName: suite)!)
            do {
                try await driver.connect()
                t.check(false, "\(label): the connect should fail")
            } catch {}
            t.expectEqual(defaults.string(forKey: key) == id, kept, label)
            t.expectEqual(pad.scanTimeouts.count, 0, "\(label): the remembered pad was used, no scan")
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
