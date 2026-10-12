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
