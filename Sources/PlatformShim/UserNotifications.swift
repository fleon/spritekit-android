import Foundation

// Apple's UserNotifications for Android: local notifications only, the
// surface a game's reminder code uses, with Apple's spellings so it compiles
// unedited (`Modules/Sources/UserNotifications` answers `import
// UserNotifications`). The device half is `PlatformNotifications.java`
// (Templates/App/notifications), reached over `PlatformChannel`:
//
//   - calls, each answered at once (Java knows these without waiting):
//     `notifications.start` → `{status}` (also releases taps held for Swift),
//     `notifications.authorization` → `{status}`,
//     `notifications.request {options, request}` → `{status, granted}`, or
//     `{status}` alone while the system's prompt is up (then a `status`
//     event with the same `request` follows),
//     `notifications.schedule {request}` → `{ok}`,
//     `notifications.remove {identifiers}`, `notifications.removeAll`,
//     `notifications.pending` → `{requests}`,
//     `notifications.delivered` → `{notifications: [{request, date}]}`,
//     `notifications.removeDelivered {identifiers}`,
//     `notifications.removeAllDelivered`, `notifications.badge {count}`,
//     `notifications.present {request, options}` (the answer to `willPresent`);
//   - events (service `notifications`): `status {status, granted?, request?}`,
//     `willPresent {request, date}` (one fired while the game is in front),
//     `opened {request, date, action}` (one the player tapped).
//
// A request travels as `{identifier, content: {title, subtitle, body,
// sound?, badge?, threadIdentifier, categoryIdentifier, userInfo}, trigger?}`
// and a trigger as `{type: "calendar", repeats, year?, month?, day?, hour?,
// minute?, second?, weekday?, timeZone?, fireAt}` or `{type: "interval",
// seconds, repeats, fireAt}`, `fireAt` being the next fire date in
// milliseconds since 1970 as Swift reckons it (Java arms the first alarm
// with it and works out the repeats itself).
//
// With no channel (a host test) or no notifications service behind it, the
// center is a device whose player hasn't decided: `.notDetermined`, a
// request that isn't granted, and requests kept in memory so the game's
// bookkeeping (what's pending, what was removed) still holds.

// MARK: - Options and statuses

public struct UNAuthorizationOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let badge = UNAuthorizationOptions(rawValue: 1 << 0)
    public static let sound = UNAuthorizationOptions(rawValue: 1 << 1)
    public static let alert = UNAuthorizationOptions(rawValue: 1 << 2)
    public static let carPlay = UNAuthorizationOptions(rawValue: 1 << 3)
    public static let criticalAlert = UNAuthorizationOptions(rawValue: 1 << 4)
    public static let providesAppNotificationSettings = UNAuthorizationOptions(rawValue: 1 << 5)
    public static let provisional = UNAuthorizationOptions(rawValue: 1 << 6)
}

public struct UNNotificationPresentationOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let badge = UNNotificationPresentationOptions(rawValue: 1 << 0)
    public static let sound = UNNotificationPresentationOptions(rawValue: 1 << 1)
    @available(*, deprecated, message: "Use .list and .banner")
    public static let alert = UNNotificationPresentationOptions(rawValue: 1 << 2)
    public static let list = UNNotificationPresentationOptions(rawValue: 1 << 3)
    public static let banner = UNNotificationPresentationOptions(rawValue: 1 << 4)
}

public enum UNAuthorizationStatus: Int, Sendable {
    case notDetermined = 0
    case denied = 1
    case authorized = 2
    case provisional = 3
    case ephemeral = 4
}

public enum UNNotificationSetting: Int, Sendable {
    case notSupported = 0
    case disabled = 1
    case enabled = 2
}

public enum UNAlertStyle: Int, Sendable {
    case none = 0
    case banner = 1
    case alert = 2
}

public enum UNShowPreviewsSetting: Int, Sendable {
    case always = 0
    case whenAuthenticated = 1
    case never = 2
}

public let UNNotificationDefaultActionIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"
public let UNNotificationDismissActionIdentifier = "com.apple.UNNotificationDismissActionIdentifier"
public let UNErrorDomain = "UNErrorDomain"

public struct UNError: Error, Hashable, Sendable {
    public enum Code: Int, Sendable, Equatable {
        case notificationsNotAllowed = 1
        case attachmentInvalidURL = 100
        case attachmentUnrecognizedType = 101
        case attachmentInvalidFileSize = 102
        case attachmentNotInDataStore = 103
        case attachmentMoveIntoDataStoreFailed = 104
        case attachmentCorrupt = 105
        case notificationInvalidNoDate = 1400
        case notificationInvalidNoContent = 1401
        case contentProvidingObjectNotAllowed = 1500
        case contentProvidingInvalid = 1501
        case badgeInputInvalid = 1600
    }

    public let code: Code
    public init(_ code: Code) { self.code = code }

    public static var errorDomain: String { UNErrorDomain }
    public var errorCode: Int { code.rawValue }
}

// MARK: - Content

public struct UNNotificationSoundName: Hashable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The system's sound, or one named. Android plays its notification
/// channel's sound for either: a channel's sound is fixed once made.
open class UNNotificationSound: NSObject, NSCopying {
    /// nil for the default sound.
    let name: String?

    init(soundName: String?) {
        name = soundName
    }

    public convenience init(named name: UNNotificationSoundName) {
        self.init(soundName: name.rawValue)
    }

    /// A new object each time, equal to every other, as Apple's is.
    open class var `default`: UNNotificationSound { UNNotificationSound(soundName: nil) }

    open func copy(with zone: NSZone? = nil) -> Any { self }

    open override func isEqual(_ object: Any?) -> Bool {
        (object as? UNNotificationSound)?.name == name
    }

    open override var hash: Int { name?.hashValue ?? 0 }
}

/// What a notification says. Immutable; `UNMutableNotificationContent` is
/// what a game fills in, and a request keeps a copy of it, as on Apple.
open class UNNotificationContent: NSObject, NSCopying, NSMutableCopying {
    struct Fields {
        var title = ""
        var subtitle = ""
        var body = ""
        var badge: NSNumber?
        var sound: UNNotificationSound?
        var threadIdentifier = ""
        var categoryIdentifier = ""
        var targetContentIdentifier: String?
        var userInfo: [AnyHashable: Any] = [:]
    }

    var fields: Fields

    public override init() {
        fields = Fields()
    }

    init(fields: Fields) {
        self.fields = fields
    }

    open var title: String { fields.title }
    open var subtitle: String { fields.subtitle }
    open var body: String { fields.body }
    open var badge: NSNumber? { fields.badge }
    open var sound: UNNotificationSound? { fields.sound }
    open var threadIdentifier: String { fields.threadIdentifier }
    open var categoryIdentifier: String { fields.categoryIdentifier }
    open var targetContentIdentifier: String? { fields.targetContentIdentifier }
    open var userInfo: [AnyHashable: Any] { fields.userInfo }

    open func copy(with zone: NSZone? = nil) -> Any { UNNotificationContent(fields: fields) }
    open func mutableCopy(with zone: NSZone? = nil) -> Any { UNMutableNotificationContent(fields: fields) }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNNotificationContent else { return false }
        let a = fields, b = other.fields
        return a.title == b.title && a.subtitle == b.subtitle && a.body == b.body
            && a.badge == b.badge && a.sound == b.sound
            && a.threadIdentifier == b.threadIdentifier && a.categoryIdentifier == b.categoryIdentifier
            && a.targetContentIdentifier == b.targetContentIdentifier
            && NSDictionary(dictionary: a.userInfo).isEqual(to: b.userInfo)
    }

    open override var hash: Int { fields.title.hashValue ^ fields.body.hashValue }
}

