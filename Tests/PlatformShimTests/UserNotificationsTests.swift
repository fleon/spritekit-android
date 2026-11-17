import Foundation
import Testing
@testable import PlatformShim

// UserNotifications over the platform channel, driven by the events
// `PlatformNotifications.java` would send. The values pinned in the first
// suite were measured against Apple's UserNotifications on macOS 27.2
// (Xcode 27.2's SDK; `.ephemeral` from the iOS SDK's header, as macOS has none).

private let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func content(title: String = "Reminder", body: String = "Something new is waiting") -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = ["route": "reminder"]
    return content
}

/// As a game's `AppDelegate` writes it: the completion-handler forms,
/// spelled without `@Sendable`.
private final class CompletionDelegate: UNUserNotificationCenterDelegate {
    var presented: [UNNotification] = []
    var responses: [UNNotificationResponse] = []
    var options: UNNotificationPresentationOptions = [.banner, .sound]

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        presented.append(notification)
        completionHandler(options)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        responses.append(response)
        completionHandler()
    }
}

/// The async forms instead.
private final class AsyncDelegate: UNUserNotificationCenterDelegate {
    var responses: [UNNotificationResponse] = []

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        responses.append(response)
    }
}

private func settle(until done: () -> Bool) async {
    for _ in 0..<1000 where !done() {
        await Task.yield()
    }
}

@Suite("UserNotifications: Apple's values")
@MainActor
struct UserNotificationsValuesTests {
    @Test("Option sets, statuses and action identifiers have Apple's raw values")
    func rawValues() {
        let authorization: [UNAuthorizationOptions] = [.badge, .sound, .alert, .carPlay, .criticalAlert, .providesAppNotificationSettings, .provisional]
        #expect(authorization.map(\.rawValue) == [1, 2, 4, 8, 16, 32, 64])
        let presentation: [UNNotificationPresentationOptions] = [.badge, .sound, .list, .banner]
        #expect(presentation.map(\.rawValue) == [1, 2, 8, 16])
        let statuses: [UNAuthorizationStatus] = [.notDetermined, .denied, .authorized, .provisional, .ephemeral]
        #expect(statuses.map(\.rawValue) == [0, 1, 2, 3, 4])
        #expect([UNNotificationSetting.notSupported, .disabled, .enabled].map(\.rawValue) == [0, 1, 2])
        #expect([UNAlertStyle.none, .banner, .alert].map(\.rawValue) == [0, 1, 2])
        #expect(UNNotificationDefaultActionIdentifier == "com.apple.UNNotificationDefaultActionIdentifier")
        #expect(UNNotificationDismissActionIdentifier == "com.apple.UNNotificationDismissActionIdentifier")
        #expect(UNErrorDomain == "UNErrorDomain")
        #expect([UNError.Code.notificationsNotAllowed, .notificationInvalidNoDate, .notificationInvalidNoContent].map(\.rawValue) == [1, 1400, 1401])
    }

    @Test("New content is empty, and sounds compare by name")
    func contentDefaults() {
        let content = UNMutableNotificationContent()
        #expect(content.title == "" && content.subtitle == "" && content.body == "")
        #expect(content.sound == nil && content.badge == nil && content.userInfo.isEmpty)
        #expect(content.threadIdentifier == "" && content.categoryIdentifier == "")
        #expect(UNNotificationSound.default !== UNNotificationSound.default)
        #expect(UNNotificationSound.default == UNNotificationSound.default)
        #expect(UNNotificationSound.default != UNNotificationSound(named: UNNotificationSoundName("x")))
        #expect(UNNotificationSound(named: UNNotificationSoundName("x")) == UNNotificationSound(named: UNNotificationSoundName("x")))
    }

