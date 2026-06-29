import Combine
import CoreBluetooth
import Darwin
import Foundation
import Network
import UserNotifications

@MainActor
/** Owns app state, service communication, BLE discovery, polling, and message persistence. */
final class AppStore: ObservableObject {
    /** Current CarIOS web-service URL. */
    @Published var serviceURL: String = UserDefaults.standard.string(forKey: AppStorageKeys.serviceURL) ?? ""
    /** Whether Bluetooth LE scanning is enabled for service discovery. */
    @Published var bleScanEnabled: Bool = UserDefaults.standard.object(forKey: AppStorageKeys.bleScanEnabled) as? Bool ?? true
    /** APNs device token registered for push notifications. */
    @Published var deviceToken: String = UserDefaults.standard.string(forKey: AppStorageKeys.deviceToken) ?? ""
    /** Current notification authorization status shown in diagnostics. */
    @Published var notificationAuthorization: String = "Unknown"
    /** Whether Network framework currently reports a satisfied local path. */
    @Published var isLocalNetworkAvailable = false
    /** User-facing description of the active network path. */
    @Published var networkPath = "Unknown"
    /** Local Wi-Fi IPv4 address detected on the device. */
    @Published var wifiIPAddress = ""
    /** Private network prefix derived from the local Wi-Fi address. */
    @Published var wifiNetworkPrefix = ""
    /** IPv4 host extracted from the configured service URL. */
    @Published var serviceHostIPAddress = ""
    /** Whether the service host appears to be on the current Wi-Fi subnet. */
    @Published var isServiceURLOnWiFiNetwork = false
    /** Current Bluetooth LE connection or scanning state. */
    @Published var bleState = "Idle"
    /** Whether BLE is currently considered connected and ready. */
    @Published var isBleConnected = false
    /** Timestamp of the last successful remote data update. */
    @Published var lastUpdated: Date?
    /** Most recent user-visible error message. */
    @Published var lastError: String?
    /** Latest power telemetry snapshot. */
    @Published var power = PowerInfo()
    /** Latest charger telemetry snapshot. */
    @Published var charger = ChargerInfo()
    /** Latest network telemetry snapshot. */
    @Published var network = NetworkInfo()
    /** Latest relay state snapshot. */
    @Published var relays = RelayInfo()
    /** Latest mobile telemetry snapshot. */
    @Published var mobile = MobileInfo()
    /** Stored notification and data messages, newest first. */
    @Published var messages: [PushMessage] = []
    /** Pending navigation request that should be consumed by the root view. */
    @Published var requestedTab: AppTab?
    /** Local toggle state for trace-style service commands. */
    @Published var commandToggleStates: [ServiceCommand: Bool] = [:]
    /** Optimistic relay states waiting for confirmation from the service. */
    @Published private var pendingRelayStates: [Int: Bool] = [:]
    /** Optimistic charger relay states waiting for confirmation from the service. */
    @Published private var pendingChargerRelayStates: [Int: Bool] = [:]
    /** Tracks the last successful load timestamp for each remote data type. */
    @Published private var receivedRemoteData: [String: Date] = [:]

    /** Stores the client value. */
    private let client = CarIOSHTTPClient()
    /** Stores the history value. */
    private let history = MessageHistoryStore()
    /** Stores the path monitor value. */
    private let pathMonitor = NWPathMonitor()
    /** Stores the path queue value. */
    private let pathQueue = DispatchQueue(label: "carios.netmon")
    /** Stores the ble client value. */
    private lazy var bleClient = CarIOSBLEClient(delegate: self)
    /** Stores the polling task value. */
    private var pollingTask: Task<Void, Never>?
    /** Stores the active poll type value. */
    private var activePollType: String = "p"
    /** Stores the is started value. */
    private var isStarted = false

    /** Whether the configured service URL can be parsed as a URL. */
    var hasServiceURL: Bool {
        URL(string: serviceURL) != nil
    }

    /** Whether all local preconditions for service communication are satisfied. */
    var canCommunicateWithServer: Bool {
        hasServiceURL && isLocalNetworkAvailable && isServiceURLOnWiFiNetwork && !deviceToken.isEmpty
    }