open class UNMutableNotificationContent: UNNotificationContent {
    open override var title: String {
        get { fields.title }
        set { fields.title = newValue }
    }
    open override var subtitle: String {
        get { fields.subtitle }
        set { fields.subtitle = newValue }
    }
    open override var body: String {
        get { fields.body }
        set { fields.body = newValue }
    }
    open override var badge: NSNumber? {
        get { fields.badge }
        set { fields.badge = newValue }
    }
    open override var sound: UNNotificationSound? {
        get { fields.sound }
        set { fields.sound = newValue }
    }
    open override var threadIdentifier: String {
        get { fields.threadIdentifier }
        set { fields.threadIdentifier = newValue }
    }
    open override var categoryIdentifier: String {
        get { fields.categoryIdentifier }
        set { fields.categoryIdentifier = newValue }
    }
    open override var targetContentIdentifier: String? {
        get { fields.targetContentIdentifier }
        set { fields.targetContentIdentifier = newValue }
    }
    open override var userInfo: [AnyHashable: Any] {
        get { fields.userInfo }
        set { fields.userInfo = newValue }
    }
}

// MARK: - Triggers

open class UNNotificationTrigger: NSObject, NSCopying {
    public let repeats: Bool

    init(repeats: Bool) {
        self.repeats = repeats
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }
}

open class UNCalendarNotificationTrigger: UNNotificationTrigger {
    public let dateComponents: DateComponents

    public init(dateMatching dateComponents: DateComponents, repeats: Bool) {
        self.dateComponents = dateComponents
        super.init(repeats: repeats)
    }

    open func nextTriggerDate() -> Date? {
        nextTriggerDate(after: Date())
    }

    /// The first date after `date` matching the components, read in their
    /// own time zone when they carry one and `calendar`'s otherwise. Missing
    /// smaller units are zero; a day the month lacks moves on to the next
    /// day, keeping the time (Foundation's
    /// `nextTimePreservingSmallerComponents`, which is what Apple's trigger
    /// was measured to answer).
    func nextTriggerDate(after date: Date, calendar: Calendar = .current) -> Date? {
        var calendar = dateComponents.calendar ?? calendar
        if let zone = dateComponents.timeZone { calendar.timeZone = zone }
        var matching = dateComponents
        matching.calendar = nil
        matching.timeZone = nil
        return calendar.nextDate(after: date, matching: matching, matchingPolicy: .nextTimePreservingSmallerComponents)
    }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNCalendarNotificationTrigger else { return false }
        return other.repeats == repeats && other.dateComponents == dateComponents
    }

    open override var hash: Int { dateComponents.hashValue }
}

open class UNTimeIntervalNotificationTrigger: UNNotificationTrigger {
    public let timeInterval: TimeInterval
    /// When a pending request's next fire is known (as Java reports it).
    var fireDate: Date?

    public init(timeInterval: TimeInterval, repeats: Bool) {
        // Apple raises for these too.
        precondition(timeInterval > 0, "time interval must be greater than 0")
        precondition(!repeats || timeInterval >= 60, "time interval must be at least 60 if repeating")
        self.timeInterval = timeInterval
        super.init(repeats: repeats)
    }

    /// From now, as Apple's answers for a trigger not yet scheduled.
    open func nextTriggerDate() -> Date? {
        if let fireDate, fireDate > Date() { return fireDate }
        return Date().addingTimeInterval(timeInterval)
    }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNTimeIntervalNotificationTrigger else { return false }
        return other.repeats == repeats && other.timeInterval == timeInterval
    }

    open override var hash: Int { timeInterval.hashValue }
}

// MARK: - Requests, notifications, responses, settings

open class UNNotificationRequest: NSObject, NSCopying {
    public let identifier: String
    public let content: UNNotificationContent
    public let trigger: UNNotificationTrigger?

