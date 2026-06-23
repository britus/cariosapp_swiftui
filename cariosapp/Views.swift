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
        case .power: "Power"
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
            NavigationStack {
                selectedTab.content
                    .navigationTitle(selectedTab.title)
            }
        }
    }

    private var tabNavigation: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    tab.content
                        .navigationTitle(tab.title)
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.icon)
                }
                .tag(tab)
            }
        }
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
        case .messages: MessageHistoryView()
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
                GaugeRow(title: "Main Battery", value: store.power.mainBattery, unit: "V", systemImage: "battery.100")
                GaugeRow(title: "Board Battery", value: store.power.boardBattery, unit: "V", systemImage: "cpu")
                GaugeRow(title: "Solar Panels", value: store.power.solarPanels, unit: "V", systemImage: "sun.max")
                GaugeRow(title: "Engine Key", value: store.power.engineKey, unit: "V", systemImage: "key")
            }
        }
        .refreshable { await store.refreshAll() }
        .serverConnectionOverlay()
    }
}

struct ChargerView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("System") {
                MetricGrid(values: store.charger.values, keys: [
                    ("sys.cp", "Charge Power"),
                    ("sys.bat.v", "Battery Voltage"),
                    ("sys.bat.i", "Battery Current"),
                    ("sys.bat.p", "Battery Power")
                ])
                ChargerRelayToggle(title: "Relay 1", value: store.charger.values["sys.r1"]) {
                    store.toggleChargerRelay(mode: 1)
                }
                ChargerRelayToggle(title: "Relay 2", value: store.charger.values["sys.r2"]) {
                    store.toggleChargerRelay(mode: 2)
                }
            }
            Section("AC/DC Charger") {
                MetricGrid(values: store.charger.values, keys: [
                    ("acdc.v", "Voltage"),
                    ("acdc.i", "Current"),
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
            Section("BMS / Solar") {
                MetricGrid(values: store.charger.values, keys: [
                    ("bms.v", "BMS Voltage"),
                    ("bms.i", "BMS Current"),
                    ("bms.p", "BMS Power"),
                    ("bms.c", "Capacity"),
                    ("sol.v", "Solar Voltage"),
                    ("sol.i", "Solar Current"),
                    ("sol.p", "Solar Power")
                ])
            }
        }
        .refreshable { await store.loadCharger() }
        .serverConnectionOverlay()
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
                NetworkStatusRow(title: "WiFi WAN IP", value: store.network.wifiWanIp, isAvailable: wifiWanAvailable)
                NetworkStatusRow(title: "Mobile WAN IP", value: store.network.gsmWanIp, isAvailable: mobileWanAvailable)
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
        .serverConnectionOverlay()
    }
}

struct RelayView: View {
    @EnvironmentObject private var store: AppStore
    private let names = ["Bed", "Trunk", "Front", "Radio", "Solar", "Relay 6", "Relay 7", "Relay 8"]

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
        .serverConnectionOverlay()
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
        .serverConnectionOverlay()
    }
}

struct MessageHistoryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            if store.messages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "bell.slash")
            } else {
                ForEach(store.messages) { message in
                    NavigationLink {
                        MessageDetailView(message: message)
                            .onAppear { store.markMessageRead(message) }
                    } label: {
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
                }
            }
        }
        .toolbar {
            Button("Clear") { store.clearMessages() }
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
        .navigationTitle("Message")
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
    func serverConnectionOverlay() -> some View {
        modifier(ServerConnectionOverlay())
    }
}

private struct ServerConnectionOverlay: ViewModifier {
    @EnvironmentObject private var store: AppStore

    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(!store.canCommunicateWithServer)

            if !store.canCommunicateWithServer {
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
        if !store.isLocalNetworkAvailable {
            return "Waiting for local network"
        }
        if !store.hasServiceURL {
            return "Scanning Bluetooth LE for web-service URL"
        }
        return "Waiting for server connection"
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
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isOn ? "power.circle.fill" : "power.circle")
                .foregroundStyle(isOn ? .green : .secondary)
            Toggle(title, isOn: Binding(
                get: { isOn },
                set: { _ in action() }
            ))
        }
    }

    private var isOn: Bool {
        guard let raw = value?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "on"
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
        ProgressView(value: min(max((value ?? 0) / 15.0, 0), 1))
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