    @Test("A request keeps an immutable copy of its content, the trigger itself, and compares by value")
    func requests() {
        let mutable = content()
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 18, minute: 0), repeats: true)
        let request = UNNotificationRequest(identifier: "id", content: mutable, trigger: trigger)
        mutable.title = "changed"
        #expect(request.content.title == "Reminder")
        #expect(!(request.content is UNMutableNotificationContent))
        #expect(request.content !== mutable)
        #expect(request.trigger === trigger)

        let same = UNNotificationRequest(identifier: "id", content: content(), trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 18, minute: 0), repeats: true))
        #expect(request == same)
        #expect(request != UNNotificationRequest(identifier: "id2", content: content(), trigger: nil))
        #expect(UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false) == UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
    }

    /// Measured at 2026-11-17T15:28:43+01:00 in Europe/Amsterdam. The two
    /// odd ones (a day the month lacks) carry the current minutes and
    /// seconds into the result: that's Apple's answer, and Foundation's
    /// `nextTimePreservingSmallerComponents`.
    @Test("A calendar trigger's next date is Apple's", arguments: [
        (DateComponents(hour: 18, minute: 0), "2026-11-17T18:00:00+01:00"),
        (DateComponents(hour: 18), "2026-11-17T18:00:00+01:00"),
        (DateComponents(minute: 30), "2026-11-17T15:30:00+01:00"),
        (DateComponents(second: 0), "2026-11-17T15:29:00+01:00"),
        (DateComponents(hour: 9, minute: 15, weekday: 4), "2026-11-18T09:15:00+01:00"),
        (DateComponents(day: 31, hour: 9), "2026-12-01T09:28:43+01:00"),
        (DateComponents(month: 2, day: 30, hour: 9), "2027-03-01T09:28:43+01:00"),
        (DateComponents(year: 2027, month: 1, day: 5, hour: 18, minute: 0), "2027-01-05T18:00:00+01:00"),
        (DateComponents(timeZone: TimeZone(identifier: "Asia/Tokyo"), year: 2027, month: 1, day: 5, hour: 18, minute: 0), "2027-01-05T10:00:00+01:00"),
        (DateComponents(timeZone: TimeZone(identifier: "Asia/Tokyo"), hour: 18, minute: 0), "2026-11-18T10:00:00+01:00"),
        (DateComponents(year: 2027), "2027-01-01T00:00:00+01:00"),
        (DateComponents(hour: 15, minute: 28), "2026-11-18T15:28:00+01:00"),
    ] as [(DateComponents, String)])
    func calendarNextDate(components: DateComponents, expected: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = amsterdam
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        #expect(trigger.nextTriggerDate(after: date("2026-11-17T15:28:43+01:00"), calendar: calendar) == date(expected))
    }

    @Test("A calendar trigger with nothing left to match has no next date")
    func calendarNoNextDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = amsterdam
        let now = date("2026-11-17T15:28:43+01:00")
        #expect(UNCalendarNotificationTrigger(dateMatching: DateComponents(year: 2025, month: 1, day: 5, hour: 18, minute: 0), repeats: false).nextTriggerDate(after: now, calendar: calendar) == nil)
        #expect(UNCalendarNotificationTrigger(dateMatching: DateComponents(), repeats: true).nextTriggerDate(after: now, calendar: calendar) == nil)
    }

    @Test("A time interval trigger's next date counts from now")
    func intervalNextDate() throws {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 120, repeats: false)
        let next = try #require(trigger.nextTriggerDate())
        #expect(abs(next.timeIntervalSinceNow - 120) < 1)
    }
}

@Suite("UserNotifications over the channel")
@MainActor
struct UserNotificationsChannelTests {
    @Test("Starting tells Java, and its status stands")
    func start() async {
        let java = FakeJava()
        java.answers["notifications.start"] = ["status": "denied"]
        let center = UNUserNotificationCenter(channel: java.channel)
        #expect(java.names == ["notifications.start"])
        #expect(await center.notificationSettings().authorizationStatus == .denied)
    }

    @Test("A request that prompts is answered by the status event that follows")
    func authorizationPrompt() async throws {
        let java = FakeJava()
        java.answers["notifications.request"] = ["status": "notDetermined"]
        let center = UNUserNotificationCenter(channel: java.channel)
        #expect(await center.notificationSettings().authorizationStatus == .notDetermined)
        let granted = Task { try await center.requestAuthorization(options: [.alert, .sound]) }
        await java.waitFor("notifications.request")
        let call = java.calls.last!
        #expect(call.arguments["options"] as? [String] == ["sound", "alert"])
        let request = call.arguments["request"] as? Int
        java.send("notifications", "status", ["status": "authorized", "granted": true, "request": request!])
        #expect(try await granted.value)
        let settings = await center.notificationSettings()
        #expect(settings.authorizationStatus == .authorized)
        #expect(settings.alertSetting == .enabled && settings.soundSetting == .enabled)
    }