    public init(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        self.identifier = identifier
        // A copy, so changing the game's content afterwards changes nothing.
        self.content = UNNotificationContent(fields: content.fields)
        self.trigger = trigger
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNNotificationRequest else { return false }
        return other.identifier == identifier && other.content == content && other.trigger == trigger
    }

    open override var hash: Int { identifier.hashValue }
}

open class UNNotification: NSObject {
    public let date: Date
    public let request: UNNotificationRequest

    init(request: UNNotificationRequest, date: Date) {
        self.request = request
        self.date = date
    }
}

open class UNNotificationResponse: NSObject {
    public let notification: UNNotification
    public let actionIdentifier: String

    init(notification: UNNotification, actionIdentifier: String) {
        self.notification = notification
        self.actionIdentifier = actionIdentifier
    }
}

/// Android has one switch where iOS has several: when notifications are
/// allowed, every one of these is `.enabled`; refused, `.disabled`; not yet
/// asked, `.notSupported`.
open class UNNotificationSettings: NSObject {
    public let authorizationStatus: UNAuthorizationStatus

    init(authorizationStatus: UNAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }

    private var setting: UNNotificationSetting {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: .enabled
        case .denied: .disabled
        case .notDetermined: .notSupported
        }
    }

    open var soundSetting: UNNotificationSetting { setting }
    open var badgeSetting: UNNotificationSetting { setting }
    open var alertSetting: UNNotificationSetting { setting }
    open var notificationCenterSetting: UNNotificationSetting { setting }
    open var lockScreenSetting: UNNotificationSetting { setting }
    open var carPlaySetting: UNNotificationSetting { .notSupported }
    open var criticalAlertSetting: UNNotificationSetting { .notSupported }
    open var announcementSetting: UNNotificationSetting { .notSupported }
    open var timeSensitiveSetting: UNNotificationSetting { .notSupported }
    open var scheduledDeliverySetting: UNNotificationSetting { .disabled }
    open var directMessagesSetting: UNNotificationSetting { .notSupported }
    open var alertStyle: UNAlertStyle { setting == .enabled ? .banner : .none }
    open var showPreviewsSetting: UNShowPreviewsSetting { .always }
    open var providesAppNotificationSettings: Bool { false }
}

// MARK: - Delegate

/// On the main actor, where the center calls it (the frame thread, as
/// `PlatformChannel` delivers there). Each method has a default, as Apple's
/// are optional; the async forms fall back to the completion-handler forms,
/// so a delegate implements whichever it likes.
@MainActor
public protocol UNUserNotificationCenterDelegate: AnyObject {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?)
}

