import Foundation
import UserNotifications

enum AppStorageKeys {
    static let serviceURL = "serviceUrl"
    static let deviceToken = "deviceToken"
    static let bleScanEnabled = "bleScanEnabled"
    static let messagePrefix = "message_"
}

enum MessageState: String, Codable {
    case none
    case willPresent
    case received
}

struct PushMessage: Identifiable, Codable, Hashable {
    var id: String
    var cariosId: String = ""
    var actionId: String = ""
    var threadId: String = ""
    var targetId: String = ""
    var title: String = ""
    var subtitle: String = ""
    var body: String = ""
    var category: String = ""
    var topic: String = ""
    var badge: Int = 0
    var date: Date = Date()
    var state: MessageState = .none
    var isRead: Bool = false
    var isDataMessage: Bool = false
    var parameters: [String: String] = [:]
}

struct PowerInfo: Equatable {
    var mainBattery: Double?
    var boardBattery: Double?
    var solarPanels: Double?
    var engineKey: Double?
}

struct ChargerInfo: Equatable {
    var values: [String: JSONScalar] = [:]
}

struct NetworkInfo: Equatable {
    var lanIp = ""
    var wifiApIp = ""
    var wifiWanIp = ""
    var gsmWanIp = ""
    var gatewayIp = ""
    var serviceUrl = ""
}

struct RelayInfo: Equatable {
    var states: [Bool] = Array(repeating: false, count: 8)
}

struct MobileInfo: Equatable {
    var values: [String: JSONScalar] = [:]
}

struct JSONScalar: Codable, Hashable, CustomStringConvertible {
    var value: String

    init(_ value: String = "") {
        self.value = value
    }

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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    var description: String { value }
}

enum NumberFormatters {
    static let voltage: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 3
        return formatter
    }()
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    func bool(_ key: String) -> Bool {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? Int { return value != 0 }
        if let value = self[key] as? String { return value == "true" || value == "1" }
        return false
    }
}

extension PushMessage {
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