    @Test("A request Java can answer at once returns at once; a refusal is denied")
    func authorizationImmediate() async throws {
        let java = FakeJava()
        java.answers["notifications.request"] = ["status": "denied", "granted": false]
        let center = UNUserNotificationCenter(channel: java.channel)
        #expect(try await !center.requestAuthorization(options: [.alert]))
        let settings = await center.notificationSettings()
        #expect(settings.authorizationStatus == .denied)
        #expect(settings.alertSetting == .disabled)
    }

    @Test("Java's live status wins over what Swift last heard")
    func authorizationLive() async {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        java.answers["notifications.authorization"] = ["status": "authorized"]
        #expect(await center.notificationSettings().authorizationStatus == .authorized)
        // Turned off in the system's settings meanwhile.
        java.answers["notifications.authorization"] = ["status": "denied"]
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
        #expect(settings == .denied)
    }

    @Test("Scheduling sends the content and a calendar trigger's components and next date")
    func scheduleCalendar() async throws {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        var components = DateComponents(year: 2099, month: 1, day: 5)
        components.hour = 18
        components.minute = 0
        components.timeZone = amsterdam
        let mutable = content()
        mutable.subtitle = "Day 12"
        mutable.badge = 3
        mutable.threadIdentifier = "daily"
        let request = UNNotificationRequest(identifier: "reminder.12", content: mutable, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        try await center.add(request)

        let sent = try #require(java.calls.last?.arguments["request"] as? [String: Any])
        #expect(java.calls.last?.name == "notifications.schedule")
        #expect(sent["identifier"] as? String == "reminder.12")
        let body = try #require(sent["content"] as? [String: Any])
        #expect(body["title"] as? String == "Reminder")
        #expect(body["subtitle"] as? String == "Day 12")
        #expect(body["body"] as? String == "Something new is waiting")
        #expect(body["sound"] as? String == "default")
        #expect(body["badge"] as? Int == 3)
        #expect(body["threadIdentifier"] as? String == "daily")
        #expect(body["userInfo"] as? [String: String] == ["route": "reminder"])
        let trigger = try #require(sent["trigger"] as? [String: Any])
        #expect(trigger["type"] as? String == "calendar")
        #expect(trigger["repeats"] as? Bool == false)
        #expect(trigger["year"] as? Int == 2099 && trigger["month"] as? Int == 1 && trigger["day"] as? Int == 5)
        #expect(trigger["hour"] as? Int == 18 && trigger["minute"] as? Int == 0)
        #expect(trigger["second"] == nil && trigger["weekday"] == nil)
        #expect(trigger["timeZone"] as? String == "Europe/Amsterdam")
        #expect(trigger["fireAt"] as? Double == date("2099-01-05T18:00:00+01:00").timeIntervalSince1970 * 1000)
    }

    @Test("A daily repeating trigger sends hour and minute only")
    func scheduleDaily() throws {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        center.add(UNNotificationRequest(identifier: "daily", content: content(), trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 18, minute: 0), repeats: true)))
        let trigger = try #require((java.calls.last?.arguments["request"] as? [String: Any])?["trigger"] as? [String: Any])
        #expect(Set(trigger.keys) == ["type", "repeats", "hour", "minute", "fireAt"])
        #expect(trigger["repeats"] as? Bool == true)
        let fireAt = try #require(trigger["fireAt"] as? Double)
        let next = Date(timeIntervalSince1970: fireAt / 1000)
        #expect(next > Date() && next.timeIntervalSinceNow <= 86_400)
        #expect(Calendar.current.dateComponents([.hour, .minute, .second], from: next) == DateComponents(hour: 18, minute: 0, second: 0))
    }

    @Test("A time interval trigger sends its seconds")
    func scheduleInterval() throws {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        center.add(UNNotificationRequest(identifier: "launch", content: content(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)))
        let trigger = try #require((java.calls.last?.arguments["request"] as? [String: Any])?["trigger"] as? [String: Any])
        #expect(trigger["type"] as? String == "interval")
        #expect(trigger["seconds"] as? Double == 10)
        #expect(trigger["repeats"] as? Bool == false)
        let fireAt = try #require(trigger["fireAt"] as? Double)
        #expect(abs(fireAt / 1000 - Date().timeIntervalSince1970 - 10) < 1)
    }

    @Test("Java refusing a request fails the add")
    func scheduleRefused() async {
        let java = FakeJava()
        java.answers["notifications.schedule"] = ["ok": false, "code": 1400]
        let center = UNUserNotificationCenter(channel: java.channel)
        await #expect(throws: UNError(.notificationInvalidNoDate)) {
            try await center.add(UNNotificationRequest(identifier: "x", content: content(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
        }
    }

    @Test("What Java lists as pending reads back as the requests the game added")
    func pendingRoundTrip() async throws {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        var components = DateComponents(year: 2099, month: 3, day: 1)
        components.hour = 18
        components.minute = 0
        components.timeZone = TimeZone.current
        let requests = [
            UNNotificationRequest(identifier: "reminder.1", content: content(), trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)),
            UNNotificationRequest(identifier: "weekly", content: content(title: "Week"), trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 9, minute: 30, weekday: 2), repeats: true)),
            UNNotificationRequest(identifier: "reminder.launch", content: content(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 90, repeats: false)),
        ]
        for request in requests { try await center.add(request) }
        // Java keeps them as sent; hand them back as its pending list.
        let stored = java.calls.filter { $0.name == "notifications.schedule" }.map { $0.arguments["request"]! }
        java.answers["notifications.pending"] = ["requests": stored]

        let pending = await center.pendingNotificationRequests()
        #expect(pending == requests)
        #expect(pending.map(\.identifier) == requests.map(\.identifier))
        #expect(pending[0].content.userInfo["route"] as? String == "reminder")
        #expect(pending[0].content.sound == .default)
        #expect((pending[1].trigger as? UNCalendarNotificationTrigger)?.dateComponents.weekday == 2)
        #expect(pending[1].trigger?.repeats == true)
        let interval = try #require(pending[2].trigger as? UNTimeIntervalNotificationTrigger)
        #expect(interval.timeInterval == 90)
        // The fire date Java reported, not a fresh 90 s from now.
        let fireAt = try #require(((stored[2] as? [String: Any])?["trigger"] as? [String: Any])?["fireAt"] as? Double)
        #expect(interval.nextTriggerDate() == Date(timeIntervalSince1970: fireAt / 1000))
    }

    @Test("Removing sends the identifiers")
    func remove() {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        center.removePendingNotificationRequests(withIdentifiers: ["a", "b"])
        #expect(java.calls.last?.name == "notifications.remove")
        #expect(java.calls.last?.arguments["identifiers"] as? [String] == ["a", "b"])
        center.removeAllPendingNotificationRequests()
        center.removeDeliveredNotifications(withIdentifiers: ["c"])
        center.removeAllDeliveredNotifications()
        #expect(java.names.suffix(3) == ["notifications.removeAll", "notifications.removeDelivered", "notifications.removeAllDelivered"])
    }

    @Test("A tap reaches the delegate's didReceive with the request and its userInfo")
    func tap() async throws {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        let delegate = CompletionDelegate()
        center.delegate = delegate
        let request = UNNotificationRequest(identifier: "reminder.7", content: content(), trigger: nil)
        java.send("notifications", "opened", ["request": NotificationCodec.encode(request), "date": 1_790_000_000_000.0, "action": "default"])
        await settle { !delegate.responses.isEmpty }
        let response = try #require(delegate.responses.first)
        #expect(response.actionIdentifier == UNNotificationDefaultActionIdentifier)
        #expect(response.notification.request == request)
        #expect(response.notification.request.content.userInfo["route"] as? String == "reminder")
        #expect(response.notification.date == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test("A tap before there is a delegate waits for one; async delegates hear it too")
    func tapHeld() async {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        let request = UNNotificationRequest(identifier: "r", content: content(), trigger: nil)
        java.send("notifications", "opened", ["request": NotificationCodec.encode(request)])
        let delegate = AsyncDelegate()
        center.delegate = delegate
        await settle { !delegate.responses.isEmpty }
        #expect(delegate.responses.map(\.notification.request.identifier) == ["r"])
    }

    @Test("One fired in front asks willPresent, and Java shows it as the delegate says")
    func willPresent() async throws {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        let delegate = CompletionDelegate()
        center.delegate = delegate
        let request = NotificationCodec.encode(UNNotificationRequest(identifier: "r", content: content(), trigger: nil))
        java.send("notifications", "willPresent", ["request": request])
        await java.waitFor("notifications.present")
        #expect(delegate.presented.map(\.request.identifier) == ["r"])
        let call = try #require(java.calls.last)
        #expect(call.name == "notifications.present")
        #expect(call.arguments["options"] as? [String] == ["sound", "banner"])
        #expect((call.arguments["request"] as? [String: Any])?["identifier"] as? String == "r")

        let quiet = AsyncDelegate()
        center.delegate = quiet
        java.send("notifications", "willPresent", ["request": request])
        await java.waitFor("notifications.present", times: 2)
        #expect(java.calls.last?.arguments["options"] as? [String] == ["list"])
    }
}

