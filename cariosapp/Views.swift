import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case power
    case charger
    case network
    case relays
    case mobile
    case messages
    case commands
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .power: "Overview"
        case .charger: "Charger"
        case .network: "Network"
        case .relays: "Relays"
        case .mobile: "Mobile"
        case .messages: "Messages"
        case .commands: "Commands"
        case .settings: "Settings"
        }
    }

    var pollType: String? {
        switch self {
        case .power: "p"
        case .charger: "c"
        case .network: "n"
        case .relays: "r"
        case .mobile: "m"
        case .messages, .commands, .settings: nil
        }
    }

    var icon: String {
        switch self {
        case .power: "bolt.fill"
        case .charger: "sun.max.fill"
        case .network: "network"
        case .relays: "switch.2"
        case .mobile: "antenna.radiowaves.left.and.right"
        case .messages: "bell.fill"
        case .commands: "terminal.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: AppTab = .power
    @State private var messagePath: [PushMessage] = []
    @State private var messageDeleteConfirmation: MessageDeleteConfirmation?

    var body: some View {
        GeometryReader { proxy in
            let useSplitNavigation = horizontalSizeClass == .regular && proxy.size.width > proxy.size.height

            Group {
                if useSplitNavigation {
                    splitNavigation
                } else {
                    tabNavigation
                }
            }
        }
        .onAppear { store.setActivePollType(selectedTab.pollType) }
        .onChange(of: selectedTab) { _, tab in
            store.setActivePollType(tab.pollType)
        }
        .onChange(of: store.requestedTab) { _, tab in
            guard let tab else { return }
            selectedTab = tab
            store.finishOpenMessagesRequest()
        }
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            List {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedTab == tab ? .blue : .primary)
                    .listRowBackground(selectedTab == tab ? Color.blue.opacity(0.12) : Color.clear)
                }
            }
            .navigationTitle("CarIOS")
        } detail: {
            if selectedTab == .messages {
                messagesNavigation
            } else {
                NavigationStack {
                    selectedTab.content
                        .navigationTitle(selectedTab.title)
                }
            }
        }
    }

    private var tabNavigation: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                tabNavigationStack(for: tab)
                .tabItem {
                    Label(tab.title, systemImage: tab.icon)
                }
                .badge(tab == .messages ? store.unreadMessageCount : 0)
                .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func tabNavigationStack(for tab: AppTab) -> some View {
        if tab == .messages {
            messagesNavigation
        } else {
            NavigationStack {
                tab.content
                    .navigationTitle(tab.title)
            }
        }
    }

    private var messagesNavigation: some View {
        NavigationStack(path: $messagePath) {
            MessageHistoryView(onDeleteRequest: requestMessageDeletion)
                .navigationTitle(AppTab.messages.title)
                .navigationDestination(for: PushMessage.self) { message in
                    MessageDetailView(message: message)
                        .onAppear { store.markMessageRead(message) }
                }
        }
        .toolbar {
            messageToolbarItems
        }
        .alert("Delete Messages?", isPresented: messageDeleteConfirmationBinding, presenting: messageDeleteConfirmation) { confirmation in
            Button("Delete", role: .destructive) {
                deleteMessages(confirmation)
            }
            Button("Cancel", role: .cancel) {
                messageDeleteConfirmation = nil
            }
        } message: { confirmation in
            switch confirmation {
            case .all:
                Text("All messages will be deleted.")
            case .message:
                Text("This message will be deleted.")
            }
        }
    }

    @ToolbarContentBuilder
    private var messageToolbarItems: some ToolbarContent {
        if let message = messagePath.last {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    requestMessageDeletion(.message(message))
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly).padding(.leading, 4)
                }
                Button {
                    closeMessageDetail()
                } label: {
                    Label("Done", systemImage: "xmark")
                        .labelStyle(.iconOnly).padding(.trailing, 4)
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    requestMessageDeletion(.all)
                } label: {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.iconOnly).padding(.horizontal, 8)
                }
                .disabled(store.messages.isEmpty)
            }
        }
    }

    private var messageDeleteConfirmationBinding: Binding<Bool> {
        Binding {
            messageDeleteConfirmation != nil
        } set: { isPresented in
            if !isPresented {
                messageDeleteConfirmation = nil
            }
        }
    }

    private func requestMessageDeletion(_ confirmation: MessageDeleteConfirmation) {
        messageDeleteConfirmation = confirmation
    }

    private func deleteMessages(_ confirmation: MessageDeleteConfirmation) {
        switch confirmation {
        case .all:
            store.clearMessages()
            messagePath.removeAll()
        case .message(let message):
            store.deleteMessage(message)
            messagePath.removeAll { $0.id == message.id }
        }
        messageDeleteConfirmation = nil
    }

    private func closeMessageDetail() {
        guard !messagePath.isEmpty else { return }
        messagePath.removeLast()
    }
}

