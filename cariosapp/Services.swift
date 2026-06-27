import Combine
import CoreBluetooth
import Darwin
import Foundation
import Network
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    @Published var serviceURL: String = UserDefaults.standard.string(forKey: AppStorageKeys.serviceURL) ?? ""
    @Published var bleScanEnabled: Bool = UserDefaults.standard.object(forKey: AppStorageKeys.bleScanEnabled) as? Bool ?? true
    @Published var deviceToken: String = UserDefaults.standard.string(forKey: AppStorageKeys.deviceToken) ?? ""
    @Published var notificationAuthorization: String = "Unknown"
    @Published var isLocalNetworkAvailable = false
    @Published var networkPath = "Unknown"
    @Published var wifiIPAddress = ""
    @Published var wifiNetworkPrefix = ""
    @Published var serviceHostIPAddress = ""
    @Published var isServiceURLOnWiFiNetwork = false
    @Published var bleState = "Idle"
    @Published var isBleConnected = false
    @Published var lastUpdated: Date?
    @Published var lastError: String?
    @Published var power = PowerInfo()
    @Published var charger = ChargerInfo()
    @Published var network = NetworkInfo()
    @Published var relays = RelayInfo()
    @Published var mobile = MobileInfo()
    @Published var messages: [PushMessage] = []
    @Published var requestedTab: AppTab?
    @Published var commandToggleStates: [ServiceCommand: Bool] = [:]
    @Published private var pendingRelayStates: [Int: Bool] = [:]
    @Published private var pendingChargerRelayStates: [Int: Bool] = [:]
    @Published private var receivedRemoteData: [String: Date] = [:]

    private let client = CarIOSHTTPClient()
    private let history = MessageHistoryStore()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "carios.netmon")
    private lazy var bleClient = CarIOSBLEClient(delegate: self)
    private var pollingTask: Task<Void, Never>?
    private var activePollType: String = "p"
    private var isStarted = false

    var hasServiceURL: Bool {
        URL(string: serviceURL) != nil
    }

    var canCommunicateWithServer: Bool {
        hasServiceURL && isLocalNetworkAvailable && isServiceURLOnWiFiNetwork && !deviceToken.isEmpty
    }

    func hasReceivedRemoteData(for type: String?) -> Bool {
        guard let type else { return true }
        return receivedRemoteData[type] != nil
    }

    var unreadMessageCount: Int {
        messages.filter { !$0.isRead }.count
    }

    func isRelayPending(index: Int) -> Bool {
        pendingRelayStates[index] != nil
    }

    func isChargerRelayPending(mode: Int) -> Bool {
        pendingChargerRelayStates[mode] != nil
    }

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

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            await self?.refreshActiveTab()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.refreshActiveTab()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func enterForeground() {
        startPolling()
        if bleScanEnabled {
            bleClient.start()
        }
    }

    func enterBackground() {
        stopPolling()
    }

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

    func refreshAll() async {
        guard canCommunicateWithServer else { return }
        await loadPower()
        await loadCharger()
        await loadNetwork()
        await loadRelays()
        await loadMobile()
    }

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

    func setServiceURL(_ url: String) {
        guard serviceURL != url else { return }
        serviceURL = url
        UserDefaults.standard.set(url, forKey: AppStorageKeys.serviceURL)
        receivedRemoteData.removeAll()
        updateServiceURLNetworkValidation()
        sendDeviceTokenOverBle()
    }

    func setBleScanEnabled(_ enabled: Bool) {
        bleScanEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppStorageKeys.bleScanEnabled)
        if enabled {
            bleClient.start()
        } else {
            bleClient.stop()
        }
    }

    func setRelay(index: Int, state: Bool) {
        pendingRelayStates[index] = state
        relays.states[index] = state
        Task {
            await sendAction(type: "r", action: ["i": index, "s": state])
            await loadRelays()
        }
    }

    func setChargerRelay(mode: Int, state: Bool) {
        pendingChargerRelayStates[mode] = state
        charger.values["sys.r\(mode)"] = JSONScalar(state ? "1" : "0")
        Task {
            await sendAction(type: "c", action: ["m": mode])
            await loadCharger()
        }
    }

    func networkCommand(_ command: NetworkCommand) {
        Task {
            await sendAction(type: "n", action: ["t": command.rawValue])
        }
    }

    func command(_ command: ServiceCommand) {
        Task {
            await sendAction(type: "s", action: ["t": "c", "c": command.rawValue, "d": "255"])
        }
    }

    func setCommandToggle(_ serviceCommand: ServiceCommand, enabled: Bool) {
        commandToggleStates[serviceCommand] = enabled
        command(serviceCommand)
    }

    func registerDeviceTokenWithServer() {
        guard canCommunicateWithServer else { return }
        Task {
            let _token = cariosapp.deviceToken(deviceToken)
            await sendAction(type: "s", action: ["t": "m", "c": "s", "d": _token])
        }
    }

    func sendDeviceTokenOverBle() {
        guard !deviceToken.isEmpty else { return }
        bleClient.sendToken(deviceToken)
    }

    func addMessage(from content: UNNotificationContent, id: String, state: MessageState, actionId: String) {
        let message = PushMessage(id: id, content: content, state: state, actionId: actionId)
        addMessage(message)
    }

    func addMessage(from userInfo: [AnyHashable: Any], state: MessageState, actionId: String) {
        let message = PushMessage(id: UUID().uuidString, userInfo: userInfo, state: state, actionId: actionId)
        addMessage(message)
    }

    func addMessage(_ message: PushMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.insert(message, at: 0)
        }
        history.save(message)
        updateApplicationBadge()
    }

    func markMessageRead(_ message: PushMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isRead = true
        history.save(messages[index])
        updateApplicationBadge()
    }

    func deleteMessage(_ message: PushMessage) {
        messages.removeAll { $0.id == message.id }
        history.remove(message)
        updateApplicationBadge()
    }

    func clearMessages() {
        messages.removeAll()
        history.removeAll()
        updateApplicationBadge()
    }

    func openMessages() {
        requestedTab = .messages
    }

    func finishOpenMessagesRequest() {
        requestedTab = nil
    }

    private func updateApplicationBadge() {
        UNUserNotificationCenter.current().setBadgeCount(unreadMessageCount)
    }

    private func requestObject(type: String) async throws -> [String: Any] {
        let response = try await client.call(serviceURL: serviceURL, token: deviceToken, payload: ["v": "0787", "o": type])
        guard let result = response[type] as? [String: Any] else {
            throw CarIOSError.invalidResponse("Missing object '\(type)'")
        }
        return result
    }

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

    private func scalarMap(_ data: [String: Any]) -> [String: JSONScalar] {
        data.reduce(into: [:]) { result, item in
            result[item.key] = JSONScalar("\(item.value)")
        }
    }

    private func boolValue(_ value: JSONScalar?) -> Bool? {
        guard let raw = value?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if ["1", "true", "on", "yes"].contains(raw) { return true }
        if ["0", "false", "off", "no"].contains(raw) { return false }
        if let number = Double(raw) { return number != 0 }
        return nil
    }

    private func markRemoteDataReceived(type: String) {
        receivedRemoteData[type] = Date()
        lastUpdated = Date()
        lastError = nil
    }

    private func markRemoteDataFailed(type: String) {
        receivedRemoteData.removeValue(forKey: type)
    }

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

    private func updateServiceURLNetworkValidation() {
        let hostAddress = NetworkInspector.ipv4HostAddress(from: serviceURL) ?? ""
        serviceHostIPAddress = hostAddress
        isServiceURLOnWiFiNetwork = networkPath == "WiFi"
            && NetworkInspector.sameIPv4Network(wifiIPAddress, hostAddress)
    }
}