public extension UNUserNotificationCenterDelegate {
    /// Not implemented, a notification that arrives in front isn't shown.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await withCheckedContinuation { continuation in
            userNotificationCenter(center, willPresent: notification) { continuation.resume(returning: $0) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await withCheckedContinuation { continuation in
            userNotificationCenter(center, didReceive: response) { continuation.resume() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {}
}

// MARK: - Center

open class UNUserNotificationCenter: NSObject {
    private static let service = "notifications"
    nonisolated(unsafe) private static var shared: UNUserNotificationCenter?

    private let channel: PlatformChannel?
    private var status: UNAuthorizationStatus = .notDetermined
    /// What's scheduled, as far as Swift knows: the answer where Java has
    /// none (no channel, or no notifications service behind it).
    private var scheduled: [UNNotificationRequest] = []
    private var nextRequest = 1
    private var authorizationWaiters: [Int: @Sendable (Bool, Error?) -> Void] = [:]
    /// Taps that came before there was a delegate to hear them.
    private var heldResponses: [UNNotificationResponse] = []

    weak open var delegate: (any UNUserNotificationCenterDelegate)? {
        didSet { deliverHeldResponses() }
    }

    open var supportsContentExtensions: Bool { false }

    /// The app's center, talking through the channel the shell installed.
    open class func current() -> UNUserNotificationCenter {
        if let shared { return shared }
        let center = UNUserNotificationCenter(channel: PlatformChannel.shared)
        shared = center
        return center
    }

    init(channel: PlatformChannel?) {
        self.channel = channel
        super.init()
        guard let channel else { return }
        channel.on(Self.service) { [weak self] event, body in self?.handle(event, body) }
        updateStatus(channel.call("notifications.start"))
    }

    // MARK: Authorization

    open func requestAuthorization(options: UNAuthorizationOptions = [], completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
        let request = nextRequest
        nextRequest += 1
        guard let answer = channel?.call("notifications.request", ["options": Self.names(of: options), "request": request]) else {
            // Nothing to ask: the player stays undecided.
            completionHandler(false, nil)
            return
        }
        updateStatus(answer)
        if let granted = answer.bool("granted") {
            completionHandler(granted, nil)
        } else {
            authorizationWaiters[request] = completionHandler
        }
    }

    @MainActor
    open func requestAuthorization(options: UNAuthorizationOptions = []) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    open func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void) {
        completionHandler(currentSettings())
    }

    @MainActor
    open func notificationSettings() async -> UNNotificationSettings {
        currentSettings()
    }

    // MARK: Scheduling

    open func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)? = nil) {
        let now = Date()
        if let answer = channel?.call("notifications.schedule", ["request": NotificationCodec.encode(request, now: now)]),
           answer.bool("ok") == false {
            completionHandler?(UNError(UNError.Code(rawValue: answer.int("code") ?? 0) ?? .notificationsNotAllowed))
            return
        }
        scheduled.removeAll { $0.identifier == request.identifier }
        // No trigger is delivered at once, and a date already past never
        // fires: neither is pending.
        if NotificationCodec.fireDate(of: request.trigger, after: now) != nil {
            scheduled.append(request)
        }
        completionHandler?(nil)
    }

