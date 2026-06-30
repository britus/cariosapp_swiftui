import SwiftUI

/** Defines the primary navigation tabs available in the CarIOS app. */
enum AppTab: String, CaseIterable, Identifiable {
    /** Represents the power option. */
    case power
    /** Represents the charger option. */
    case charger
    /** Represents the network option. */
    case network
    /** Represents the relays option. */
    case relays
    /** Represents the mobile option. */
    case mobile
    /** Represents the messages option. */
    case messages
    /** Represents the commands option. */
    case commands
    /** Represents the settings option. */
    case settings

    /** Stable identifier used by SwiftUI collections and persisted models. */
    var id: String { rawValue }

    /** User-facing title shown for this item. */
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

    /** Service poll type associated with this tab, or nil when the tab does not poll. */
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

    /** SF Symbol name used for this tab in navigation UI. */
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

/** Coordinates the app-level navigation and message detail routing. */
struct RootView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /** Stores the selected tab value. */
    @State private var selectedTab: AppTab = .power
    /** Stores the message path value. */
    @State private var messagePath: [PushMessage] = []
    /** Stores the message delete confirmation value. */
    @State private var messageDeleteConfirmation: MessageDeleteConfirmation?

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

    /** Navigation layout used on wide regular-width displays. */
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
                messagesNavigation(usesSplitToolbar: true)
            } else {
                NavigationStack {
                    selectedTab.content
                        .navigationTitle(selectedTab.title)
                }
            }
        }
    }

    /** Tab-based navigation layout used on compact displays. */
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
    /** Builds the navigation stack for a specific tab. */
    private func tabNavigationStack(for tab: AppTab) -> some View {
        if tab == .messages {
            messagesNavigation(usesSplitToolbar: false)
        } else {
            NavigationStack {
                tab.content
                    .navigationTitle(tab.title)
            }
        }
    }

    /** Navigation stack used for message history and detail screens. */
    private func messagesNavigation(usesSplitToolbar: Bool) -> some View {
        NavigationStack(path: $messagePath) {
            MessageHistoryView(onDeleteRequest: requestMessageDeletion)
                .navigationTitle(AppTab.messages.title)
                .toolbar {
                    if usesSplitToolbar {
                        messageHistoryToolbarItems
                    }
                }
                .navigationDestination(for: PushMessage.self) { message in
                    MessageDetailView(message: message)
                        .navigationTitle(message.title.isEmpty ? "Message" : message.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            if usesSplitToolbar {
                                messageDetailToolbarItems(for: message)
                            }
                        }
                        .onAppear { store.markMessageRead(message) }
                }
        }
        .toolbar {
            if !usesSplitToolbar {
                messageToolbarItems
            }
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
    /** Main toolbar actions used by compact message navigation. */
    private var messageToolbarItems: some ToolbarContent {
        if let message = messagePath.last {
            messageDetailToolbarItems(for: message)
        } else {
            messageHistoryToolbarItems
        }
    }

    @ToolbarContentBuilder
    /** Toolbar action for clearing all messages from the message history. */
    private var messageHistoryToolbarItems: some ToolbarContent {
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

    @ToolbarContentBuilder
    /** Toolbar actions for deleting or closing a message detail screen. */
    private func messageDetailToolbarItems(for message: PushMessage) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                closeMessageDetail()
            } label: {
                Label("Messages", systemImage: "chevron.left")
            }
        }
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
    }

    /** Boolean binding that presents and clears the delete confirmation alert. */
    private var messageDeleteConfirmationBinding: Binding<Bool> {
        Binding {
            messageDeleteConfirmation != nil
        } set: { isPresented in
            if !isPresented {
                messageDeleteConfirmation = nil
            }
        }
    }

    /** Stores the deletion request so the confirmation alert can present it. */
    private func requestMessageDeletion(_ confirmation: MessageDeleteConfirmation) {
        messageDeleteConfirmation = confirmation
    }

    /** Deletes the requested message scope and clears the confirmation state. */
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

    /** Pops the active message detail screen when one is visible. */
    private func closeMessageDetail() {
        guard !messagePath.isEmpty else { return }
        messagePath.removeLast()
    }
}

/** Adds CarIOS-specific behavior to AppTab. */
extension AppTab {
    @ViewBuilder
    /** SwiftUI content associated with this app tab. */
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

/** Shows the current power and voltage telemetry from the CarIOS service. */
struct PowerView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Shows charger telemetry and exposes charger relay controls. */
struct ChargerView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore

    private var slcTitle: String {
        guard let v = double("sys.bat.i") else {
            return "Current"
        }
        if v < 0 {
            return "Supply Current"
        } else if v > 0 {
            return "Charge Current"
        } else {
            return "Current"
        }
    }
    private var slpTitle: String {
        guard let v = double("sys.bat.p") else {
            return "Power"
        }
        if v < 0 {
            return "Supply Power"
        } else if v > 0 {
            return "Charge Power"
        } else {
            return "Current"
        }
    }
    private var bmscTitle: String {
        guard let v = double("bms.i") else {
            return "Current"
        }
        if v < 0 {
            return "Supply Current"
        } else if v > 0 {
            return "Charge Current"
        } else {
            return "Current"
        }
    }
    private var bmspTitle: String {
        guard let v = double("bms.p") else {
            return "Power"
        }
        if v < 0 {
            return "Supply Power"
        } else if v > 0 {
            return "Charge Power"
        } else {
            return "Current"
        }
    }

    /** Builds the SwiftUI view hierarchy for this view or scene. */
    var body: some View {
        List {
            Section("System Control") {
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
            Section("Solar Panels") {
                GaugeRow(title: "Voltage", value: double("sol.v"), unit: "V", systemImage: "bolt.fill", maximum: 24)
                GaugeRow(title: "Current", value: double("sol.i"), unit: "A", systemImage: "gauge", maximum: 30)
                GaugeRow(title: "Power", value: double("sol.p"), unit: "W", systemImage: "bolt.circle.fill", maximum: 1500)
                GaugeRow(title: "Load V", value: double("sol.load.v"), unit: "V", systemImage: "bolt.fill", maximum: 15)
                GaugeRow(title: "Load I", value: double("sol.load.i"), unit: "A", systemImage: "bolt.circle.fill", maximum: 18)
            }
            Section("Board Battery") {
                GaugeRow(title: "Voltage", value: double("sys.bat.v"), unit: "V", systemImage: "bolt.fill", maximum: 15)
                GaugeRow(title: slcTitle, value: double("sys.bat.i"), unit: "A", systemImage: "gauge", maximum: 30)
                GaugeRow(title: slpTitle, value: double("sys.bat.p"), unit: "W", systemImage: "bolt.circle.fill", maximum: 1500)
                if (double("sys.cp") != 0) {
                    GaugeRow(title: "Charger", value: double("sys.cp"), unit: "W", systemImage: "bolt.circle.fill", maximum: 1500)
                }
            }
            Section("Battery Management System") {
                GaugeRow(title: "Voltage", value: double("bms.v"), unit: "V", systemImage: "bolt.fill", maximum: 15)
                GaugeRow(title: bmscTitle, value: double("bms.i"), unit: "A", systemImage: "gauge", maximum: 30)
                GaugeRow(title: bmspTitle, value: double("bms.p"), unit: "W", systemImage: "bolt.circle.fill", maximum: 1500)
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

    /** Converts a charger scalar field into a Double for gauge rendering. */
    private func double(_ key: String) -> Double? {
        guard let raw = store.charger.values[key]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Double(raw)
    }
}

/** Shows network status details and network maintenance actions. */
struct NetworkView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Shows and controls the configured CarIOS relay outputs. */
struct RelayView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore
    /** Stores the names value. */
    private let names = ["Bed K1", "Trunk K2", "Relay 3", "Boden K4", "Radio K5", "Relay 6", "Front Spot K7", "Back Spot K8"]

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Shows mobile modem and cellular network telemetry. */
struct MobileView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Lists received push and data messages. */
struct MessageHistoryView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore
    /** Stores the on delete request value. */
    let onDeleteRequest: (MessageDeleteConfirmation) -> Void

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

    /** Builds a destructive swipe action for a message row. */
    private func deleteButton(for message: PushMessage) -> some View {
        Button(role: .destructive) {
            onDeleteRequest(.message(message))
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/** Describes the pending message deletion action that needs user confirmation. */
enum MessageDeleteConfirmation: Identifiable {
    /** Deletes the complete message history. */
    case all
    /** Deletes a single selected message. */
    case message(PushMessage)

    /** Stable identifier used by SwiftUI collections and persisted models. */
    var id: String {
        switch self {
        case .all: "all"
        case .message(let message): message.id
        }
    }
}

/** Shows the complete payload and metadata for a push message. */
struct MessageDetailView: View {
    /** Stores the message value. */
    let message: PushMessage

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Exposes diagnostic and service commands for the CarIOS backend. */
struct CommandView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Shows configuration, Bluetooth, notification, and diagnostic settings. */
struct SettingsView: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore
    /** Stores the draft url value. */
    @State private var draftURL = ""

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Adds CarIOS-specific behavior to View. */
private extension View {
    /** Applies the connection-state overlay to a view. */
    func serverConnectionOverlay(remoteDataType: String? = nil) -> some View {
        modifier(ServerConnectionOverlay(remoteDataType: remoteDataType))
    }
}

/** Blocks interactive content while the app cannot reach the CarIOS service or required data is missing. */
private struct ServerConnectionOverlay: ViewModifier {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore
    /** Stores the remote data type value. */
    let remoteDataType: String?

    /** Performs the body operation. */
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

    /** Human-readable explanation for the current connection-blocking state. */
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

    /** Text describing the currently detected local network. */
    private var currentNetworkText: String {
        if store.networkPath == "WiFi", !store.wifiNetworkPrefix.isEmpty {
            return "Current network: \(store.wifiNetworkPrefix)"
        }
        return "Current network unknown."
    }
}

/** Displays a network value with availability highlighting. */
struct NetworkStatusRow: View {
    /** User-facing title shown for this item. */
    let title: String
    /** String-backed scalar value used for display and encoding. */
    let value: String
    /** Stores the is available value. */
    let isAvailable: Bool

    /** Builds the SwiftUI view hierarchy for this view or scene. */
    var body: some View {
        LabeledContent(title, value: value.isEmpty ? "--" : value)
            .listRowBackground(isAvailable ? Color.green.opacity(0.22) : Color.clear)
    }

    /** Returns true when the WAN address represents an available interface. */
    static func isAvailableWAN(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "0.0.0.0"
    }
}

/** Displays a charger relay state and sends toggle changes back to the store. */
struct ChargerRelayToggle: View {
    /** User-facing title shown for this item. */
    let title: String
    /** String-backed scalar value used for display and encoding. */
    let value: JSONScalar?
    /** Stores the action value. */
    let action: (Bool) -> Void

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

    /** Boolean relay state derived from the raw scalar value. */
    private var isOn: Bool {
        guard let raw = value?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        if ["1", "true", "on", "yes"].contains(raw) { return true }
        if ["0", "false", "off", "no"].contains(raw) { return false }
        return (Double(raw) ?? 0) != 0
    }
}

/** Displays compact connection and error status information. */
struct StatusSection: View {
    /** Stores the store value. */
    @EnvironmentObject private var store: AppStore

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Displays a labeled numeric value together with a normalized progress indicator. */
struct GaugeRow: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /** User-facing title shown for this item. */
    let title: String
    /** String-backed scalar value used for display and encoding. */
    let value: Double?
    /** Stores the unit value. */
    let unit: String
    /** Stores the system image value. */
    let systemImage: String
    /** Stores the maximum value. */
    let maximum: Double

    /** Creates a new instance with the supplied values. */
    init(title: String, value: Double?, unit: String, systemImage: String, maximum: Double = 15.0) {
        self.title = title
        self.value = value
        self.unit = unit
        self.systemImage = systemImage
        self.maximum = maximum
    }

    /** Builds the SwiftUI view hierarchy for this view or scene. */
    var body: some View {
        if horizontalSizeClass == .compact {
            compactLayout
        } else {
            regularLayout
        }
    }

    /** Layout optimized for compact horizontal size classes. */
    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleLabel
                Spacer(minLength: 6)
                valueText
            }
            progress
        }
    }

    /** Layout optimized for regular horizontal size classes. */
    private var regularLayout: some View {
        HStack(alignment: .center, spacing: 16) {
            titleLabel
            progress
            valueText
        }
    }

    /** Label that combines the metric title with its SF Symbol. */
    private var titleLabel: some View {
        Label {
            Text(title).frame(alignment: .leading)
                .font(Font.subheadline)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(.blue)
        }
    }

    private var normValue: Double {
        guard let v = value as Double? else {
            return 0
        }
        if v < 0 {
            return v * -1
        } else {
            return v
        }
    }

    /** Normalized progress indicator for the metric value. */
    private var progress: some View {
        ProgressView(value: min(Swift.max(normValue / maximum, 0), 1))
            .frame(minWidth: 200, idealWidth: 250, maxWidth: .infinity, alignment: .leading)
    }

    /** Formatted value text shown beside the gauge. */
    private var valueText: some View {
        Text(formatted)
            .font(.headline.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .layoutPriority(1)
    }

    /** Display string for the numeric value and unit. */
    private var formatted: String {
        guard let value else { return "-- \(unit)" }
        let number = NumberFormatters.voltage.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(number) \(unit)"
    }
}

/** Displays key-value telemetry fields as labeled rows. */
struct MetricGrid: View {
    /** Stores the values value. */
    let values: [String: JSONScalar]
    /** Stores the keys value. */
    let keys: [(String, String)]

    /** Builds the SwiftUI view hierarchy for this view or scene. */
    var body: some View {
        ForEach(keys, id: \.0) { key, title in
            LabeledContent(title, value: values[key]?.value ?? "--")
        }
    }
}