enum NetworkInspector {
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

    static func ipv4HostAddress(from serviceURL: String) -> String? {
        guard
            let url = URL(string: serviceURL),
            let host = url.host(percentEncoded: false),
            ipv4Octets(host) != nil
        else { return nil }
        return host
    }

    static func sameIPv4Network(_ lhs: String, _ rhs: String) -> Bool {
        guard
            let lhsOctets = ipv4Octets(lhs),
            let rhsOctets = ipv4Octets(rhs)
        else { return false }
        return lhsOctets.prefix(3).elementsEqual(rhsOctets.prefix(3))
    }

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

extension AppStore: CarIOSBLEClientDelegate {
    nonisolated func bleClientDidUpdate(state: String) {
        Task { @MainActor in
            self.bleState = state
            self.isBleConnected = state == "Connected"
        }
    }

    nonisolated func bleClientDidReceive(serviceURL: String) {
        Task { @MainActor in
            self.setServiceURL(serviceURL)
        }
    }

    nonisolated func bleClientDidBecomeReady() {
        Task { @MainActor in
            self.bleState = "Connected"
            self.isBleConnected = true
            self.sendDeviceTokenOverBle()
        }
    }

    nonisolated func bleClientDidFail(error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
        }
    }
}

enum NetworkCommand: Int, CaseIterable, Identifiable {
    case softResetGsm = 1
    case hardResetGsm = 2
    case resetNetwork = 3
    case rebootSystem = 4

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .softResetGsm: "GSM Soft Reset"
        case .hardResetGsm: "GSM Hard Reset"
        case .resetNetwork: "Network Reset"
        case .rebootSystem: "Reboot CarIOS"
        }
    }
}