    @MainActor
    open func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    open func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) {
        completionHandler(pending())
    }

    @MainActor
    open func pendingNotificationRequests() async -> [UNNotificationRequest] {
        pending()
    }

    open func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        let removed = Set(identifiers)
        scheduled.removeAll { removed.contains($0.identifier) }
        channel?.call("notifications.remove", ["identifiers": identifiers])
    }

    open func removeAllPendingNotificationRequests() {
        scheduled = []
        channel?.call("notifications.removeAll")
    }

    // MARK: Delivered

    open func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {
        completionHandler(delivered())
    }

    @MainActor
    open func deliveredNotifications() async -> [UNNotification] {
        delivered()
    }

    open func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        channel?.call("notifications.removeDelivered", ["identifiers": identifiers])
    }

    open func removeAllDeliveredNotifications() {
        channel?.call("notifications.removeAllDelivered")
    }

    /// Android's launchers count notifications themselves; Java keeps the
    /// number for the next one it shows.
    open func setBadgeCount(_ newBadgeCount: Int, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)? = nil) {
        channel?.call("notifications.badge", ["count": newBadgeCount])
        completionHandler?(nil)
    }

    @MainActor
    open func setBadgeCount(_ newBadgeCount: Int) async throws {
        setBadgeCount(newBadgeCount, withCompletionHandler: nil)
    }

    // MARK: - Private

    private func currentSettings() -> UNNotificationSettings {
        updateStatus(channel?.call("notifications.authorization"))
        return UNNotificationSettings(authorizationStatus: status)
    }

    private func pending() -> [UNNotificationRequest] {
        if let answer = channel?.call("notifications.pending"),
           let requests = answer["requests"] as? [PlatformChannel.Message] {
            scheduled = requests.compactMap(NotificationCodec.decodeRequest)
            return scheduled
        }
        let now = Date()
        scheduled.removeAll { NotificationCodec.fireDate(of: $0.trigger, after: now) == nil }
        return scheduled
    }

    private func delivered() -> [UNNotification] {
        let items = channel?.call("notifications.delivered")?["notifications"] as? [PlatformChannel.Message] ?? []
        return items.compactMap(NotificationCodec.decodeNotification)
    }

    private func updateStatus(_ answer: PlatformChannel.Message?) {
        guard let name = answer?["status"] as? String, let status = NotificationCodec.status(named: name) else { return }
        self.status = status
    }

    private func handle(_ event: String, _ body: PlatformChannel.Message) {
        switch event {
        case "status":
            updateStatus(body)
            guard let request = body.int("request"), let waiter = authorizationWaiters.removeValue(forKey: request) else { return }
            waiter(body.bool("granted") ?? false, nil)
        case "willPresent":
            guard let notification = NotificationCodec.decodeNotification(body),
                  let request = body["request"] as? PlatformChannel.Message else { return }
            // Events are delivered on the frame thread, the main actor's.
            MainActor.assumeIsolated {
                guard let delegate else { return }
                Task {
                    let options = await delegate.userNotificationCenter(self, willPresent: notification)
                    self.channel?.call("notifications.present", ["request": request, "options": Self.names(of: options)])
                }
            }
        case "opened":
            guard let notification = NotificationCodec.decodeNotification(body) else { return }
            let action = (body["action"] as? String) == "dismiss" ? UNNotificationDismissActionIdentifier : UNNotificationDefaultActionIdentifier
            heldResponses.append(UNNotificationResponse(notification: notification, actionIdentifier: action))
            deliverHeldResponses()
        default:
            break
        }
    }

    private func deliverHeldResponses() {
        guard !heldResponses.isEmpty, Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard let delegate else { return }
            let responses = heldResponses
            heldResponses = []
            Task {
                for response in responses {
                    await delegate.userNotificationCenter(self, didReceive: response)
                }
            }
        }
    }

    private static func names(of options: UNAuthorizationOptions) -> [String] {
        let names: [(UNAuthorizationOptions, String)] = [
            (.badge, "badge"), (.sound, "sound"), (.alert, "alert"), (.carPlay, "carPlay"),
            (.criticalAlert, "criticalAlert"), (.providesAppNotificationSettings, "providesAppNotificationSettings"),
            (.provisional, "provisional"),
        ]
        return names.filter { options.contains($0.0) }.map(\.1)
    }

    private static func names(of options: UNNotificationPresentationOptions) -> [String] {
        let names: [(UNNotificationPresentationOptions, String)] = [
            (.badge, "badge"), (.sound, "sound"), (UNNotificationPresentationOptions(rawValue: 1 << 2), "alert"),
            (.list, "list"), (.banner, "banner"),
        ]
        return names.filter { options.contains($0.0) }.map(\.1)
    }
}

// MARK: - Wire format

/// Requests to and from the JSON `PlatformNotifications.java` keeps.
enum NotificationCodec {
    private static let calendarUnits: [(String, WritableKeyPath<DateComponents, Int?>)] = [
        ("year", \.year), ("month", \.month), ("day", \.day), ("hour", \.hour),
        ("minute", \.minute), ("second", \.second), ("weekday", \.weekday),
    ]

    static func status(named name: String) -> UNAuthorizationStatus? {
        switch name {
        case "notDetermined": .notDetermined
        case "denied": .denied
        case "authorized": .authorized
        case "provisional": .provisional
        case "ephemeral": .ephemeral
        default: nil
        }
    }

    static func fireDate(of trigger: UNNotificationTrigger?, after now: Date) -> Date? {
        switch trigger {
        case let calendar as UNCalendarNotificationTrigger:
            calendar.nextTriggerDate(after: now)
        case let interval as UNTimeIntervalNotificationTrigger:
            interval.fireDate.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(interval.timeInterval)
        default:
            nil
        }
    }

