import Foundation

/// Public deep-link value types (PARITY §6, rows DL1–DL4). Mirrors the Flutter
/// reference `types_deep_link_lifecycle.dart` + `types.dart` enums and the Android
/// `AttriaxDeepLinkTypes`.
///
/// The internal `AttriaxUri` value is not exposed publicly; events surface the
/// canonical URL as a `String` (`url`) so the public API stays framework-free.

/// What caused a deep-link event to be emitted (Flutter `AttriaxDeepLinkTrigger`).
public enum AttriaxDeepLinkTrigger {
    /// The app launched from a fully stopped state because of this link.
    case coldStart
    /// The link arrived while the app was already running.
    case foreground
    /// The link click happened before install and resolved on first launch.
    case deferred
}

/// Backend resolution outcome for a deep link (row DL4).
public enum AttriaxDeepLinkResolutionStatus {
    case matched
    case unmatched
    case invalid

    /// Map the wire `status` string (`matched|unmatched|invalid`) to the enum.
    /// An unknown/absent status is treated as unmatched (safe default: the link is
    /// not treated as a confirmed match).
    static func fromWire(_ value: String?) -> AttriaxDeepLinkResolutionStatus {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "matched": return .matched
        case "unmatched": return .unmatched
        case "invalid": return .invalid
        default: return .unmatched
        }
    }
}

/// How the SDK should open a resolved browser URL, when the backend returns one.
public enum AttriaxResolvedUrlOpenMode {
    case inApp
    case external
    case unknown

    static func fromWire(_ value: String?) -> AttriaxResolvedUrlOpenMode {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "in_app", "inapp": return .inApp
        case "external": return .external
        default: return .unknown
        }
    }
}

/// Optional browser action carried by a resolution (backend `browserAction`).
public struct AttriaxBrowserAction: Equatable {
    public let url: String
    public let openMode: AttriaxResolvedUrlOpenMode

    public init(url: String, openMode: AttriaxResolvedUrlOpenMode) {
        self.url = url
        self.openMode = openMode
    }
}

/// A raw deep-link input captured from the host's URL forwarding (row DL1).
public struct AttriaxRawDeepLinkEvent: Equatable {
    /// The raw URL string as received.
    public let url: String
    public let receivedAtMs: Int64
    public let isInitial: Bool

    let uri: AttriaxUri

    init(uri: AttriaxUri, receivedAtMs: Int64, isInitial: Bool) {
        self.uri = uri
        self.url = uri.stringValue
        self.receivedAtMs = receivedAtMs
        self.isInitial = isInitial
    }

    public static func == (lhs: AttriaxRawDeepLinkEvent, rhs: AttriaxRawDeepLinkEvent) -> Bool {
        lhs.url == rhs.url && lhs.receivedAtMs == rhs.receivedAtMs && lhs.isInitial == rhs.isInitial
    }
}

/// A handled deep-link event emitted to observers after resolution (rows DL2/DL3).
public struct AttriaxDeepLinkEvent {
    /// The canonical resolved URL (backend URI when present, else the original link).
    public let url: String
    public let clickedAtMs: Int64
    public let consumedAtMs: Int64
    public let found: Bool
    public let trigger: AttriaxDeepLinkTrigger
    public let isAttriaxSubDomain: Bool
    public let status: AttriaxDeepLinkResolutionStatus
    public let rawEvent: AttriaxRawDeepLinkEvent?
    public let data: [String: String]?
    public let utm: [String: String]?
    public let browserAction: AttriaxBrowserAction?

    /// The canonical URI (internal — the manager reads it for near-duplicate work).
    let uri: AttriaxUri