    /** Returns whether data has been received for the requested service type. */
    func hasReceivedRemoteData(for type: String?) -> Bool {
        guard let type else { return true }
        return receivedRemoteData[type] != nil
    }

    /** Number of stored messages that have not been marked read. */
    var unreadMessageCount: Int {
        messages.filter { !$0.isRead }.count
    }

    /** Returns whether a relay update is awaiting service confirmation. */
    func isRelayPending(index: Int) -> Bool {
        pendingRelayStates[index] != nil
    }

    /** Returns whether a charger relay update is awaiting service confirmation. */
    func isChargerRelayPending(mode: Int) -> Bool {
        pendingChargerRelayStates[mode] != nil
    }

    /** Starts BLE scanning or resumes scanning when Bluetooth is already powered on. */
    func start() {
        guard !isStarted else { return }
        isStarted = true
        messages = history.load()
        updateApplicationBadge()
        startNetworkMonitor()
        if bleScanEnabled {
            bleClient.start()
        }
        startPolling()
    }

    /** Starts the active-tab polling loop. */
    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.refreshActiveTab()
            }
        }
    }

    /** Cancels the active polling loop. */
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /** Restarts foreground-only communication tasks. */
    func enterForeground() {
        startPolling()
        if bleScanEnabled {
            bleClient.start()
        }
    }

    /** Stops foreground-only communication tasks. */
    func enterBackground() {
        stopPolling()
    }

    /** Changes which service object is polled for the active tab. */
    func setActivePollType(_ type: String?) {
        activePollType = type ?? ""
        if type == nil {
            stopPolling()
        } else {
            receivedRemoteData.removeValue(forKey: activePollType)
            if pollingTask == nil {
                startPolling()
            }
        }
    }

    /** Refreshes the service data associated with the active poll type. */
    func refreshActiveTab() async {
        guard canCommunicateWithServer else { return }
        switch activePollType {
        case "p": await loadPower()
        case "c": await loadCharger()
        case "n": await loadNetwork()
        case "r": await loadRelays()
        case "m": await loadMobile()
        default: break
        }
    }

    /** Refreshes all service data groups sequentially. */
    func refreshAll() async {
        guard canCommunicateWithServer else { return }
        await loadPower()
        await loadCharger()
        await loadNetwork()
        await loadRelays()
        await loadMobile()
    }

    /** Loads power telemetry from the CarIOS service. */
    func loadPower() async {
        do {
            let data = try await requestObject(type: "p")
            power = PowerInfo(
                mainBattery: data.double("m"),
                boardBattery: data.double("b"),
                solarPanels: data.double("p"),
                engineKey: data.double("e")
            )
            markRemoteDataReceived(type: "p")
        } catch {
            markRemoteDataFailed(type: "p")
            lastError = error.localizedDescription
        }
    }

    /** Loads charger telemetry and reconciles pending relay changes. */
    func loadCharger() async {
        do {
            let data = try await requestObject(type: "c")
            var values = scalarMap(data)
            for mode in [1, 2] {
                let key = "sys.r\(mode)"
                guard let desiredState = pendingChargerRelayStates[mode] else { continue }
                if boolValue(values[key]) == desiredState {
                    pendingChargerRelayStates.removeValue(forKey: mode)
                } else {
                    values[key] = JSONScalar(desiredState ? "1" : "0")
                }
            }
            charger = ChargerInfo(values: values)
            markRemoteDataReceived(type: "c")
        } catch {
            markRemoteDataFailed(type: "c")
            lastError = error.localizedDescription
        }
    }

    /** Loads network telemetry and updates the stored service URL when provided. */
    func loadNetwork() async {
        do {
            let data = try await requestObject(type: "n")
            let next = NetworkInfo(
                lanIp: data.string("lanIp"),
                wifiApIp: data.string("wifiApIp"),
                wifiWanIp: data.string("wifiWanIp"),
                gsmWanIp: data.string("gsmWanIp"),
                gatewayIp: data.string("gatewayIp"),
                serviceUrl: data.string("serviceUrl")
            )
            network = next
            if !next.serviceUrl.isEmpty {
                setServiceURL(next.serviceUrl)
            }
            markRemoteDataReceived(type: "n")
        } catch {
            markRemoteDataFailed(type: "n")
            lastError = error.localizedDescription
        }
    }

    /** Loads relay state and reconciles pending relay changes. */
    func loadRelays() async {
        do {
            let data = try await requestObject(type: "r")
            var states = (0..<8).map { data.bool("\($0)") }
            for (index, desiredState) in Array(pendingRelayStates) {
                guard states.indices.contains(index) else {
                    pendingRelayStates.removeValue(forKey: index)
                    continue
                }
                if states[index] == desiredState {
                    pendingRelayStates.removeValue(forKey: index)
                } else {
                    states[index] = desiredState
                }
            }
            relays = RelayInfo(states: states)
            markRemoteDataReceived(type: "r")
        } catch {
            markRemoteDataFailed(type: "r")
            lastError = error.localizedDescription
        }
    }

    /** Loads mobile modem telemetry from the CarIOS service. */
    func loadMobile() async {
        do {
            let data = try await requestObject(type: "m")
            mobile = MobileInfo(values: scalarMap(data))
            markRemoteDataReceived(type: "m")
        } catch {
            markRemoteDataFailed(type: "m")
            lastError = error.localizedDescription
        }
    }

    /** Persists a new service URL and refreshes dependent connection state. */
    func setServiceURL(_ url: String) {
        guard serviceURL != url else { return }
        serviceURL = url
        UserDefaults.standard.set(url, forKey: AppStorageKeys.serviceURL)
        receivedRemoteData.removeAll()
        updateServiceURLNetworkValidation()
        sendDeviceTokenOverBle()
    }

    /** Persists BLE scanning preference and starts or stops scanning. */
    func setBleScanEnabled(_ enabled: Bool) {
        bleScanEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppStorageKeys.bleScanEnabled)
        if enabled {
            bleClient.start()
        } else {
            bleClient.stop()
        }
    }

    /** Optimistically updates a relay and sends the change to the service. */
    func setRelay(index: Int, state: Bool) {
        pendingRelayStates[index] = state
        relays.states[index] = state
        Task {
            await sendAction(type: "r", action: ["i": index, "s": state])
            await loadRelays()
        }
    }

    /** Optimistically updates a charger relay and sends the change to the service. */
    func setChargerRelay(mode: Int, state: Bool) {
        pendingChargerRelayStates[mode] = state
        charger.values["sys.r\(mode)"] = JSONScalar(state ? "1" : "0")
        Task {
            await sendAction(type: "c", action: ["m": mode])
            await loadCharger()
        }
    }

    /** Sends a network maintenance command to the service. */
    func networkCommand(_ command: NetworkCommand) {
        Task {
            await sendAction(type: "n", action: ["t": command.rawValue])
        }
    }

    /** Sends a service command to the backend. */
    func command(_ command: ServiceCommand) {
        Task {
            await sendAction(type: "s", action: ["t": "c", "c": command.rawValue, "d": "255"])
        }
    }

    /** Updates a local command toggle and sends its command. */
    func setCommandToggle(_ serviceCommand: ServiceCommand, enabled: Bool) {
        commandToggleStates[serviceCommand] = enabled
        command(serviceCommand)
    }

    /** Registers the current APNs token with the CarIOS service. */
    func registerDeviceTokenWithServer() {
        guard canCommunicateWithServer else { return }
        Task {
            let _token = cariosapp.deviceToken(deviceToken)
            await sendAction(type: "s", action: ["t": "m", "c": "s", "d": _token])
        }
    }

    /** Sends the current APNs token through the BLE channel when available. */
    func sendDeviceTokenOverBle() {
        guard !deviceToken.isEmpty else { return }
        bleClient.sendToken(deviceToken)
    }

    /** Adds or updates a message and persists it to history. */
    func addMessage(from content: UNNotificationContent, id: String, state: MessageState, actionId: String) {
        let message = PushMessage(id: id, content: content, state: state, actionId: actionId)
        addMessage(message)
    }

    /** Adds or updates a message and persists it to history. */
    func addMessage(from userInfo: [AnyHashable: Any], state: MessageState, actionId: String) {
        let message = PushMessage(id: UUID().uuidString, userInfo: userInfo, state: state, actionId: actionId)
        addMessage(message)
    }

    /** Adds or updates a message and persists it to history. */
    func addMessage(_ message: PushMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.insert(message, at: 0)
        }
        history.save(message)
        updateApplicationBadge()
    }

    /** Marks a stored message as read and updates the application badge. */
    func markMessageRead(_ message: PushMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isRead = true
        history.save(messages[index])
        updateApplicationBadge()
    }

    /** Deletes a stored message and updates the application badge. */
    func deleteMessage(_ message: PushMessage) {
        messages.removeAll { $0.id == message.id }
        history.remove(message)
        updateApplicationBadge()
    }

    /** Removes all stored messages and clears the application badge. */
    func clearMessages() {
        messages.removeAll()
        history.removeAll()
        updateApplicationBadge()
    }

    /** Requests navigation to the messages tab. */
    func openMessages() {
        requestedTab = .messages
    }

    /** Clears a consumed messages-tab navigation request. */
    func finishOpenMessagesRequest() {
        requestedTab = nil
    }

    /** Synchronizes the app badge with the unread message count. */
    private func updateApplicationBadge() {
        UNUserNotificationCenter.current().setBadgeCount(unreadMessageCount)
    }

    /** Requests a typed telemetry object from the CarIOS service. */
    private func requestObject(type: String) async throws -> [String: Any] {
        let response = try await client.call(serviceURL: serviceURL, token: deviceToken, payload: ["v": "0787", "o": type])
        guard let result = response[type] as? [String: Any] else {
            throw CarIOSError.invalidResponse("Missing object '\(type)'")
        }
        return result
    }

    /** Sends an action payload to the CarIOS service and records service errors. */
    private func sendAction(type: String, action: [String: Any]) async {
        guard canCommunicateWithServer else { return }
        do {
            let response = try await client.call(serviceURL: serviceURL, token: deviceToken, payload: ["v": "0787", "x": type, "a": action])
            if let code = response["c"] as? Int, code != 0 {
                lastError = response["r"] as? String ?? "Server returned code \(code)"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /** Converts a raw service dictionary into displayable JSONScalar values. */
    private func scalarMap(_ data: [String: Any]) -> [String: JSONScalar] {
        data.reduce(into: [:]) { result, item in
            result[item.key] = JSONScalar("\(item.value)")
        }
    }

    /** Interprets common string and numeric scalar values as booleans. */
    private func boolValue(_ value: JSONScalar?) -> Bool? {
        guard let raw = value?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if ["1", "true", "on", "yes"].contains(raw) { return true }
        if ["0", "false", "off", "no"].contains(raw) { return false }
        if let number = Double(raw) { return number != 0 }
        return nil
    }

    /** Records a successful remote data update for the given type. */
    private func markRemoteDataReceived(type: String) {
        receivedRemoteData[type] = Date()
        lastUpdated = Date()
        lastError = nil
    }

    /** Clears the success marker for a failed remote data type. */
    private func markRemoteDataFailed(type: String) {
        receivedRemoteData.removeValue(forKey: type)
    }

    /** Starts observing local network path and Wi-Fi address changes. */
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isLocalNetworkAvailable = path.status == .satisfied
                if path.usesInterfaceType(.wifi) {
                    self?.networkPath = "WiFi"
                } else if path.usesInterfaceType(.cellular) {
                    self?.networkPath = "Cellular"
                } else if path.status == .satisfied {
                    self?.networkPath = "Connected"
                } else {
                    self?.networkPath = "Offline"
                }
                self?.wifiIPAddress = NetworkInspector.localWiFiIPv4Address() ?? ""
                self?.wifiNetworkPrefix = NetworkInspector.privateNetworkPrefix(for: self?.wifiIPAddress ?? "") ?? ""
                self?.updateServiceURLNetworkValidation()
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    /** Recomputes whether the service URL belongs to the current Wi-Fi network. */
    private func updateServiceURLNetworkValidation() {
        let hostAddress = NetworkInspector.ipv4HostAddress(from: serviceURL) ?? ""
        serviceHostIPAddress = hostAddress
        isServiceURLOnWiFiNetwork = networkPath == "WiFi"
            && NetworkInspector.sameIPv4Network(wifiIPAddress, hostAddress)
    }
}

/** Provides IPv4 network inspection helpers for validating local service reachability. */
enum NetworkInspector {
    /** Returns the local IPv4 address for the Wi-Fi interface when available. */
    static func localWiFiIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var interface = firstInterface
        while true {
            defer {
                if let next = interface.pointee.ifa_next {
                    interface = next
                }
            }

            guard let addressPointer = interface.pointee.ifa_addr else {
                guard interface.pointee.ifa_next != nil else {
                    return nil
                }
                continue
            }

            let name = String(cString: interface.pointee.ifa_name)
            let address = addressPointer.pointee
            if name == "en0", address.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addressPointer,
                    socklen_t(address.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    return String(cString: host)
                }
            }

            guard interface.pointee.ifa_next != nil else {
                return nil
            }
        }
    }

    /** Extracts an IPv4 host address from a service URL string. */
    static func ipv4HostAddress(from serviceURL: String) -> String? {
        guard
            let url = URL(string: serviceURL),
            let host = url.host(percentEncoded: false),
            ipv4Octets(host) != nil
        else { return nil }
        return host
    }

    /** Returns whether two IPv4 addresses share the same /24 prefix. */
    static func sameIPv4Network(_ lhs: String, _ rhs: String) -> Bool {
        guard
            let lhsOctets = ipv4Octets(lhs),
            let rhsOctets = ipv4Octets(rhs)
        else { return false }
        return lhsOctets.prefix(3).elementsEqual(rhsOctets.prefix(3))
    }

    /** Returns the private network prefix that contains the IPv4 address. */
    static func privateNetworkPrefix(for address: String) -> String? {
        guard let octets = ipv4Octets(address) else { return nil }
        switch octets[0] {
        case 10:
            return "10.0.0.0/8"
        case 172:
            return "\(octets[0]).\(octets[1]).0.0/16"
        case 192:
            return "\(octets[0]).\(octets[1]).\(octets[2]).0/24"
        default:
            return nil
        }
    }

    /** Parses an IPv4 address into four validated octets. */
    private static func ipv4Octets(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return octets
    }
}

