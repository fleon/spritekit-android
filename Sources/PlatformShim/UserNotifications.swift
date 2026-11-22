import Foundation

// Apple's UserNotifications for Android: local notifications only, the
// surface a game's reminder code uses, with Apple's spellings so it compiles
// unedited (`Modules/Sources/UserNotifications` answers `import
// UserNotifications`). The device half is `PlatformNotifications.java`
// (Library/spritekit-notifications), reached over `PlatformChannel`:
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

    public static var notificationsNotAllowed: Code { .notificationsNotAllowed }
    public static var attachmentInvalidURL: Code { .attachmentInvalidURL }
    public static var attachmentUnrecognizedType: Code { .attachmentUnrecognizedType }
    public static var attachmentInvalidFileSize: Code { .attachmentInvalidFileSize }
    public static var attachmentNotInDataStore: Code { .attachmentNotInDataStore }
    public static var attachmentMoveIntoDataStoreFailed: Code { .attachmentMoveIntoDataStoreFailed }
    public static var attachmentCorrupt: Code { .attachmentCorrupt }
    public static var notificationInvalidNoDate: Code { .notificationInvalidNoDate }
    public static var notificationInvalidNoContent: Code { .notificationInvalidNoContent }
    public static var contentProvidingObjectNotAllowed: Code { .contentProvidingObjectNotAllowed }
    public static var contentProvidingInvalid: Code { .contentProvidingInvalid }
    public static var badgeInputInvalid: Code { .badgeInputInvalid }
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
    /// What tells a critical sound from the plain one; Apple's equality
    /// compares both, the volume only when one was given.
    let isCritical: Bool
    let criticalVolume: Float?

    init(soundName: String?, critical: Bool = false, volume: Float? = nil) {
        name = soundName
        isCritical = critical
        criticalVolume = volume
    }

    public convenience init(named name: UNNotificationSoundName) {
        self.init(soundName: name.rawValue)
    }

    /// A new object each time, equal to every other, as Apple's is.
    open class var `default`: UNNotificationSound { UNNotificationSound(soundName: nil) }

    /// Critical alerts need an entitlement Android has no counterpart for:
    /// they play as the default sound does.
    open class var defaultCritical: UNNotificationSound { UNNotificationSound(soundName: nil, critical: true) }

    open class func defaultCriticalSound(withAudioVolume volume: Float) -> UNNotificationSound {
        UNNotificationSound(soundName: nil, critical: true, volume: volume)
    }

    open class func criticalSoundNamed(_ name: UNNotificationSoundName) -> UNNotificationSound {
        UNNotificationSound(soundName: name.rawValue, critical: true)
    }

    open class func criticalSoundNamed(_ name: UNNotificationSoundName, withAudioVolume volume: Float) -> UNNotificationSound {
        UNNotificationSound(soundName: name.rawValue, critical: true, volume: volume)
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNNotificationSound else { return false }
        return other.name == name && other.isCritical == isCritical && other.criticalVolume == criticalVolume
    }

    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(isCritical)
        hasher.combine(criticalVolume)
        return hasher.finalize()
    }
}

/// How insistently a notification asks for attention (Apple's raw values).
public enum UNNotificationInterruptionLevel: UInt, Sendable {
    case passive = 0
    case active = 1
    case timeSensitive = 2
    case critical = 3

    var name: String {
        switch self {
        case .passive: "passive"
        case .active: "active"
        case .timeSensitive: "timeSensitive"
        case .critical: "critical"
        }
    }

    init?(name: String) {
        switch name {
        case "passive": self = .passive
        case "active": self = .active
        case "timeSensitive": self = .timeSensitive
        case "critical": self = .critical
        default: return nil
        }
    }
}

/// A file shown with a notification. Kept, not shown: Android's
/// notifications here carry text alone.
open class UNNotificationAttachment: NSObject, NSCopying {
    open var identifier: String { storedIdentifier }
    open var url: URL { storedURL }
    open var type: String { "" }

    private let storedIdentifier: String
    private let storedURL: URL