enum ServiceCommand: String, CaseIterable, Identifiable {
    case gsmMessage = "1"
    case pushMessage = "2"
    case mobileTrace = "3"
    case solarTrace = "4"
    case veDirectTrace = "5"
    case cerboTrace = "6"
    case bluetoothTrace = "7"
    case serviceTrace = "8"

    var id: String { rawValue }

    var isToggle: Bool {
        switch self {
        case .gsmMessage, .pushMessage: false
        case .mobileTrace, .solarTrace, .veDirectTrace, .cerboTrace, .bluetoothTrace, .serviceTrace: true
        }
    }

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

enum CarIOSError: LocalizedError {
    case invalidURL
    case invalidResponse(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid web-service URL"
        case .invalidResponse(let message): message
        case .http(let code): "HTTP error \(code)"
        }
    }
}

func deviceToken(_ token: String) -> String {
    var _token = token
    #if DEBUG
    _token = "<sandbox>"
    #endif
    return _token
}

final class CarIOSHTTPClient {
    private let session: URLSession

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

protocol CarIOSBLEClientDelegate: AnyObject {
    func bleClientDidUpdate(state: String)
    func bleClientDidReceive(serviceURL: String)
    func bleClientDidBecomeReady()
    func bleClientDidFail(error: Error)
}

final class CarIOSBLEClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceUUID = CBUUID(string: "0000FEED-0000-1000-8000-00805F9B34FB")
    private static let commandUUID = CBUUID(string: "0000BEEF-0000-1000-8000-00805F9B34FB")
    private static let serverOutUUID = CBUUID(string: "0000DEAD-0000-1000-8000-00805F9B34FB")
    private static let serverInUUID = CBUUID(string: "0000C0DE-0000-1000-8000-00805F9B34FB")

    private weak var delegate: CarIOSBLEClientDelegate?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var serverInputCharacteristic: CBCharacteristic?
    private var receiveBuffer = Data()
    private var isReceiving = false
    private let queue = DispatchQueue(label: "carios.ble")

    init(delegate: CarIOSBLEClientDelegate) {
        self.delegate = delegate
        super.init()
    }

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue)
        } else if central?.state == .poweredOn {
            scan()
        }
    }

    func stop() {
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        delegate?.bleClientDidUpdate(state: "Stopped")
    }

    func sendToken(_ token: String) {
        let _token = deviceToken(token)
        guard let data = _token.data(using: .ascii) else {
            return
        }
        writeCommand(0xf0be)
        writeFramed(data)
    }

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

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        delegate?.bleClientDidUpdate(state: "Discovering")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        delegate?.bleClientDidUpdate(state: "Disconnected")
        if let error {
            delegate?.bleClientDidFail(error: error)
        }
        scan()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        delegate?.bleClientDidUpdate(state: "Connection Failed")
        if let error {
            delegate?.bleClientDidFail(error: error)
        }
        scan()
    }

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

    private func scan() {
        guard central?.state == .poweredOn else {
            return
        }

        central?.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func writeCommand(_ command: UInt64) {
        guard let peripheral, let commandCharacteristic else { return }
        var bigEndian = command.bigEndian
        let data = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        peripheral.writeValue(data, for: commandCharacteristic, type: .withResponse)
    }

    private func writeFramed(_ data: Data) {
        guard let peripheral, let serverInputCharacteristic, !data.isEmpty else { return }
        peripheral.writeValue(Data([0x02]), for: serverInputCharacteristic, type: .withResponse)
        for start in stride(from: 0, to: data.count, by: 20) {
            peripheral.writeValue(data.subdata(in: start..<min(start + 20, data.count)), for: serverInputCharacteristic, type: .withResponse)
        }
        peripheral.writeValue(Data([0x03]), for: serverInputCharacteristic, type: .withResponse)
    }

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

    private func processFrame(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let url = object["url"] as? String,
            !url.isEmpty
        else { return }
        delegate?.bleClientDidReceive(serviceURL: url)
    }
}

final class MessageHistoryStore {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() -> [PushMessage] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(AppStorageKeys.messagePrefix) }
            .compactMap { key -> PushMessage? in
                guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
                return try? decoder.decode(PushMessage.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    func save(_ message: PushMessage) {
        guard let data = try? encoder.encode(message) else { return }
        UserDefaults.standard.set(data, forKey: AppStorageKeys.messagePrefix + message.id)
    }

    func remove(_ message: PushMessage) {
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.messagePrefix + message.id)
    }

    func removeAll() {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(AppStorageKeys.messagePrefix) }
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}