/** Adds CarIOS-specific behavior to AppStore. */
extension AppStore: CarIOSBLEClientDelegate {
    /** Receives BLE state changes and mirrors them onto main-actor app state. */
    nonisolated func bleClientDidUpdate(state: String) {
        Task { @MainActor in
            self.bleState = state
            self.isBleConnected = state == "Connected"
        }
    }

    /** Receives a BLE-discovered service URL and stores it. */
    nonisolated func bleClientDidReceive(serviceURL: String) {
        Task { @MainActor in
            self.setServiceURL(serviceURL)
        }
    }

    /** Handles a ready BLE connection and sends the APNs token. */
    nonisolated func bleClientDidBecomeReady() {
        Task { @MainActor in
            self.bleState = "Connected"
            self.isBleConnected = true
            self.sendDeviceTokenOverBle()
        }
    }

    /** Receives BLE errors and exposes them through app state. */
    nonisolated func bleClientDidFail(error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
        }
    }
}

/** Defines network maintenance commands supported by the CarIOS service. */
enum NetworkCommand: Int, CaseIterable, Identifiable {
    /** Represents the soft reset gsm option. */
    case softResetGsm = 1
    /** Represents the hard reset gsm option. */
    case hardResetGsm = 2
    /** Represents the reset network option. */
    case resetNetwork = 3
    /** Represents the reboot system option. */
    case rebootSystem = 4

