// Stands in for UserNotifications on Android: local notifications for a
// game's reminders. `UNUserNotificationCenter` and the rest live in the
// platform layer (PlatformShim/UserNotifications.swift), over the platform
// channel to `PlatformNotifications.java` (Templates/App/notifications).
@_exported import PlatformShim
