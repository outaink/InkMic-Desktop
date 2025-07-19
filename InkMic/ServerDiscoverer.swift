import SwiftUI
import Network
import Combine
import AVFoundation

// MARK: - Models

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case error(String)
}

struct DataStats {
    var totalPacketsReceived: Int = 0
    var totalBytesReceived: Int = 0
    var packetsPerSecond: Int = 0
    var bytesPerSecond: Int = 0
    var lastUpdateTime: Date = Date()
    var lastPacketTime: Date?
    
    mutating func updateWithNewPacket(bytes: Int) {
        totalPacketsReceived += 1
        totalBytesReceived += bytes
        lastPacketTime = Date()
        
        // Calculate per-second rates
        let now = Date()
        let timeDiff = now.timeIntervalSince(lastUpdateTime)
        if timeDiff >= 1.0 {
            // Reset counters for next second
            packetsPerSecond = totalPacketsReceived
            bytesPerSecond = totalBytesReceived
            lastUpdateTime = now
        }
    }
}

struct DiscoveredDevice: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let service: NetService
    var ipAddress: String?
    var port: Int?
    var isResolving: Bool = false
    var lastSeen: Date = Date()
    var connectionState: ConnectionState = .disconnected
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }
    
    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

// MARK: - Modern Service Discovery Manager using Combine and Swift Concurrency