    /** Stable identifier used by SwiftUI collections and persisted models. */
    var id: Int { rawValue }
    /** User-facing title shown for this item. */
    var title: String {
        switch self {
        case .softResetGsm: "GSM Soft Reset"
        case .hardResetGsm: "GSM Hard Reset"
        case .resetNetwork: "Network Reset"
        case .rebootSystem: "Reboot CarIOS"
        }
    }
}

/** Defines service and trace commands supported by the CarIOS backend. */
enum ServiceCommand: String, CaseIterable, Identifiable {
    /** Represents the gsm message option. */
    case gsmMessage = "1"
    /** Represents the push message option. */
    case pushMessage = "2"
    /** Represents the mobile trace option. */
    case mobileTrace = "3"
    /** Represents the solar trace option. */
    case solarTrace = "4"
    /** Represents the ve direct trace option. */
    case veDirectTrace = "5"
    /** Represents the cerbo trace option. */
    case cerboTrace = "6"
    /** Represents the bluetooth trace option. */
    case bluetoothTrace = "7"
    /** Represents the service trace option. */
    case serviceTrace = "8"

    /** Stable identifier used by SwiftUI collections and persisted models. */
    var id: String { rawValue }

    /** Whether this service command is represented as a persistent toggle in the UI. */
    var isToggle: Bool {
        switch self {
        case .gsmMessage, .pushMessage: false
        case .mobileTrace, .solarTrace, .veDirectTrace, .cerboTrace, .bluetoothTrace, .serviceTrace: true
        }
    }