    public init(identifier: String, url: URL, options: [AnyHashable: Any]? = nil) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw UNError(.attachmentInvalidURL)
        }
        storedIdentifier = identifier
        storedURL = url
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }
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
        var interruptionLevel = UNNotificationInterruptionLevel.active
        var relevanceScore = 0.0
        var filterCriteria: String?
        var attachments: [UNNotificationAttachment] = []
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
    open var interruptionLevel: UNNotificationInterruptionLevel { fields.interruptionLevel }
    open var relevanceScore: Double { fields.relevanceScore }
    open var filterCriteria: String? { fields.filterCriteria }
    open var attachments: [UNNotificationAttachment] { fields.attachments }

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
            && a.interruptionLevel == b.interruptionLevel && a.relevanceScore == b.relevanceScore
            && a.filterCriteria == b.filterCriteria
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
    open override var interruptionLevel: UNNotificationInterruptionLevel {
        get { fields.interruptionLevel }
        set { fields.interruptionLevel = newValue }
    }
    open override var relevanceScore: Double {
        get { fields.relevanceScore }
        set { fields.relevanceScore = newValue }
    }
    open override var filterCriteria: String? {
        get { fields.filterCriteria }
        set { fields.filterCriteria = newValue }
    }
    open override var attachments: [UNNotificationAttachment] {
        get { fields.attachments }
        set { fields.attachments = newValue }
    }
}

// MARK: - Triggers

open class UNNotificationTrigger: NSObject, NSCopying {
    open var repeats: Bool { storedRepeats }
    private let storedRepeats: Bool

    init(repeats: Bool) {
        storedRepeats = repeats
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }
}

open class UNCalendarNotificationTrigger: UNNotificationTrigger {
    open var dateComponents: DateComponents { storedComponents }
    private let storedComponents: DateComponents