    static func encode(_ request: UNNotificationRequest, now: Date = Date()) -> PlatformChannel.Message {
        let content = request.content
        var encodedContent: PlatformChannel.Message = [
            "title": content.title,
            "subtitle": content.subtitle,
            "body": content.body,
            "threadIdentifier": content.threadIdentifier,
            "categoryIdentifier": content.categoryIdentifier,
            "userInfo": jsonSafe(content.userInfo),
        ]
        if let sound = content.sound { encodedContent["sound"] = sound.name ?? "default" }
        if let badge = content.badge { encodedContent["badge"] = badge.intValue }
        var message: PlatformChannel.Message = ["identifier": request.identifier, "content": encodedContent]
        if let trigger = encode(request.trigger, now: now) { message["trigger"] = trigger }
        return message
    }

    private static func encode(_ trigger: UNNotificationTrigger?, now: Date) -> PlatformChannel.Message? {
        var message: PlatformChannel.Message
        switch trigger {
        case let calendar as UNCalendarNotificationTrigger:
            message = ["type": "calendar"]
            for (name, path) in calendarUnits {
                if let value = calendar.dateComponents[keyPath: path] { message[name] = value }
            }
            if let zone = calendar.dateComponents.timeZone { message["timeZone"] = zone.identifier }
        case let interval as UNTimeIntervalNotificationTrigger:
            message = ["type": "interval", "seconds": interval.timeInterval]
        default:
            return nil
        }
        message["repeats"] = trigger?.repeats ?? false
        if let date = fireDate(of: trigger, after: now) {
            message["fireAt"] = (date.timeIntervalSince1970 * 1000).rounded()
        }
        return message
    }

    static func decodeRequest(_ message: PlatformChannel.Message) -> UNNotificationRequest? {
        guard let identifier = message["identifier"] as? String else { return nil }
        let content = UNMutableNotificationContent()
        if let fields = message["content"] as? PlatformChannel.Message {
            content.title = fields["title"] as? String ?? ""
            content.subtitle = fields["subtitle"] as? String ?? ""
            content.body = fields["body"] as? String ?? ""
            content.threadIdentifier = fields["threadIdentifier"] as? String ?? ""
            content.categoryIdentifier = fields["categoryIdentifier"] as? String ?? ""
            if let sound = fields["sound"] as? String {
                content.sound = sound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(sound))
            }
            content.badge = fields.int("badge").map { NSNumber(value: $0) }
            if let userInfo = fields["userInfo"] as? [String: Any] {
                content.userInfo = Dictionary(uniqueKeysWithValues: userInfo.map { (AnyHashable($0.key), $0.value) })
            }
        }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: decodeTrigger(message["trigger"] as? PlatformChannel.Message))
    }

    private static func decodeTrigger(_ message: PlatformChannel.Message?) -> UNNotificationTrigger? {
        guard let message else { return nil }
        let repeats = message.bool("repeats") ?? false
        switch message["type"] as? String {
        case "calendar":
            var components = DateComponents()
            for (name, path) in calendarUnits {
                if let value = message.int(name) { components[keyPath: path] = value }
            }
            if let zone = message["timeZone"] as? String { components.timeZone = TimeZone(identifier: zone) }
            return UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        case "interval":
            guard let seconds = message.double("seconds"), seconds > 0, !repeats || seconds >= 60 else { return nil }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: repeats)
            trigger.fireDate = message.double("fireAt").map { Date(timeIntervalSince1970: $0 / 1000) }
            return trigger
        default:
            return nil
        }
    }

    /// `{request, date}`, `date` in milliseconds since 1970.
    static func decodeNotification(_ message: PlatformChannel.Message) -> UNNotification? {
        guard let fields = message["request"] as? PlatformChannel.Message, let request = decodeRequest(fields) else { return nil }
        let date = message.double("date").map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return UNNotification(request: request, date: date)
    }

    /// `userInfo` as JSON takes it: string keys, and only values JSON can
    /// carry (Apple's property-list values less dates and data).
    private static func jsonSafe(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        var safe: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let key = key.base as? String, JSONSerialization.isValidJSONObject([value]) else { continue }
            safe[key] = value
        }
        return safe
    }
}