    /** User-facing title shown for this item. */
    var title: String {
        switch self {
        case .gsmMessage: "Send GSM Test"
        case .pushMessage: "Send Push Test"
        case .mobileTrace: "Toggle Mobile Trace"
        case .solarTrace: "Toggle Solar Trace"
        case .veDirectTrace: "Toggle VE.Direct Trace"
        case .cerboTrace: "Toggle Cerbo Trace"
        case .bluetoothTrace: "Toggle Bluetooth Trace"
        case .serviceTrace: "Toggle Service Trace"
        }
    }
}

/** Describes service communication errors surfaced by the app. */
enum CarIOSError: LocalizedError {
    /** Represents the invalid url option. */
    case invalidURL
    /** Represents the invalid response option. */
    case invalidResponse(String)
    /** Represents the http option. */
    case http(Int)

    /** Localized message for the CarIOS communication error. */
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid web-service URL"
        case .invalidResponse(let message): message
        case .http(let code): "HTTP error \(code)"
        }
    }
}

/** Returns the token value sent to services, substituting a sandbox token in debug builds. */
func deviceToken(_ token: String) -> String {
    var _token = token
    #if DEBUG
    _token = "<sandbox>"
    #endif
    return _token
}

/** Performs legacy CarIOS HTTP JSON calls. */
final class CarIOSHTTPClient {
    /** Stores the session value. */
    private let session: URLSession

