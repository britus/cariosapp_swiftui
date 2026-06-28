import Foundation
import UserNotifications

/** Centralizes UserDefaults keys used by the app. */
enum AppStorageKeys {
    /** Current CarIOS web-service URL. */
    static let serviceURL = "serviceUrl"
    /** APNs device token registered for push notifications. */
    static let deviceToken = "deviceToken"
    /** Whether Bluetooth LE scanning is enabled for service discovery. */
    static let bleScanEnabled = "bleScanEnabled"
    /** Stores the message prefix value. */
    static let messagePrefix = "message_"
}

/** Describes how a notification message entered the app. */
enum MessageState: String, Codable {
    /** No notification delivery state has been assigned. */
    case none
    /** Message was received while the app was in the foreground. */
    case willPresent
    /** Message was received through the notification delivery path. */
    case received
}

/** Represents a persisted push notification or remote data message. */
struct PushMessage: Identifiable, Codable, Hashable {
    /** Stable identifier used by SwiftUI collections and persisted models. */
    var id: String
    /** Stores the carios id value. */
    var cariosId: String = ""
    /** Stores the action id value. */
    var actionId: String = ""
    /** Stores the thread id value. */
    var threadId: String = ""
    /** Stores the target id value. */
    var targetId: String = ""
    /** User-facing title shown for this item. */
    var title: String = ""
    /** Stores the subtitle value. */
    var subtitle: String = ""
    /** Builds the SwiftUI view hierarchy for this view or scene. */
    var body: String = ""
    /** Stores the category value. */
    var category: String = ""
    /** Stores the topic value. */
    var topic: String = ""
    /** Stores the badge value. */
    var badge: Int = 0
    /** Stores the date value. */
    var date: Date = Date()
    /** Stores the state value. */
    var state: MessageState = .none
    /** Stores the is read value. */
    var isRead: Bool = false
    /** Stores the is data message value. */
    var isDataMessage: Bool = false
    /** Stores the parameters value. */
    var parameters: [String: String] = [:]
}

/** Stores power telemetry values returned by the CarIOS service. */
struct PowerInfo: Equatable {
    /** Stores the main battery value. */
    var mainBattery: Double?
    /** Stores the board battery value. */
    var boardBattery: Double?
    /** Stores the solar panels value. */
    var solarPanels: Double?
    /** Stores the engine key value. */
    var engineKey: Double?
}

/** Stores charger telemetry values keyed by their service field names. */
struct ChargerInfo: Equatable {
    /** Stores the values value. */
    var values: [String: JSONScalar] = [:]
}

/** Stores network addresses and service discovery details reported by CarIOS. */
struct NetworkInfo: Equatable {
    /** Stores the lan ip value. */
    var lanIp = ""
    /** Stores the wifi ap ip value. */
    var wifiApIp = ""
    /** Stores the wifi wan ip value. */
    var wifiWanIp = ""
    /** Stores the gsm wan ip value. */
    var gsmWanIp = ""
    /** Stores the gateway ip value. */
    var gatewayIp = ""
    /** Stores the service url value. */
    var serviceUrl = ""
}

/** Stores the current on/off state of each relay channel. */
struct RelayInfo: Equatable {
    /** Stores the states value. */
    var states: [Bool] = Array(repeating: false, count: 8)
}

/** Stores mobile modem telemetry values keyed by their service field names. */
struct MobileInfo: Equatable {
    /** Stores the values value. */
    var values: [String: JSONScalar] = [:]
}

/** Wraps JSON scalar values as displayable strings while preserving Codable support. */
struct JSONScalar: Codable, Hashable, CustomStringConvertible {
    /** String-backed scalar value used for display and encoding. */
    var value: String

    /** Creates a new instance with the supplied values. */
    init(_ value: String = "") {
        self.value = value
    }

    /** Creates a new instance with the supplied values. */
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode(Int.self) {
            self.value = "\(value)"
        } else if let value = try? container.decode(Double.self) {
            self.value = NumberFormatters.decimal.string(from: NSNumber(value: value)) ?? "\(value)"
        } else if let value = try? container.decode(Bool.self) {
            self.value = value ? "true" : "false"
        } else if container.decodeNil() {
            self.value = ""
        } else {
            self.value = "..."
        }
    }

    /** Performs the encode operation. */
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /** Display representation of the wrapped scalar value. */
    var description: String { value }
}

/** Provides shared number formatters used by telemetry views. */
enum NumberFormatters {
    /** Formatter for voltage and fixed two-decimal telemetry values. */
    static let voltage: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /** Formatter for compact decimal telemetry values. */
    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 3
        return formatter
    }()
}

/** Adds CarIOS-specific behavior to Dictionary. */
extension Dictionary where Key == String, Value == Any {
    /** Performs the string operation. */
    func string(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    /** Converts a charger scalar field into a Double for gauge rendering. */
    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    /** Performs the bool operation. */
    func bool(_ key: String) -> Bool {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? Int { return value != 0 }
        if let value = self[key] as? String { return value == "true" || value == "1" }
        return false
    }
}

/** Adds CarIOS-specific behavior to PushMessage. */
extension PushMessage {
    /** Creates a new instance with the supplied values. */
    init(id: String, content: UNNotificationContent, state: MessageState, actionId: String) {
        self.id = id
        self.cariosId = id
        self.actionId = actionId
        self.threadId = content.threadIdentifier
        self.targetId = content.targetContentIdentifier ?? ""
        self.title = content.title
        self.subtitle = content.subtitle
        self.body = content.body
        self.category = content.categoryIdentifier
        self.badge = Int(truncating: content.badge ?? 0)
        self.date = Date()
        self.state = state
        self.isDataMessage = content.userInfo["aps"] == nil
        self.parameters = content.userInfo.reduce(into: [:]) { result, item in
            result["\(item.key)"] = "\(item.value)"
        }
    }

    /** Creates a new instance with the supplied values. */
    init(id: String, userInfo: [AnyHashable: Any], state: MessageState, actionId: String) {
        self.id = id
        self.cariosId = id
        self.actionId = actionId
        self.date = Date()
        self.state = state
        self.isDataMessage = userInfo["aps"] == nil
        self.parameters = userInfo.reduce(into: [:]) { result, item in
            result["\(item.key)"] = "\(item.value)"
        }
        if let aps = userInfo["aps"] as? [String: Any] {
            if let alert = aps["alert"] as? [String: Any] {
                title = alert["title"] as? String ?? ""
                subtitle = alert["subtitle"] as? String ?? ""
                body = alert["body"] as? String ?? ""
            } else if let alert = aps["alert"] as? String {
                body = alert
            }
            badge = aps["badge"] as? Int ?? 0
            category = aps["category"] as? String ?? ""
            threadId = aps["thread-id"] as? String ?? ""
        }
        title = userInfo["title"] as? String ?? title
        subtitle = userInfo["subtitle"] as? String ?? subtitle
        body = userInfo["body"] as? String ?? body
        category = userInfo["category"] as? String ?? category
        topic = userInfo["topic"] as? String ?? topic
    }
}
