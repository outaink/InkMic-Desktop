// MARK: - Views
import SwiftUI
struct ContentView: View {
    @StateObject private var discoveryManager = ServiceDiscoveryManager()
    @State private var selectedDeviceID: UUID?
    @State private var showingDetails = false
    
    private var selectedDevice: DiscoveredDevice? {
        guard let selectedDeviceID = selectedDeviceID else { return nil }
        return discoveryManager.devices.first { $0.id == selectedDeviceID }
    }
    
    var body: some View {
        NavigationSplitView {
            DeviceListView(
                devices: discoveryManager.devices,
                selectedDeviceID: $selectedDeviceID,
                isSearching: discoveryManager.isSearching,
                statusMessage: discoveryManager.statusMessage,
                connectedDevice: discoveryManager.connectedDevice,
                onStartSearch: { discoveryManager.startDiscovery() },
                onStopSearch: { discoveryManager.stopDiscovery() },
                onResolveDevice: { device in
                    Task {
                        await discoveryManager.resolveDevice(device)
                    }
                },
                onConnectDevice: { device in
                    discoveryManager.connectToDevice(device)
                },
                onDisconnect: {
                    discoveryManager.disconnect()
                }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            if let device = selectedDevice {
                DeviceDetailView(
                    device: device,
                    connectedDevice: discoveryManager.connectedDevice,
                    audioLevel: discoveryManager.audioLevel,
                    receivedDataStats: discoveryManager.receivedDataStats,
                    connectionLogs: discoveryManager.connectionLogs,
                    onConnect: { discoveryManager.connectToDevice(device) },
                    onDisconnect: { discoveryManager.disconnect() },
                    onClearLogs: { discoveryManager.clearLogs() }
                )
            } else {
                EmptyStateView()
            }
        }
        .navigationTitle(discoveryManager.connectedDevice != nil ? "InkMic - Connected" : "InkMic")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SearchButton(
                    isSearching: discoveryManager.isSearching,
                    onStartSearch: { discoveryManager.startDiscovery() },
                    onStopSearch: { discoveryManager.stopDiscovery() }
                )
            }
        }
    }
}

struct DeviceListView: View {
    let devices: [DiscoveredDevice]
    @Binding var selectedDeviceID: UUID?
    let isSearching: Bool
    let statusMessage: String
    let connectedDevice: DiscoveredDevice?
    let onStartSearch: () -> Void
    let onStopSearch: () -> Void
    let onResolveDevice: (DiscoveredDevice) -> Void
    let onConnectDevice: (DiscoveredDevice) -> Void
    let onDisconnect: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            StatusBar(message: statusMessage, isSearching: isSearching)
            
            if devices.isEmpty {
                EmptyDeviceListView(
                    isSearching: isSearching,
                    onStartSearch: onStartSearch
                )
            } else {
                List(devices, id: \.id, selection: $selectedDeviceID) { device in
                    DeviceRow(
                        device: device,
                        isConnected: connectedDevice?.id == device.id,
                        onResolve: { onResolveDevice(device) },
                        onConnect: { onConnectDevice(device) },
                        onDisconnect: onDisconnect
                    )
                    .tag(device.id)
                }
                .listStyle(.sidebar)
            }
        }
    }
}