    /** Creates a new instance with the supplied values. */
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 5 * 60
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config)
    }

    /** Posts a legacy JSON request to the CarIOS service and returns the response object. */
    func call(serviceURL: String, token: String, payload: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: serviceURL) else { throw CarIOSError.invalidURL }
        let bodyString = try Self.legacyJSONString(payload)
        guard let body = bodyString.data(using: .nonLossyASCII) else {
            throw CarIOSError.invalidResponse("Unable to encode request body")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Token token=\"\(deviceToken(token))\"", forHTTPHeaderField: "Authorization")
        request.setValue("application/json charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(bodyString.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("CarIOSApp/1", forHTTPHeaderField: "User-Agent")
        request.setValue("1.00", forHTTPHeaderField: "X-CarIOSApp")
        request.networkServiceType = .callSignaling
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = true

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CarIOSError.invalidResponse("No HTTP response")
        }
        guard http.statusCode == 200 else {
            throw CarIOSError.http(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CarIOSError.invalidResponse("Response is not a JSON object")
        }
        return object
    }

    /** Builds the legacy JSON request format expected by the CarIOS service. */
    private static func legacyJSONString(_ payload: [String: Any]) throws -> String {
        if let operation = payload["o"] as? String, let version = payload["v"] as? String {
            return "{\"v\": \"\(version)\", \"o\": \"\(operation)\"}"
        }
        if let type = payload["x"] as? String, let version = payload["v"] as? String, let action = payload["a"] {
            let actionData = try JSONSerialization.data(withJSONObject: action, options: [])
            let actionString = String(data: actionData, encoding: .utf8) ?? "{}"
            return "{\"v\": \"\(version)\", \"x\": \"\(type)\", \"a\": \(actionString)}"
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/** Receives BLE state, service URL, readiness, and error callbacks. */
protocol CarIOSBLEClientDelegate: AnyObject {
    /** Receives BLE state changes and mirrors them onto main-actor app state. */
    func bleClientDidUpdate(state: String)
    /** Receives a BLE-discovered service URL and stores it. */
    func bleClientDidReceive(serviceURL: String)
    /** Handles a ready BLE connection and sends the APNs token. */
    func bleClientDidBecomeReady()
    /** Receives BLE errors and exposes them through app state. */
    func bleClientDidFail(error: Error)
}

/** Discovers the CarIOS BLE service and exchanges framed configuration data. */
final class CarIOSBLEClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /** Stores the service uuid value. */
    private static let serviceUUID = CBUUID(string: "0000FEED-0000-1000-8000-00805F9B34FB")
    /** Stores the command uuid value. */
    private static let commandUUID = CBUUID(string: "0000BEEF-0000-1000-8000-00805F9B34FB")
    /** Stores the server out uuid value. */
    private static let serverOutUUID = CBUUID(string: "0000DEAD-0000-1000-8000-00805F9B34FB")
    /** Stores the server in uuid value. */
    private static let serverInUUID = CBUUID(string: "0000C0DE-0000-1000-8000-00805F9B34FB")

    /** Stores the delegate value. */
    private weak var delegate: CarIOSBLEClientDelegate?
    /** Stores the central value. */
    private var central: CBCentralManager?
    /** Stores the peripheral value. */
    private var peripheral: CBPeripheral?
    /** Stores the command characteristic value. */
    private var commandCharacteristic: CBCharacteristic?
    /** Stores the server input characteristic value. */
    private var serverInputCharacteristic: CBCharacteristic?
    /** Stores the receive buffer value. */
    private var receiveBuffer = Data()
    /** Stores the is receiving value. */
    private var isReceiving = false
    /** Stores the queue value. */
    private let queue = DispatchQueue(label: "carios.ble")

    /** Creates a new instance with the supplied values. */
    init(delegate: CarIOSBLEClientDelegate) {
        self.delegate = delegate
        super.init()
    }

    /** Starts BLE scanning or resumes scanning when Bluetooth is already powered on. */
    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue)
        } else if central?.state == .poweredOn {
            scan()
        }
    }

    /** Stops BLE scanning, disconnects the peripheral, and reports stopped state. */
    func stop() {
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        delegate?.bleClientDidUpdate(state: "Stopped")
    }

    /** Sends the APNs token over the BLE framed transport. */
    func sendToken(_ token: String) {
        let _token = deviceToken(token)
        guard let data = _token.data(using: .ascii) else {
            return
        }
        writeCommand(0xf0be)
        writeFramed(data)
    }

    /** Responds to Bluetooth state changes and starts scanning when possible. */
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            delegate?.bleClientDidUpdate(state: "Scanning")
            scan()
        case .poweredOff:
            delegate?.bleClientDidUpdate(state: "Bluetooth Off")
        case .unauthorized:
            delegate?.bleClientDidUpdate(state: "Bluetooth Unauthorized")
        default:
            delegate?.bleClientDidUpdate(state: "Bluetooth \(central.state.rawValue)")
        }
    }

    /** Handles CoreBluetooth central-manager events. */
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard services.contains(Self.serviceUUID) || peripheral.name?.isEmpty == false else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        delegate?.bleClientDidUpdate(state: "Connecting")
    }

    /** Handles CoreBluetooth central-manager events. */
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        delegate?.bleClientDidUpdate(state: "Discovering")
        peripheral.discoverServices([Self.serviceUUID])
    }

    /** Handles CoreBluetooth central-manager events. */
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        delegate?.bleClientDidUpdate(state: "Disconnected")
        if let error {
            delegate?.bleClientDidFail(error: error)
        }
        scan()
    }

    /** Handles CoreBluetooth central-manager events. */
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        delegate?.bleClientDidUpdate(state: "Connection Failed")
        if let error {
            delegate?.bleClientDidFail(error: error)
        }
        scan()
    }

    /** Handles CoreBluetooth peripheral events. */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            delegate?.bleClientDidFail(error: error)
            return
        }
        peripheral.services?
            .filter { $0.uuid == Self.serviceUUID }
            .forEach {
                peripheral.discoverCharacteristics([Self.commandUUID, Self.serverOutUUID, Self.serverInUUID], for: $0)
            }
    }

    /** Handles CoreBluetooth peripheral events. */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            delegate?.bleClientDidFail(error: error)
            return
        }
        service.characteristics?.forEach { characteristic in
            switch characteristic.uuid {
            case Self.commandUUID:
                commandCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            case Self.serverOutUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.serverInUUID:
                serverInputCharacteristic = characteristic
            default:
                break
            }
        }
        if commandCharacteristic != nil && serverInputCharacteristic != nil {
            delegate?.bleClientDidBecomeReady()
        }
    }

    /** Handles CoreBluetooth peripheral events. */
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            delegate?.bleClientDidFail(error: error)
            return
        }

        guard characteristic.uuid == Self.serverOutUUID, let value = characteristic.value else {
            return
        }

        handleFrame(value)
    }

    /** Starts scanning for the CarIOS BLE service. */
    private func scan() {
        guard central?.state == .poweredOn else {
            return
        }

        central?.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /** Writes a command word to the BLE command characteristic. */
    private func writeCommand(_ command: UInt64) {
        guard let peripheral, let commandCharacteristic else { return }
        var bigEndian = command.bigEndian
        let data = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        peripheral.writeValue(data, for: commandCharacteristic, type: .withResponse)
    }

    /** Writes data as an STX/ETX-framed BLE payload. */
    private func writeFramed(_ data: Data) {
        guard let peripheral, let serverInputCharacteristic, !data.isEmpty else { return }
        peripheral.writeValue(Data([0x02]), for: serverInputCharacteristic, type: .withResponse)
        for start in stride(from: 0, to: data.count, by: 20) {
            peripheral.writeValue(data.subdata(in: start..<min(start + 20, data.count)), for: serverInputCharacteristic, type: .withResponse)
        }
        peripheral.writeValue(Data([0x03]), for: serverInputCharacteristic, type: .withResponse)
    }

    /** Accumulates incoming BLE frame bytes and dispatches complete frames. */
    private func handleFrame(_ data: Data) {
        for byte in data {
            if byte == 0x02 {
                receiveBuffer.removeAll()
                isReceiving = true
            } else if byte == 0x03 {
                if isReceiving {
                    processFrame(receiveBuffer)
                }
                isReceiving = false
            } else if isReceiving {
                receiveBuffer.append(byte)
            }
        }
    }

    /** Parses a BLE frame and forwards discovered service URLs. */
    private func processFrame(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let url = object["url"] as? String,
            !url.isEmpty
        else { return }
        delegate?.bleClientDidReceive(serviceURL: url)
    }
}

/** Persists received messages in UserDefaults. */
final class MessageHistoryStore {
    /** Stores the encoder value. */
    private let encoder = JSONEncoder()
    /** Stores the decoder value. */
    private let decoder = JSONDecoder()

    /** Loads all persisted messages from UserDefaults. */
    func load() -> [PushMessage] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(AppStorageKeys.messagePrefix) }
            .compactMap { key -> PushMessage? in
                guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
                return try? decoder.decode(PushMessage.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    /** Persists a message in UserDefaults. */
    func save(_ message: PushMessage) {
        guard let data = try? encoder.encode(message) else { return }
        UserDefaults.standard.set(data, forKey: AppStorageKeys.messagePrefix + message.id)
    }

    /** Removes a single persisted message from UserDefaults. */
    func remove(_ message: PushMessage) {
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.messagePrefix + message.id)
    }

    /** Removes all persisted messages from UserDefaults. */
    func removeAll() {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(AppStorageKeys.messagePrefix) }
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}