    public init(dateMatching dateComponents: DateComponents, repeats: Bool) {
        storedComponents = dateComponents
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
    open var timeInterval: TimeInterval { storedInterval }
    private let storedInterval: TimeInterval
    /// When a pending request's next fire is known (as Java reports it).
    var fireDate: Date?

    public init(timeInterval: TimeInterval, repeats: Bool) {
        // Apple raises for these too.
        precondition(timeInterval > 0, "time interval must be greater than 0")
        precondition(!repeats || timeInterval >= 60, "time interval must be at least 60 if repeating")
        storedInterval = timeInterval
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
    open var identifier: String { storedIdentifier }
    open var content: UNNotificationContent { storedContent }
    open var trigger: UNNotificationTrigger? { storedTrigger }

    private let storedIdentifier: String
    private let storedContent: UNNotificationContent
    private let storedTrigger: UNNotificationTrigger?

    public init(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        storedIdentifier = identifier
        // A copy, so changing the game's content afterwards changes nothing.
        storedContent = UNNotificationContent(fields: content.fields)
        storedTrigger = trigger
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNNotificationRequest else { return false }
        return other.identifier == identifier && other.content == content && other.trigger == trigger
    }

    open override var hash: Int { identifier.hashValue }
}

open class UNNotification: NSObject {
    open var date: Date { storedDate }
    open var request: UNNotificationRequest { storedRequest }

    private let storedDate: Date
    private let storedRequest: UNNotificationRequest

    init(request: UNNotificationRequest, date: Date) {
        storedRequest = request
        storedDate = date
    }
}

open class UNNotificationResponse: NSObject {
    open var notification: UNNotification { storedNotification }
    open var actionIdentifier: String { storedAction }

    private let storedNotification: UNNotification
    private let storedAction: String

    init(notification: UNNotification, actionIdentifier: String) {
        storedNotification = notification
        storedAction = actionIdentifier
    }
}

/// Android has one switch where iOS has several: when notifications are
/// allowed, every one of these is `.enabled`; refused, `.disabled`; not yet
/// asked, `.notSupported`.
open class UNNotificationSettings: NSObject {
    open var authorizationStatus: UNAuthorizationStatus { storedStatus }
    private let storedStatus: UNAuthorizationStatus

    init(authorizationStatus: UNAuthorizationStatus) {
        storedStatus = authorizationStatus
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

// MARK: - Categories

public struct UNNotificationActionOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let authenticationRequired = UNNotificationActionOptions(rawValue: 1 << 0)
    public static let destructive = UNNotificationActionOptions(rawValue: 1 << 1)
    public static let foreground = UNNotificationActionOptions(rawValue: 1 << 2)
}

public struct UNNotificationCategoryOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let customDismissAction = UNNotificationCategoryOptions(rawValue: 1 << 0)
    public static let allowInCarPlay = UNNotificationCategoryOptions(rawValue: 1 << 1)
    public static let hiddenPreviewsShowTitle = UNNotificationCategoryOptions(rawValue: 1 << 2)
    public static let hiddenPreviewsShowSubtitle = UNNotificationCategoryOptions(rawValue: 1 << 3)
    public static let allowAnnouncement = UNNotificationCategoryOptions(rawValue: 1 << 4)
}

/// An action button's image: an SF Symbol or a template image, by name.
open class UNNotificationActionIcon: NSObject, NSCopying {
    private let imageName: String
    private let isTemplate: Bool

    public init(templateImageName: String) {
        imageName = templateImageName
        isTemplate = true
    }

    public init(systemImageName: String) {
        imageName = systemImageName
        isTemplate = false
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNNotificationActionIcon else { return false }
        return other.imageName == imageName && other.isTemplate == isTemplate
    }

    open override var hash: Int { imageName.hashValue }
}

/// A button a notification of a category offers. Kept for the game to read
/// back: Android's notifications here offer no buttons.
///
/// Equal, as Apple's, when identifier, title and options are; the icon
/// isn't compared.
open class UNNotificationAction: NSObject, NSCopying {
    open var identifier: String { storedIdentifier }
    open var title: String { storedTitle }
    open var options: UNNotificationActionOptions { storedOptions }
    open var icon: UNNotificationActionIcon? { storedIcon }

    private let storedIdentifier: String
    private let storedTitle: String
    private let storedOptions: UNNotificationActionOptions
    private let storedIcon: UNNotificationActionIcon?

    public init(identifier: String, title: String, options: UNNotificationActionOptions = []) {
        storedIdentifier = identifier
        storedTitle = title
        storedOptions = options
        storedIcon = nil
    }

    public init(identifier: String, title: String, options: UNNotificationActionOptions = [], icon: UNNotificationActionIcon?) {
        storedIdentifier = identifier
        storedTitle = title
        storedOptions = options
        storedIcon = icon
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNNotificationAction else { return false }
        return other.identifier == identifier && other.title == title && other.options == options
    }

    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(identifier)
        hasher.combine(title)
        hasher.combine(options.rawValue)
        return hasher.finalize()
    }
}

/// An action that asks for a line of text. As on Apple, it equals a plain
/// action with the same identifier, title and options; between two of
/// these, the button title and placeholder count too.
open class UNTextInputNotificationAction: UNNotificationAction {
    open var textInputButtonTitle: String { storedButtonTitle }
    open var textInputPlaceholder: String { storedPlaceholder }

    private let storedButtonTitle: String
    private let storedPlaceholder: String

    public init(
        identifier: String, title: String, options: UNNotificationActionOptions = [],
        textInputButtonTitle: String, textInputPlaceholder: String
    ) {
        storedButtonTitle = textInputButtonTitle
        storedPlaceholder = textInputPlaceholder
        super.init(identifier: identifier, title: title, options: options)
    }

    public init(
        identifier: String, title: String, options: UNNotificationActionOptions = [], icon: UNNotificationActionIcon?,
        textInputButtonTitle: String, textInputPlaceholder: String
    ) {
        storedButtonTitle = textInputButtonTitle
        storedPlaceholder = textInputPlaceholder
        super.init(identifier: identifier, title: title, options: options, icon: icon)
    }

    open override func isEqual(_ object: Any?) -> Bool {
        guard super.isEqual(object) else { return false }
        guard let other = object as? UNTextInputNotificationAction else { return true }
        return other.textInputButtonTitle == textInputButtonTitle && other.textInputPlaceholder == textInputPlaceholder
    }
}

/// A kind of notification and its actions, kept by the center. Equal, as
/// Apple's, when every field is.
open class UNNotificationCategory: NSObject, NSCopying {
    open var identifier: String { storedIdentifier }
    open var actions: [UNNotificationAction] { storedActions }
    open var intentIdentifiers: [String] { storedIntents }
    open var options: UNNotificationCategoryOptions { storedOptions }
    /// Empty unless given, as on Apple.
    open var hiddenPreviewsBodyPlaceholder: String { storedPlaceholder }
    open var categorySummaryFormat: String { storedSummaryFormat }