@MainActor
class ServiceDiscoveryManager: NSObject, ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var isSearching = false
    @Published private(set) var statusMessage = "Ready to search"
    @Published private(set) var error: Error?
    @Published private(set) var connectedDevice: DiscoveredDevice?
    @Published private(set) var audioLevel: Float = 0.0
    @Published private(set) var connectionLogs: [String] = []
    @Published private(set) var receivedDataStats: DataStats = DataStats()
    
    private var browser: NetServiceBrowser?
    private var resolvingServices = Set<NetService>()
    private var cancellables = Set<AnyCancellable>()
    private let serviceType = "_androidmic._udp."
    private let searchTimeout: TimeInterval = 10
    
    // UDP Communication
    private var udpListener: NWListener?
    private var udpConnection: NWConnection?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private let audioQueue = DispatchQueue(label: "audio.processing", qos: .userInteractive)
    private let maxLogEntries = 50
    
    // Shared audio format for consistency throughout the pipeline
    // Using Float32 format which is more universally supported by AVAudioEngine
    private lazy var audioFormat: AVAudioFormat = {
        // Try to create a mono format first
        if let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, 
                                    sampleRate: 44100, 
                                    channels: 1, 
                                    interleaved: false) {
            return format
        }
        
        // Fallback to stereo if mono is not supported
        if let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, 
                                    sampleRate: 44100, 
                                    channels: 2, 
                                    interleaved: false) {
            addLog("⚠️ Using stereo format as fallback")
            return format
        }
        
        // Last resort: use the output node's format
        addLog("⚠️ Using output node format as last resort")
        return audioEngine?.outputNode.outputFormat(forBus: 0) ?? 
               AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    }()
    
    override init() {
        super.init()
        setupBrowser()
        setupAudioEngine()
    }
    
    deinit {
        Task { @MainActor in
            disconnect()
            stopAudioEngine()
        }
    }
    
    private func setupBrowser() {
        browser = NetServiceBrowser()
        browser?.delegate = self
    }
    
    // MARK: - Logging
    
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.timeFormatter.string(from: Date())
        let logEntry = "[\(timestamp)] \(message)"
        
        connectionLogs.append(logEntry)
        
        // Keep only the most recent entries
        if connectionLogs.count > maxLogEntries {
            connectionLogs.removeFirst(connectionLogs.count - maxLogEntries)
        }
        
        print("InkMic: \(logEntry)")
    }
    
    func clearLogs() {
        connectionLogs.removeAll()
        addLog("Logs cleared")
    }
    
    func startDiscovery() {
        guard !isSearching else { return }
        
        devices.removeAll()
        error = nil
        isSearching = true
        statusMessage = "Searching for devices..."
        
        addLog("Starting service discovery for \(serviceType)")
        browser?.searchForServices(ofType: serviceType, inDomain: "local.")
        
        // Auto-stop after timeout
        Task {
            try? await Task.sleep(nanoseconds: UInt64(searchTimeout * 1_000_000_000))
            if devices.isEmpty && isSearching {
                statusMessage = "No devices found. Check network connection."
                addLog("Discovery timeout - no devices found after \(searchTimeout) seconds")
            }
        }
    }
    
    func stopDiscovery() {
        browser?.stop()
        isSearching = false
        statusMessage = devices.isEmpty ? "Search stopped" : "Found \(devices.count) device(s)"
        addLog("Discovery stopped - found \(devices.count) device(s)")
    }
    
    func resolveDevice(_ device: DiscoveredDevice) async {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        
        devices[index].isResolving = true
        
        await withCheckedContinuation { continuation in
            let service = device.service
            service.delegate = self
            resolvingServices.insert(service)
            service.resolve(withTimeout: 5.0)
            
            // Ensure continuation is called after timeout
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continuation.resume()
            }
        }
    }
    
    private func updateDevice(for service: NetService, ipAddress: String?, port: Int?) {
        guard let index = devices.firstIndex(where: { $0.service == service }) else { return }
        
        devices[index].ipAddress = ipAddress
        devices[index].port = port
        devices[index].isResolving = false
    }
    
    // MARK: - Audio Setup
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        
        guard let engine = audioEngine, let playerNode = audioPlayerNode else { 
            addLog("❌ Failed to create audio engine or player node")
            return 
        }
        
        engine.attach(playerNode)
        
        // Get the output format to ensure compatibility
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        addLog("🎵 Output format: \(outputFormat.sampleRate)Hz, \(outputFormat.channelCount) channels")
        
        do {
            // Try to connect with our preferred format first
            engine.connect(playerNode, to: engine.outputNode, format: audioFormat)
            addLog("🎵 Connected with format: \(audioFormat.sampleRate)Hz, \(audioFormat.channelCount) channels")
        } catch {
            addLog("⚠️ Failed to connect with preferred format: \(error)")
            
            // Fallback: connect without specifying format (let the engine decide)
            do {
                engine.connect(playerNode, to: engine.outputNode, format: nil)
                addLog("🔄 Connected with default format")
            } catch {
                addLog("❌ Failed to connect with default format: \(error)")
                return
            }
        }
        
        do {
            try engine.start()
            addLog("✅ Audio engine started successfully")
        } catch {
            addLog("❌ Failed to start audio engine: \(error)")
        }
    }
    
    private func stopAudioEngine() {
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioPlayerNode = nil
        audioEngine = nil
    }
    
    // MARK: - Connection Management
    
    func connectToDevice(_ device: DiscoveredDevice) {
        guard let ipAddress = device.ipAddress,
              let port = device.port else {
            updateDeviceConnectionState(device, state: .error("Device not resolved"))
            addLog("❌ Connection failed: Device \(device.name) not resolved")
            return
        }
        
        disconnect() // Disconnect any existing connection
        
        updateDeviceConnectionState(device, state: .connecting)
        connectedDevice = device
        addLog("🔗 Connecting to \(device.name) at \(ipAddress):\(port)")
        
        // Reset data stats
        receivedDataStats = DataStats()
        
        Task {
            await initiateHandshake(ipAddress: ipAddress, port: port)
        }
    }
    
    func disconnect() {
        if let device = connectedDevice {
            addLog("🔌 Disconnecting from \(device.name)")
        }
        
        udpConnection?.cancel()
        udpConnection = nil
        
        udpListener?.cancel()
        udpListener = nil
        
        if let device = connectedDevice {
            updateDeviceConnectionState(device, state: .disconnected)
        }
        connectedDevice = nil
        audioLevel = 0.0
        
        addLog("✅ Disconnected")
    }
    
    private func updateDeviceConnectionState(_ device: DiscoveredDevice, state: ConnectionState) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].connectionState = state
        
        if connectedDevice?.id == device.id {
            connectedDevice = devices[index]
        }
    }
    
    // MARK: - UDP Communication
    
    private func initiateHandshake(ipAddress: String, port: Int) async {
        do {
            // Step 1: Create UDP listener for incoming audio stream
            let listener = try NWListener(using: .udp, on: .any)
            
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleIncomingAudioConnection(connection)
                }
            }
            
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        if let listenerPort = listener.port {
                            self?.addLog("🎧 UDP listener ready on port \(listenerPort.rawValue)")
                            Task {
                                await self?.sendHandshakePacket(to: ipAddress, port: port, from: Int(listenerPort.rawValue))
                            }
                        }
                    case .failed(let error):
                        self?.handleConnectionError("Failed to start UDP listener: \(error)")
                    default:
                        break
                    }
                }
            }
            
            listener.start(queue: audioQueue)
            self.udpListener = listener
            
        } catch {
            await MainActor.run {
                handleConnectionError("Failed to create UDP listener: \(error)")
            }
        }
    }
    
    // CRITICAL FIX: Corrected port confusion in handshake
    // destinationPort = Android device's advertised port (where to send handshake)
    // localListeningPort = macOS listening port (what to include in handshake message)
    private func sendHandshakePacket(to ipAddress: String, port destinationPort: Int, from localListeningPort: Int) async {
        addLog("🤝 Sending handshake to \(ipAddress):\(destinationPort) with reply port \(localListeningPort)")
        
        do {
            let host = NWEndpoint.Host(ipAddress)
            let port = NWEndpoint.Port(integerLiteral: UInt16(destinationPort))
            let connection = NWConnection(host: host, port: port, using: .udp)
            
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.addLog("📡 Handshake connection established")
                    case .failed(let error):
                        self?.handleConnectionError("Handshake failed: \(error)")
                    default:
                        break
                    }
                }
            }
            
            connection.start(queue: audioQueue)
            
            // Send handshake packet with our listening port
            let handshakeData = "CONNECT:\(localListeningPort)".data(using: .utf8)!
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: handshakeData, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
            
            await MainActor.run {
                if let device = connectedDevice {
                    updateDeviceConnectionState(device, state: .connected)
                    statusMessage = "Connected to \(device.name)"
                    addLog("✅ Handshake sent successfully to \(device.name)")
                }
            }
            
            // Keep connection for a short time then close it
            try await Task.sleep(nanoseconds: 1_000_000_000)
            connection.cancel()
            
        } catch {
            await MainActor.run {
                handleConnectionError("Failed to send handshake: \(error)")
            }
        }
    }
    
    private func handleIncomingAudioConnection(_ connection: NWConnection) {
        connection.start(queue: audioQueue)
        
        Task { @MainActor in
            if let device = connectedDevice {
                updateDeviceConnectionState(device, state: .streaming)
                statusMessage = "Streaming audio from \(device.name)"
                addLog("🎵 Audio streaming started from \(device.name)")
            }
        }
        
        Task {
            await receiveAudioData(from: connection)
        }
    }
    
    private func receiveAudioData(from connection: NWConnection) async {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            
            if let error = error {
                Task { @MainActor in
                    self?.handleConnectionError("Audio receive error: \(error)")
                }
                return
            }
            
            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    self?.processAudioData(data)
                }
            }
            
            Task {
                await self?.receiveAudioData(from: connection)
            }
        }
    }
    
    private func processAudioData(_ data: Data) {
        // Update statistics
        receivedDataStats.updateWithNewPacket(bytes: data.count)
        
        // Log first packet and periodically
        if receivedDataStats.totalPacketsReceived == 1 {
            addLog("📦 First audio packet received (\(data.count) bytes)")
            
            // Log format information on first packet
            if let playerNode = audioPlayerNode {
                let format = playerNode.outputFormat(forBus: 0)
                addLog("🎵 Player format: \(format.commonFormat.rawValue), \(format.sampleRate)Hz, \(format.channelCount)ch")
            }
        } else if receivedDataStats.totalPacketsReceived % 100 == 0 {
            let kbReceived = receivedDataStats.totalBytesReceived / 1024
            addLog("📊 Received \(receivedDataStats.totalPacketsReceived) packets, \(kbReceived) KB total")
        }
        
        // Convert raw audio data to PCM format and play
        guard let playerNode = audioPlayerNode,
              let engine = audioEngine else { 
            addLog("⚠️ Audio engine not available")
            return 
        }
        
        // Create buffer compatible with the player node's format
        let playerFormat = playerNode.outputFormat(forBus: 0)
        let frameCount = UInt32(data.count / 2) // 16-bit samples
        
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else {
            addLog("⚠️ Failed to create audio buffer for \(data.count) bytes")
            return
        }
        
        audioBuffer.frameLength = frameCount
        
        // Convert 16-bit Int data to the buffer format
        if playerFormat.commonFormat == .pcmFormatFloat32 {
            // Convert Int16 to Float32
            data.withUnsafeBytes { bytes in
                guard let int16Pointer = bytes.bindMemory(to: Int16.self).baseAddress else { return }
                guard let floatChannelData = audioBuffer.floatChannelData else { return }
                
                // Convert to float and handle mono/stereo
                for i in 0..<Int(frameCount) {
                    let sample = Float(int16Pointer[i]) / Float(Int16.max)
                    floatChannelData[0][i] = sample
                    
                    // If stereo, duplicate to right channel
                    if playerFormat.channelCount == 2 {
                        floatChannelData[1][i] = sample
                    }
                }
            }
        } else if playerFormat.commonFormat == .pcmFormatInt16 {
            // Direct copy for Int16 format
            data.withUnsafeBytes { bytes in
                guard let int16Pointer = bytes.bindMemory(to: Int16.self).baseAddress else { return }
                guard let int16ChannelData = audioBuffer.int16ChannelData else { return }
                
                // Copy and handle mono/stereo
                for i in 0..<Int(frameCount) {
                    int16ChannelData[0][i] = int16Pointer[i]
                    
                    // If stereo, duplicate to right channel
                    if playerFormat.channelCount == 2 {
                        int16ChannelData[1][i] = int16Pointer[i]
                    }
                }
            }
        }
        
        // Calculate audio level for UI feedback
        let audioLevel = calculateAudioLevel(from: data)
        Task { @MainActor in
            self.audioLevel = audioLevel
        }
        
        // Play audio
        if engine.isRunning {
            playerNode.scheduleBuffer(audioBuffer, completionHandler: nil)
            if !playerNode.isPlaying {
                playerNode.play()
                if receivedDataStats.totalPacketsReceived == 1 {
                    addLog("🔊 Audio playback started")
                }
            }
        } else {
            addLog("⚠️ Audio engine not running, attempting restart")
            // Try to restart the audio engine
            do {
                try engine.start()
                addLog("🔄 Audio engine restarted successfully")
                playerNode.scheduleBuffer(audioBuffer, completionHandler: nil)
                if !playerNode.isPlaying {
                    playerNode.play()
                }
            } catch {
                addLog("❌ Failed to restart audio engine: \(error)")
            }
        }
    }
    
    private func calculateAudioLevel(from data: Data) -> Float {
        let samples = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self)
        }
        
        let sum = samples.reduce(0) { result, sample in
            result + abs(Int32(sample))
        }
        
        let average = Float(sum) / Float(samples.count)
        return min(average / Float(Int16.max), 1.0)
    }
    
    private func handleConnectionError(_ message: String) {
        print("Connection error: \(message)")
        
        if let device = connectedDevice {
            updateDeviceConnectionState(device, state: .error(message))
        }
        
        error = NSError(domain: "AudioConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        statusMessage = "Connection failed: \(message)"
        
        disconnect()
    }
}