    init(
        uri: AttriaxUri,
        clickedAtMs: Int64,
        consumedAtMs: Int64,
        found: Bool,
        trigger: AttriaxDeepLinkTrigger,
        isAttriaxSubDomain: Bool,
        status: AttriaxDeepLinkResolutionStatus,
        rawEvent: AttriaxRawDeepLinkEvent? = nil,
        data: [String: String]? = nil,
        utm: [String: String]? = nil,
        browserAction: AttriaxBrowserAction? = nil
    ) {
        self.uri = uri
        self.url = uri.stringValue
        self.clickedAtMs = clickedAtMs
        self.consumedAtMs = consumedAtMs
        self.found = found
        self.trigger = trigger
        self.isAttriaxSubDomain = isAttriaxSubDomain
        self.status = status
        self.rawEvent = rawEvent
        self.data = data
        self.utm = utm
        self.browserAction = browserAction
    }

    public var isDeferred: Bool { trigger == .deferred }
    public var isColdStart: Bool { trigger == .coldStart }
    public var isForeground: Bool { trigger == .foreground }
}

/// Decoded backend deep-link resolution response (`/deep-links/resolve` data).
struct AttriaxDeepLinkResolutionResult {
    let matched: Bool
    let status: AttriaxDeepLinkResolutionStatus
    let isFirstLaunch: Bool
    let reason: String?
    let consumedAtMs: Int64?
    let path: String?
    let uri: String?
    let data: [String: String]?
    let utm: [String: String]?
    let browserAction: AttriaxBrowserAction?
}

/// Redirect defaults passed to `AttriaxDeepLinks.createDynamicLink`.
public struct AttriaxDynamicLinkRedirects {
    public let ios: Bool?
    public let android: Bool?

    public init(ios: Bool? = nil, android: Bool? = nil) {
        self.ios = ios
        self.android = android
    }
}

/// Open Graph social preview passed to `AttriaxDeepLinks.createDynamicLink`.
public struct AttriaxDynamicLinkSocialPreview {
    public let title: String?
    public let description: String?

    public init(title: String? = nil, description: String? = nil) {
        self.title = title
        self.description = description
    }
}

/// UTM parameters passed to `AttriaxDeepLinks.createDynamicLink`.
public struct AttriaxDynamicLinkUtms {
    public let source: String?
    public let medium: String?
    public let campaign: String?
    public let term: String?
    public let content: String?

    public init(
        source: String? = nil,
        medium: String? = nil,
        campaign: String? = nil,
        term: String? = nil,
        content: String? = nil
    ) {
        self.source = source
        self.medium = medium
        self.campaign = campaign
        self.term = term
        self.content = content
    }
}

/// The persisted dynamic-link record returned by the backend.
public struct AttriaxDynamicLinkRecord {
    public let id: String
    public let path: String
    public let shortUrl: String
    public let name: String?
    public let destinationUrl: String?
    public let group: String?
    public let prefix: String?
    public let data: [String: Any?]?

    public init(
        id: String,
        path: String,
        shortUrl: String,
        name: String? = nil,
        destinationUrl: String? = nil,
        group: String? = nil,
        prefix: String? = nil,
        data: [String: Any?]? = nil
    ) {
        self.id = id
        self.path = path
        self.shortUrl = shortUrl
        self.name = name
        self.destinationUrl = destinationUrl
        self.group = group
        self.prefix = prefix
        self.data = data
    }
}

/// Result of `AttriaxDeepLinks.createDynamicLink`.
public struct AttriaxCreateDynamicLinkResult {
    public let shortUrl: String
    public let record: AttriaxDynamicLinkRecord

    public init(shortUrl: String, record: AttriaxDynamicLinkRecord) {
        self.shortUrl = shortUrl
        self.record = record
    }
}

/// Observer for handled deep-link events (row DL1 listener pattern). A simple
/// closure-based listener — no Combine dependency required.
public typealias AttriaxDeepLinkListener = (AttriaxDeepLinkEvent) -> Void

/// Observer for raw (pre-resolution) deep-link inputs.
public typealias AttriaxRawDeepLinkListener = (AttriaxRawDeepLinkEvent) -> Void

/// An opaque token returned when registering a listener; pass it back to remove.
public struct AttriaxDeepLinkListenerToken: Equatable {
    let id: String
}