extension AppTab {
    @ViewBuilder
    var content: some View {
        switch self {
        case .power: PowerView()
        case .charger: ChargerView()
        case .network: NetworkView()
        case .relays: RelayView()
        case .mobile: MobileView()
        case .messages: MessageHistoryView(onDeleteRequest: { _ in })
        case .commands: CommandView()
        case .settings: SettingsView()
        }
    }
}

struct PowerView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("Voltages") {
                GaugeRow(title: "Main Battery", value: store.power.mainBattery, unit: "V", systemImage: "battery.100", maximum: 15)
                GaugeRow(title: "Board Battery", value: store.power.boardBattery, unit: "V", systemImage: "cpu", maximum: 15)
                GaugeRow(title: "Solar Panels", value: store.power.solarPanels, unit: "V", systemImage: "sun.max", maximum: 24)
                GaugeRow(title: "Engine Key", value: store.power.engineKey, unit: "V", systemImage: "key", maximum: 15)
            }
        }
        .refreshable { await store.refreshAll() }
        .serverConnectionOverlay(remoteDataType: "p")
    }
}

struct ChargerView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("System") {
                ChargerRelayToggle(
                    title: "AC/DC Charger",
                    value: store.charger.values["sys.r1"]
                ) { state in
                    store.setChargerRelay(mode: 1, state: state)
                }
                ChargerRelayToggle(
                    title: "DC/DC B2B Charger",
                    value: store.charger.values["sys.r2"]
                ) { state in
                    store.setChargerRelay(mode: 2, state: state)
                }
            }
            Section("Battery") {
                GaugeRow(title: "Voltage", value: double("sys.bat.v"), unit: "V", systemImage: "bolt.fill", maximum: 15)
                GaugeRow(title: "Current", value: double("sys.bat.i"), unit: "A", systemImage: "gauge", maximum: 30)
                GaugeRow(title: "Power", value: double("sys.bat.p"), unit: "W", systemImage: "bolt.circle.fill", maximum: 1500)
                GaugeRow(title: "Charge", value: double("sys.cp"), unit: "W", systemImage: "bolt.circle.fill", maximum: 1500)
            }
            Section("Solar") {
                GaugeRow(title: "Voltage", value: double("sol.v"), unit: "V", systemImage: "bolt.fill", maximum: 24)
                GaugeRow(title: "Current", value: double("sol.i"), unit: "A", systemImage: "gauge", maximum: 30)
                GaugeRow(title: "Power", value: double("sol.p"), unit: "W", systemImage: "bolt.circle.fill", maximum: 1500)
            }
            Section("BMS") {
                GaugeRow(title: "Voltage", value: double("bms.v"), unit: "V", systemImage: "bolt.fill", maximum: 15)
                GaugeRow(title: "Current", value: double("bms.i"), unit: "A", systemImage: "gauge", maximum: 30)
                GaugeRow(title: "Power", value: double("bms.p"), unit: "W", systemImage: "bolt.circle.fill", maximum: 1500)
                GaugeRow(title: "Capacity", value: double("bms.c"), unit: "%", systemImage: "bolt.circle.fill", maximum: 100)
            }
            Section("AC/DC Charger") {
                GaugeRow(title: "Voltage", value: double("acdc.v"), unit: "V", systemImage: "bolt.fill", maximum: 15)
                GaugeRow(title: "Current", value: double("acdc.i"), unit: "A", systemImage: "gauge", maximum: 30)
                MetricGrid(values: store.charger.values, keys: [
                    /*("acdc.v", "Voltage"),
                    ("acdc.i", "Current"),*/
                    ("acdc.t", "Temperature"),
                    ("acdc.s", "State"),
                    ("acdc.m", "Mode"),
                    ("acdc.ls", "Link State"),
                    ("acdc.cs", "Custom State"),
                    ("acdc.ec", "Error Code"),
                    ("acdc.rs", "Relay State"),
                    ("acdc.nm", "Network Mode")
                ])
            }
          }
        .refreshable { await store.loadCharger() }
        .serverConnectionOverlay(remoteDataType: "c")
    }

    private func double(_ key: String) -> Double? {
        guard let raw = store.charger.values[key]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Double(raw)
    }
}