// MARK: - NetServiceBrowserDelegate

extension ServiceDiscoveryManager: @preconcurrency NetServiceBrowserDelegate {
    nonisolated func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            statusMessage = "Starting search..."
        }
    }
    
    nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            isSearching = false
            statusMessage = devices.isEmpty ? "Search stopped" : "Found \(devices.count) device(s)"
        }
    }
    
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        let errorCode = errorDict[NetService.errorCode] ?? -1
        Task { @MainActor in
            isSearching = false
            error = NSError(domain: "ServiceDiscovery", code: errorCode.intValue, userInfo: errorDict)
            statusMessage = "Search failed"
        }
    }
    
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let device = DiscoveredDevice(name: service.name, service: service)
        
        Task { @MainActor in
            if !devices.contains(where: { $0.name == device.name }) {
                devices.append(device)
                statusMessage = "Found \(devices.count) device(s)"
            }
        }
    }
    
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            devices.removeAll { $0.service.name == service.name }
            statusMessage = devices.isEmpty ? "No devices found" : "Found \(devices.count) device(s)"
        }
    }
}

// MARK: - NetServiceDelegate

extension ServiceDiscoveryManager: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        defer {
            Task { @MainActor in
                resolvingServices.remove(sender)
            }
        }
        
        guard let addresses = sender.addresses, !addresses.isEmpty else {
            Task { @MainActor in
                updateDevice(for: sender, ipAddress: nil, port: nil)
            }
            return
        }
        
        // Extract IPv4 address
        for addressData in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            
            addressData.withUnsafeBytes { bytes in
                guard let sockAddr = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                
                if sockAddr.pointee.sa_family == AF_INET {
                    if getnameinfo(sockAddr, socklen_t(addressData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ipAddress = String(cString: hostname)
                        Task { @MainActor in
                            updateDevice(for: sender, ipAddress: ipAddress, port: Int(sender.port))
                        }
                        return
                    }
                }
            }
        }
    }
    
    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        Task { @MainActor in
            resolvingServices.remove(sender)
            updateDevice(for: sender, ipAddress: nil, port: nil)
        }
    }
}

// MARK: - Extensions

extension DateFormatter {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