@Suite("UserNotifications without a channel")
@MainActor
struct UserNotificationsMemoryTests {
    @Test("A device whose player hasn't decided, keeping requests in memory")
    func memory() async throws {
        let center = UNUserNotificationCenter(channel: nil)
        #expect(await center.notificationSettings().authorizationStatus == .notDetermined)
        #expect(try await !center.requestAuthorization(options: [.alert, .sound]))
        #expect(await center.notificationSettings().authorizationStatus == .notDetermined)

        let daily = UNNotificationRequest(identifier: "reminder.1", content: content(), trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 18, minute: 0), repeats: true))
        let soon = UNNotificationRequest(identifier: "soon", content: content(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false))
        let past = UNNotificationRequest(identifier: "past", content: content(), trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(year: 2020, month: 1, day: 1, hour: 9), repeats: false))
        let now = UNNotificationRequest(identifier: "now", content: content(), trigger: nil)
        for request in [daily, soon, past, now] { try await center.add(request) }
        #expect(await center.pendingNotificationRequests().map(\.identifier) == ["reminder.1", "soon"])

        // Adding the same identifier replaces it.
        let replaced = UNNotificationRequest(identifier: "soon", content: content(title: "Again"), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 120, repeats: false))
        try await center.add(replaced)
        #expect(await center.pendingNotificationRequests().map(\.content.title) == ["Reminder", "Again"])

        center.removePendingNotificationRequests(withIdentifiers: ["reminder.1"])
        #expect(await center.pendingNotificationRequests() == [replaced])
        center.removeAllPendingNotificationRequests()
        #expect(await center.pendingNotificationRequests().isEmpty)
    }

    @Test("Java with no notifications service behind the channel is the same as none")
    func unwired() async throws {
        let java = FakeJava()
        let center = UNUserNotificationCenter(channel: java.channel)
        #expect(try await !center.requestAuthorization(options: [.alert]))
        try await center.add(UNNotificationRequest(identifier: "a", content: content(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
        #expect(await center.pendingNotificationRequests().map(\.identifier) == ["a"])
    }

    /// A game's reminder scheduling, in brief: the
    /// calls it makes, spelled as it spells them, compile and do what it
    /// expects of them.
    @Test("Reminder bookkeeping works against the center")
    func consumerShape() async throws {
        let center = UNUserNotificationCenter(channel: nil)
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            Issue.record("not asked yet")
        case .notDetermined:
            _ = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .denied:
            Issue.record("not asked yet")
        @unknown default:
            Issue.record("unknown")
        }
        let calendar = Calendar.current
        let day = try #require(calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: Date())))
        let reminderDate = try #require(calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day))
        var date = calendar.dateComponents([.year, .month, .day], from: reminderDate)
        date.hour = 18
        date.minute = 0
        date.timeZone = calendar.timeZone
        let request = UNNotificationRequest(identifier: "reminder.x", content: content(), trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: false))
        try await center.add(request)
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("reminder.") }
        #expect(identifiers == ["reminder.x"])
        #expect((request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() == reminderDate)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        #expect(await center.pendingNotificationRequests().isEmpty)
    }
}