struct NetworkView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let wifiWanAvailable = NetworkStatusRow.isAvailableWAN(store.network.wifiWanIp)
        let mobileWanAvailable = NetworkStatusRow.isAvailableWAN(store.network.gsmWanIp)
        let gatewayAvailable = [store.network.wifiWanIp, store.network.gsmWanIp]
            .contains { NetworkStatusRow.isAvailableWAN($0) && $0 == store.network.gatewayIp }

        List {
            //StatusSection()
            Section("CarIOS Network") {
                LabeledContent("LAN IP", value: store.network.lanIp)
                LabeledContent("WiFi AP IP", value: store.network.wifiApIp)
                NetworkStatusRow(title: "WiFi WAN", value: store.network.wifiWanIp, isAvailable: wifiWanAvailable)
                NetworkStatusRow(title: "Mobile WAN", value: store.network.gsmWanIp, isAvailable: mobileWanAvailable)
                NetworkStatusRow(title: "Gateway IP", value: store.network.gatewayIp, isAvailable: gatewayAvailable)
                LabeledContent("Service URL", value: store.network.serviceUrl)
            }
            Section("Actions") {
                ForEach(NetworkCommand.allCases) { command in
                    Button(command.title) { store.networkCommand(command) }
                }
            }
        }
        .refreshable { await store.loadNetwork() }
        .serverConnectionOverlay(remoteDataType: "n")
    }
}

struct RelayView: View {
    @EnvironmentObject private var store: AppStore
    private let names = ["Bed K1", "Trunk K2", "Relay 3", "Boden K4", "Radio K5", "Relay 6", "Front Spot K7", "Back Spot K8"]

    var body: some View {
        List {
            ForEach(Array(store.relays.states.enumerated()), id: \.offset) { index, state in
                HStack {
                    Image(systemName: state ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(state ? .green : .secondary)
                    Toggle(names[index], isOn: Binding(
                        get: { store.relays.states[index] },
                        set: { store.setRelay(index: index, state: $0) }
                    ))
                }
            }
        }
        .refreshable { await store.loadRelays() }
        .serverConnectionOverlay(remoteDataType: "r")
    }
}

struct MobileView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("Module") {
                MetricGrid(values: store.mobile.values, keys: [
                    ("manufacturer", "Manufacturer"),
                    ("modelId", "Model"),
                    ("hwVersion", "HW Version"),
                    ("fwVersion", "FW Version"),
                    ("serialNo", "Serial No."),
                    ("iccId", "ICC ID"),
                    ("phoneNumber", "Phone")
                ])
            }
            Section("Network") {
                MetricGrid(values: store.mobile.values, keys: [
                    ("netOperator", "Operator"),
                    ("networkName", "Network"),
                    ("serviceProvider", "Provider"),
                    ("netBandType", "Band"),
                    ("netRegName", "Registration"),
                    ("signalRssi", "RSSI"),
                    ("signalQoS", "QoS"),
                    ("adc1Value", "ADC 1"),
                    ("adc2Value", "ADC 2")
                ])
            }
        }
        .task {
            store.setActivePollType("m")
            await store.loadMobile()
        }
        .refreshable { await store.loadMobile() }
        .serverConnectionOverlay(remoteDataType: "m")
    }
}

struct MessageHistoryView: View {
    @EnvironmentObject private var store: AppStore
    let onDeleteRequest: (MessageDeleteConfirmation) -> Void