struct DeviceRow: View {
    let device: DiscoveredDevice
    let isConnected: Bool
    let onResolve: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                
                if let ip = device.ipAddress, let port = device.port {
                    HStack {
                        Text("\(ip):\(port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        ConnectionStatusBadge(state: device.connectionState)
                    }
                } else {
                    Button("Resolve") {
                        onResolve()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .disabled(device.isResolving)
                }
            }
            
            Spacer()
            
            if device.isResolving {
                ProgressView()
                    .scaleEffect(0.5)
            } else if isConnected {
                Button(action: onDisconnect) {
                    Image(systemName: "stop.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            } else if device.ipAddress != nil {
                Button(action: onConnect) {
                    Image(systemName: "play.circle")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "network")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeviceDetailView: View {
    let device: DiscoveredDevice
    let connectedDevice: DiscoveredDevice?
    let audioLevel: Float
    let receivedDataStats: DataStats
    let connectionLogs: [String]
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onClearLogs: () -> Void
    
    private var isConnected: Bool {
        connectedDevice?.id == device.id
    }
    
    private var deviceIcon: String {
        switch device.connectionState {
        case .connected, .streaming:
            return "mic.fill"
        case .connecting:
            return "mic.badge.plus"
        case .error:
            return "mic.slash"
        default:
            return "mic"
        }
    }
    
    private var deviceIconColor: Color {
        switch device.connectionState {
        case .connected:
            return .green
        case .streaming:
            return .blue
        case .connecting:
            return .orange
        case .error:
            return .red
        default:
            return .accentColor
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                VStack {
                    Image(systemName: deviceIcon)
                        .font(.largeTitle)
                        .foregroundColor(deviceIconColor)
                    
                    if isConnected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                VStack(alignment: .leading) {
                    Text(device.name)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    
                    HStack {
                        Text("Android Microphone Device")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        ConnectionStatusBadge(state: device.connectionState)
                    }
                    
                    if let ip = device.ipAddress, let port = device.port {
                        Text("\(ip):\(port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            
            Divider()
            
            // Connection Details
            GroupBox("Connection Details") {
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(label: "Device Name", value: device.name)
                    DetailRow(label: "Device ID", value: device.id.uuidString.prefix(8) + "...")
                    DetailRow(label: "Service Type", value: "_androidmic._udp.")
                    
                    if let ip = device.ipAddress {
                        DetailRow(label: "IP Address", value: ip)
                    } else {
                        DetailRow(label: "IP Address", value: "Not resolved")
                    }
                    
                    if let port = device.port {
                        DetailRow(label: "Port", value: String(port))
                    } else {
                        DetailRow(label: "Port", value: "Not resolved")
                    }
                    
                    DetailRow(label: "Connection Status", value: connectionStatusText(device.connectionState))
                    DetailRow(label: "Resolution Status", value: device.isResolving ? "Resolving..." : "Ready")
                    DetailRow(label: "Last Discovered", value: device.lastSeen.formatted(date: .omitted, time: .shortened))
                    DetailRow(label: "Discovery Time", value: device.lastSeen.formatted(date: .abbreviated, time: .omitted))
                    
                    if let ip = device.ipAddress, let port = device.port {
                        DetailRow(label: "Full Address", value: "\(ip):\(port)")
                    }
                }
                .padding(.vertical, 8)
            }
            
            // Device Information
            if !isConnected && device.ipAddress != nil {
                GroupBox("Device Information") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("This Android device is advertising microphone services on your local network.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Image(systemName: "wifi")
                                .foregroundColor(.green)
                            Text("Network connectivity established and device is reachable.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if device.connectionState == .disconnected {
                            HStack {
                                Image(systemName: "play.circle")
                                    .foregroundColor(.orange)
                                Text("Ready to connect. Click 'Connect to Device' to start audio streaming.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Audio Level Indicator
            if isConnected {
                GroupBox("Audio Level") {
                    AudioLevelIndicator(level: audioLevel)
                        .padding(.vertical, 8)
                }
                
                // Data Statistics
                DataStatsView(stats: connectedDevice?.connectionState == .streaming ? 
                            receivedDataStats : DataStats())
                
                // Connection Logs
                ConnectionLogsView(
                    logs: connectionLogs,
                    onClear: { onClearLogs() }
                )
            }
            
            // Actions
            if device.ipAddress != nil && device.port != nil {
                HStack {
                    if isConnected {
                        Button("Disconnect") {
                            onDisconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button("Connect to Device") {
                            onConnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connectedDevice != nil)
                    }
                    
                    Button("Copy Connection Info") {
                        let info = "\(device.ipAddress ?? ""):\(device.port ?? 0)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }
            }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private func connectionStatusText(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .streaming:
            return "Streaming Audio"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            
            Text(value)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }
}

struct StatusBar: View {
    let message: String
    let isSearching: Bool
    
    var body: some View {
        HStack {
            if isSearching {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
            }
            
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "network.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Device Selected")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Select a device from the list to view details")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyDeviceListView: View {
    let isSearching: Bool
    let onStartSearch: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isSearching ? "antenna.radiowaves.left.and.right" : "network")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: isSearching)
            
            Text(isSearching ? "Searching for devices..." : "No devices found")
                .font(.title3)
                .fontWeight(.medium)
            
            if !isSearching {
                Button("Start Search") {
                    onStartSearch()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SearchButton: View {
    let isSearching: Bool
    let onStartSearch: () -> Void
    let onStopSearch: () -> Void
    
    var body: some View {
        Button {
            isSearching ? onStopSearch() : onStartSearch()
        } label: {
            Label(
                isSearching ? "Stop Search" : "Start Search",
                systemImage: isSearching ? "stop.circle" : "magnifyingglass"
            )
        }
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - Additional UI Components

struct ConnectionStatusBadge: View {
    let state: ConnectionState
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var statusColor: Color {
        switch state {
        case .disconnected:
            return .gray
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .streaming:
            return .blue
        case .error:
            return .red
        }
    }
    
    private var statusText: String {
        switch state {
        case .disconnected:
            return "Offline"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .streaming:
            return "Streaming"
        case .error:
            return "Error"
        }
    }
}

struct AudioLevelIndicator: View {
    let level: Float
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Level")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(Int(level * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 8)
                    
                    // Level indicator
                    RoundedRectangle(cornerRadius: 4)
                        .fill(levelColor)
                        .frame(width: geometry.size.width * CGFloat(level), height: 8)
                        .animation(.easeInOut(duration: 0.1), value: level)
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 4)
    }
    
    private var levelColor: Color {
        switch level {
        case 0.0..<0.3:
            return .green
        case 0.3..<0.7:
            return .yellow
        case 0.7...1.0:
            return .red
        default:
            return .gray
        }
    }
}

struct DataStatsView: View {
    let stats: DataStats
    
    var body: some View {
        GroupBox("Data Statistics") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Packets Received:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(stats.totalPacketsReceived)")
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Total Data:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatBytes(stats.totalBytesReceived))
                        .fontWeight(.medium)
                }
                
                if let lastPacket = stats.lastPacketTime {
                    HStack {
                        Text("Last Packet:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(DateFormatter.timeFormatter.string(from: lastPacket))
                            .fontWeight(.medium)
                    }
                }
                
                if stats.totalPacketsReceived > 0 {
                    HStack {
                        Text("Avg Packet Size:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(stats.totalBytesReceived / stats.totalPacketsReceived) bytes")
                            .fontWeight(.medium)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
}

struct ConnectionLogsView: View {
    let logs: [String]
    let onClear: () -> Void
    
    var body: some View {
        GroupBox {
            HStack {
                Text("Connection Logs")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    onClear()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(index % 2 == 0 ? Color.clear : Color.gray.opacity(0.1))
                                .id(index)
                        }
                        
                        // Invisible spacer for auto-scroll target
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .onChange(of: logs.count) {
                        if !logs.isEmpty {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .frame(height: 200)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
        }
    }
}