    private let storedIdentifier: String
    private let storedActions: [UNNotificationAction]
    private let storedIntents: [String]
    private let storedOptions: UNNotificationCategoryOptions
    private let storedPlaceholder: String
    private let storedSummaryFormat: String

    public init(
        identifier: String, actions: [UNNotificationAction], intentIdentifiers: [String],
        options: UNNotificationCategoryOptions = []
    ) {
        storedIdentifier = identifier
        storedActions = actions
        storedIntents = intentIdentifiers
        storedOptions = options
        storedPlaceholder = ""
        storedSummaryFormat = ""
    }

    public init(
        identifier: String, actions: [UNNotificationAction], intentIdentifiers: [String],
        hiddenPreviewsBodyPlaceholder: String, options: UNNotificationCategoryOptions = []
    ) {
        storedIdentifier = identifier
        storedActions = actions
        storedIntents = intentIdentifiers
        storedOptions = options
        storedPlaceholder = hiddenPreviewsBodyPlaceholder
        storedSummaryFormat = ""
    }

    public init(
        identifier: String, actions: [UNNotificationAction], intentIdentifiers: [String],
        hiddenPreviewsBodyPlaceholder: String?, categorySummaryFormat: String?,
        options: UNNotificationCategoryOptions = []
    ) {
        storedIdentifier = identifier
        storedActions = actions
        storedIntents = intentIdentifiers
        storedOptions = options
        storedPlaceholder = hiddenPreviewsBodyPlaceholder ?? ""
        storedSummaryFormat = categorySummaryFormat ?? ""
    }

    open func copy(with zone: NSZone? = nil) -> Any { self }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UNNotificationCategory else { return false }
        return other.identifier == identifier && other.actions == actions
            && other.intentIdentifiers == intentIdentifiers && other.options == options
            && other.hiddenPreviewsBodyPlaceholder == hiddenPreviewsBodyPlaceholder
            && other.categorySummaryFormat == categorySummaryFormat
    }

    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(identifier)
        hasher.combine(actions)
        hasher.combine(intentIdentifiers)
        hasher.combine(options.rawValue)
        return hasher.finalize()
    }
}

// MARK: - Delegate

/// Apple's: an `NSObjectProtocol` with no actor of its own, called on the
/// frame thread (where `PlatformChannel` delivers). Each method has a
/// default, as Apple's are optional; the async forms fall back to the
/// completion-handler forms, so a delegate implements whichever it likes.
public protocol UNUserNotificationCenterDelegate: NSObjectProtocol {
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
    private let authorizations = RequestTable<Bool>(ifAbandoned: false)
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
        authorizations.send(start: { request in
            // Nothing to ask: the player stays undecided.
            guard let answer = channel?.call("notifications.request", ["options": Self.names(of: options), "request": request]) else { return false }
            updateStatus(answer)
            return answer.bool("granted")
        }, then: { completionHandler($0, nil) })
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

    private var categories: Set<UNNotificationCategory> = []

    open func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    open func getNotificationCategories(completionHandler: @escaping @Sendable (Set<UNNotificationCategory>) -> Void) {
        completionHandler(categories)
    }

    open func notificationCategories() async -> Set<UNNotificationCategory> {
        categories
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
            guard let request = body.int("request") else { return }
            authorizations.finish(id: request, body.bool("granted") ?? false)
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
        if content.interruptionLevel != .active { encodedContent["interruptionLevel"] = content.interruptionLevel.name }
        if content.relevanceScore != 0 { encodedContent["relevanceScore"] = content.relevanceScore }
        if let filter = content.filterCriteria { encodedContent["filterCriteria"] = filter }
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
            if let level = (fields["interruptionLevel"] as? String).flatMap(UNNotificationInterruptionLevel.init(name:)) {
                content.interruptionLevel = level
            }
            content.relevanceScore = fields.double("relevanceScore") ?? 0
            content.filterCriteria = fields["filterCriteria"] as? String
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
