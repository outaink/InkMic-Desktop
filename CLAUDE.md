# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

InkMic is a macOS SwiftUI application for discovering and connecting to Android microphone devices over the local network using Bonjour/Zeroconf service discovery. The app searches for `_androidmic._udp.` services and provides a user interface to view and connect to discovered devices.

## Build and Development Commands

### Building the Project
```bash
# Build using Xcode command line tools
xcodebuild -project InkMic.xcodeproj -scheme InkMic -configuration Debug build

# Build for release
xcodebuild -project InkMic.xcodeproj -scheme InkMic -configuration Release build
```

### Running Tests
```bash
# Run unit tests
xcodebuild -project InkMic.xcodeproj -scheme InkMic -destination 'platform=macOS' test

# Run specific test target
xcodebuild -project InkMic.xcodeproj -scheme InkMicTests -destination 'platform=macOS' test
```

### Opening in Xcode
```bash
open InkMic.xcodeproj
```

## Architecture Overview

### Core Components

1. **ServiceDiscoveryManager** (`ServerDiscoverer.swift`): Main business logic class that handles Bonjour service discovery and UDP audio communication
   - Uses `NetServiceBrowser` for discovering services
   - Implements both `NetServiceBrowserDelegate` and `NetServiceDelegate`
   - Manages device resolution and connection state
   - Uses modern Swift concurrency (async/await) and Combine for reactive updates
   - Handles UDP handshake and audio streaming via Network.framework
   - Integrates AVAudioEngine for real-time audio playback

2. **ContentView** (`ContentView.swift`): Main UI containing multiple view components
   - Split view layout with device list and detail views
   - Reactive UI updates through `@StateObject` and `@Published` properties
   - Contains all UI components in a single file
   - Shows connection status and audio level indicators

3. **DiscoveredDevice Model**: Represents network devices found via service discovery
   - Contains device metadata (name, IP, port, service reference)
   - Tracks resolution state, connection state, and timestamps
   - Supports ConnectionState enum (disconnected, connecting, connected, streaming, error)

### Key Features

- **Network Discovery**: Searches for `_androidmic._udp.` services on local network
- **Device Resolution**: Resolves service addresses to get IP and port information  
- **Real-time UI**: Live updates as devices are discovered/removed with connection status
- **UDP Communication**: Establishes handshake and audio streaming connections
- **Audio Processing**: Real-time audio playback through AVAudioEngine with level monitoring

### App Configuration

- **Target Platform**: macOS 15.5+
- **Swift Version**: 5.0
- **Bundle ID**: `outaink.InkMic`
- **Entitlements**: Network client/server access, sandboxed app
- **Localization**: Chinese description for local network usage

### Testing Structure

- **Unit Tests**: `InkMicTests/` - Uses Swift Testing framework
- **UI Tests**: `InkMicUITests/` - Automated UI testing

## Communication Protocol

The app implements a two-phase UDP communication protocol:

### Phase 1: Handshake (macOS → Android)
1. macOS creates a UDP listener on a random available port
2. macOS sends handshake packet to Android device containing: `"CONNECT:<port>"`
3. Android device receives the packet and learns macOS IP and port

### Phase 2: Audio Streaming (Android → macOS)
1. Android captures microphone audio and streams UDP packets to macOS
2. macOS receives audio data and plays it through AVAudioEngine
3. Audio level is calculated and displayed in real-time

### Audio Format
- **Sample Rate**: 44.1 kHz
- **Format**: 16-bit PCM, mono
- **Transport**: UDP packets (up to 4096 bytes each)

## Development Notes

- The app requires local network permissions to discover devices
- Service discovery is limited to the `.local` domain
- Uses modern SwiftUI navigation with `NavigationSplitView`
- Implements proper memory management with `@MainActor` for UI updates
- Network operations use Swift concurrency patterns with proper actor isolation
- Audio processing happens on a dedicated queue for real-time performance
- Connection state is managed reactively through @Published properties