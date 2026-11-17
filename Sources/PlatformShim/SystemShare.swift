import Foundation

/// What the game hands the system's share sheet, sorted the way Android's
/// takes it: the files to send (a video, or a picture) and the words
/// that go with them (the line and the link, joined).
///
/// UIKit's `UIActivityViewController` takes a mixed `[Any]` and works out
/// what each item is; Android's `ACTION_SEND` takes one stream and one text
/// extra. A game's share code on Android sorts its items into this
/// and hands it to `SystemShare.sheet`, which the shell installs.
public struct ShareRequest: Equatable, Sendable {
    public var files: [URL]
    public var text: String?

    public init(files: [URL], text: String?) {
        self.files = files
        self.text = text
    }

    /// `items` as the game passes them: strings, web links, and file URLs.
    /// An App Store page among them links `storePage` instead when given
    /// (`PlayStorePage`).
    public init(items: [Any], storePage: URL? = nil) {
        var files: [URL] = []
        var words: [String] = []
        for item in items {
            switch item {
            case let url as URL where url.isFileURL:
                files.append(url)
            case let url as URL:
                let link = storePage.flatMap { PlayStorePage.isAppStorePage(url) ? $0 : nil } ?? url
                words.append(link.absoluteString)
            case let string as String where !string.isEmpty:
                words.append(string)
            default:
                continue
            }
        }
        self.init(files: files, text: words.isEmpty ? nil : words.joined(separator: " "))
    }

    /// The MIME type Android's share targets filter on.
    public static func mimeType(of file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        default: "application/octet-stream"
        }
    }
}

public enum SystemShare {
    /// Opens the share sheet; nil where there is none (a host test).
    public nonisolated(unsafe) static var sheet: ((ShareRequest) -> Bool)?
    /// Puts text on the clipboard; nil where there is none.
    public nonisolated(unsafe) static var pasteboard: ((String) -> Void)?
}