    var body: some View {
        List {
            if store.messages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "bell.slash")
            } else {
                ForEach(store.messages) { message in
                    NavigationLink(value: message) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(message.title.isEmpty ? "CarIOS Message" : message.title)
                                    .font(.headline)
                                if !message.isRead {
                                    Image(systemName: "circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .accessibilityLabel("Unread")
                                }
                            }
                            Text(message.body)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                            Text(message.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        deleteButton(for: message)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        deleteButton(for: message)
                    }
                }
            }
        }
    }

    private func deleteButton(for message: PushMessage) -> some View {
        Button(role: .destructive) {
            onDeleteRequest(.message(message))
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

enum MessageDeleteConfirmation: Identifiable {
    case all
    case message(PushMessage)

    var id: String {
        switch self {
        case .all: "all"
        case .message(let message): message.id
        }
    }
}

struct MessageDetailView: View {
    let message: PushMessage

    var body: some View {
        List {
            Section("Message") {
                LabeledContent("Title", value: message.title)
                LabeledContent("Subtitle", value: message.subtitle)
                Text(message.body)
            }
            Section("Metadata") {
                LabeledContent("Message ID", value: message.id)
                LabeledContent("CarIOS ID", value: message.cariosId)
                LabeledContent("Action", value: message.actionId)
                LabeledContent("Category", value: message.category)
                LabeledContent("Thread", value: message.threadId)
                LabeledContent("State", value: message.state.rawValue)
                LabeledContent("Badge", value: "\(message.badge)")
                LabeledContent("Date", value: message.date.formatted())
            }
            if !message.parameters.isEmpty {
                Section("Parameters") {
                    ForEach(message.parameters.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: message.parameters[key] ?? "")
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationLinkIndicatorVisibility(.hidden)
    }
}

struct CommandView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("Service Commands") {
                ForEach(ServiceCommand.allCases.filter { !$0.isToggle }) { command in
                    Button(command.title) { store.command(command) }
                }
            }
            Section("Network Commands") {
                ForEach(NetworkCommand.allCases) { command in
                    Button(command.title) { store.networkCommand(command) }
                }
            }
            Section("Server Traces") {
                ForEach(ServiceCommand.allCases.filter { $0.isToggle }) { command in
                    Toggle(command.title, isOn: Binding(
                        get: { store.commandToggleStates[command] ?? false },
                        set: { store.setCommandToggle(command, enabled: $0) }
                    ))
                }
            }
        }
        .serverConnectionOverlay()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draftURL = ""

    var body: some View {
        Form {
            Section("Web Service") {
                TextField("http://host:port/carios", text: $draftURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save URL") {
                    store.setServiceURL(draftURL)
                }
                Button("Register Push Token") {
                    store.registerDeviceTokenWithServer()
                }
                LabeledContent("Device Token", value: store.deviceToken.isEmpty ? "Not registered" : store.deviceToken)
            }
            Section("Bluetooth LE") {
                Toggle("Scan for CarIOS", isOn: Binding(
                    get: { store.bleScanEnabled },
                    set: { store.setBleScanEnabled($0) }
                ))
                LabeledContent("BLE State", value: store.bleState)
                Button("Send Token over BLE") {
                    store.sendDeviceTokenOverBle()
                }
            }
            Section("Diagnostics") {
                LabeledContent("Notifications", value: store.notificationAuthorization)
                LabeledContent("Network", value: store.networkPath)
                LabeledContent("iPhone WiFi Network", value: store.wifiNetworkPrefix.isEmpty ? "--" : store.wifiNetworkPrefix)
                LabeledContent("Service Host IP", value: store.serviceHostIPAddress.isEmpty ? "--" : store.serviceHostIPAddress)
                LabeledContent("Service Network", value: store.isServiceURLOnWiFiNetwork ? "Matched" : "Not matched")
                if !store.isServiceURLOnWiFiNetwork {
                    LabeledContent("WiFi IP Address", value: store.wifiIPAddress)
                }
                if let lastUpdated = store.lastUpdated {
                    LabeledContent("Last Update", value: lastUpdated.formatted(date: .omitted, time: .standard))
                }
                if let lastError = store.lastError {
                    Text(lastError).foregroundStyle(.red)
                }
            }
        }
        .onAppear { draftURL = store.serviceURL }
    }
}

private extension View {
    func serverConnectionOverlay(remoteDataType: String? = nil) -> some View {
        modifier(ServerConnectionOverlay(remoteDataType: remoteDataType))
    }
}

private struct ServerConnectionOverlay: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let remoteDataType: String?

    func body(content: Content) -> some View {
        let shouldBlock = !store.canCommunicateWithServer || !store.hasReceivedRemoteData(for: remoteDataType)

        ZStack {
            content
                .disabled(shouldBlock)

            if shouldBlock {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Connecting to CarIOS")
                        .font(.headline)
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(currentNetworkText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding()
            }
        }
    }

    private var statusText: String {
        if store.deviceToken.isEmpty {
            return "Waiting for push token and Bluetooth LE discovery"
        }
        if !store.hasServiceURL {
            return "Scanning Bluetooth LE for web-service URL"
        }
        if !store.isLocalNetworkAvailable {
            return "Waiting for local network"
        }
        if store.networkPath != "WiFi" {
            return "Waiting for WiFi connection"
        }
        if !store.isServiceURLOnWiFiNetwork {
            if store.wifiIPAddress.isEmpty {
                return "Waiting for iPhone WiFi IP address"
            }
            if store.serviceHostIPAddress.isEmpty {
                return "Waiting for IPv4 address in web-service URL"
            }
            guard var svcNet = NetworkInspector.ipv4HostAddress(from: store.serviceURL) else {
                return "Web-service URL not known."
            }
            svcNet = NetworkInspector.privateNetworkPrefix(for: svcNet) ?? "unknown"
            return "Your Smartphone must be in WiFi network \(svcNet)"
        }
        if !store.hasReceivedRemoteData(for: remoteDataType) {
            return "Waiting for data from CarIOS"
        }
        return "Waiting for server connection"
    }

    private var currentNetworkText: String {
        if store.networkPath == "WiFi", !store.wifiNetworkPrefix.isEmpty {
            return "Current network: \(store.wifiNetworkPrefix)"
        }
        return "Current network unknown."
    }
}

struct NetworkStatusRow: View {
    let title: String
    let value: String
    let isAvailable: Bool

    var body: some View {
        LabeledContent(title, value: value.isEmpty ? "--" : value)
            .listRowBackground(isAvailable ? Color.green.opacity(0.22) : Color.clear)
    }

    static func isAvailableWAN(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "0.0.0.0"
    }
}

struct ChargerRelayToggle: View {
    let title: String
    let value: JSONScalar?
    let action: (Bool) -> Void

    var body: some View {
        HStack {
            Image(systemName: isOn ? "power.circle.fill" : "power.circle")
                .foregroundStyle(isOn ? .green : .secondary)
            Toggle(title, isOn: Binding(
                get: { isOn },
                set: { action($0) }
            ))
        }
    }

    private var isOn: Bool {
        guard let raw = value?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        if ["1", "true", "on", "yes"].contains(raw) { return true }
        if ["0", "false", "off", "no"].contains(raw) { return false }
        return (Double(raw) ?? 0) != 0
    }
}

struct StatusSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Section("Status") {
            LabeledContent("Web Service", value: store.serviceURL.isEmpty ? "Not set" : store.serviceURL)
            LabeledContent("Local Network", value: store.isLocalNetworkAvailable ? store.networkPath : "Offline")
            LabeledContent("Bluetooth", value: store.bleState)
            if let lastError = store.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct GaugeRow: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let title: String
    let value: Double?
    let unit: String
    let systemImage: String
    let maximum: Double

    init(title: String, value: Double?, unit: String, systemImage: String, maximum: Double = 15.0) {
        self.title = title
        self.value = value
        self.unit = unit
        self.systemImage = systemImage
        self.maximum = maximum
    }

    var body: some View {
        if horizontalSizeClass == .compact {
            compactLayout
        } else {
            regularLayout
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleLabel
                Spacer(minLength: 12)
                valueText
            }
            progress
        }
    }

    private var regularLayout: some View {
        HStack(alignment: .center, spacing: 16) {
            titleLabel
            progress
            valueText
        }
    }

    private var titleLabel: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(.blue)
        }
    }

    private var progress: some View {
        ProgressView(value: min(Swift.max((value ?? 0) / maximum, 0), 1))
    }

    private var valueText: some View {
        Text(formatted)
            .font(.headline.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .layoutPriority(1)
    }

    private var formatted: String {
        guard let value else { return "-- \(unit)" }
        let number = NumberFormatters.voltage.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(number) \(unit)"
    }
}

struct MetricGrid: View {
    let values: [String: JSONScalar]
    let keys: [(String, String)]

    var body: some View {
        ForEach(keys, id: \.0) { key, title in
            LabeledContent(title, value: values[key]?.value ?? "--")
        }
    }
}
