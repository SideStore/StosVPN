//
//  ContentView.swift
//  StosVPN
//
//  Created by Stossy11 on 28/03/2025.
//

import SwiftUI
import Foundation
import NetworkExtension


// MARK: - Logging Utility
class VPNLogger: ObservableObject {
    @Published var logs: [String] = []
    
    static var shared = VPNLogger()
    
    private init() {}
    
    func log(_ message: Any, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let fileName = (file as NSString).lastPathComponent
        print("[\(fileName):\(line)] \(function): \(message)")
        #endif
        
        logs.append("\(message)")
    }
}

class PrivacyManager {
    static let shared = PrivacyManager()
    
    // This function explicitly shows we're not collecting any data
    func collectUserData() -> [String: Any]? {
        return nil
    }
    
    // This function explicitly shows we're not sharing any data
    func shareDataWithThirdParties() -> Bool {
        return false
    }
    
    private init() {}
}

// MARK: - Tunnel Manager
class TunnelManager: ObservableObject {
    @Published var hasLocalDeviceSupport = false
    @Published var tunnelStatus: TunnelStatus = .disconnected
    
    static var shared = TunnelManager()
    
    private var vpnManager: NETunnelProviderManager?
    private var vpnObserver: NSObjectProtocol?
    
    private var tunnelDeviceIp: String {
        UserDefaults.standard.string(forKey: "TunnelDeviceIP") ?? "10.7.0.0"
    }
    
    private var tunnelFakeIp: String {
        UserDefaults.standard.string(forKey: "TunnelFakeIP") ?? "10.7.0.1"
    }
    
    private var tunnelSubnetMask: String {
        UserDefaults.standard.string(forKey: "TunnelSubnetMask") ?? "255.255.255.0"
    }
    
    private var tunnelBundleId: String {
        Bundle.main.bundleIdentifier!.appending(".TunnelProv")
    }
    
    enum TunnelStatus: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case disconnecting = "Disconnecting"
        case error = "Error"
        
        var color: Color {
            switch self {
            case .disconnected: return .gray
            case .connecting: return .orange
            case .connected: return .green
            case .disconnecting: return .orange
            case .error: return .red
            }
        }
        
        var systemImage: String {
            switch self {
            case .disconnected: return "network.slash"
            case .connecting: return "network.badge.shield.half.filled"
            case .connected: return "checkmark.shield.fill"
            case .disconnecting: return "network.badge.shield.half.filled"
            case .error: return "exclamationmark.shield.fill"
            }
        }
    }
    
    private init() {
        loadTunnelPreferences()
        setupStatusObserver()
    }
    
    // MARK: - Private Methods
    private func loadTunnelPreferences() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                
                if let error = error {
                    VPNLogger.shared.log("Error loading preferences: \(error.localizedDescription)")
                    self.tunnelStatus = .error
                    return
                }
                
                self.hasLocalDeviceSupport = true
                
                if let managers = managers, !managers.isEmpty {
                    for manager in managers {
                        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                           proto.providerBundleIdentifier == self.tunnelBundleId {
                            self.vpnManager = manager
                            self.updateTunnelStatus(from: manager.connection.status)
                            VPNLogger.shared.log("Loaded existing tunnel configuration")
                            break
                        }
                    }
                    
                    // If we didn't find a matching manager, use the first one
                    if self.vpnManager == nil, let firstManager = managers.first {
                        self.vpnManager = firstManager
                        self.updateTunnelStatus(from: firstManager.connection.status)
                        VPNLogger.shared.log("Using existing tunnel configuration")
                    }
                } else {
                    VPNLogger.shared.log("No existing tunnel configuration found")
                }
            }
        }
    }
    
    private func setupStatusObserver() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let connection = notification.object as? NEVPNConnection else {
                return
            }
            
            self.updateTunnelStatus(from: connection.status)
        }
    }
    
    private func updateTunnelStatus(from connectionStatus: NEVPNStatus) {
        DispatchQueue.main.async {
            switch connectionStatus {
            case .invalid, .disconnected:
                self.tunnelStatus = .disconnected
            case .connecting:
                self.tunnelStatus = .connecting
            case .connected:
                self.tunnelStatus = .connected
            case .disconnecting:
                self.tunnelStatus = .disconnecting
            case .reasserting:
                self.tunnelStatus = .connecting
            @unknown default:
                self.tunnelStatus = .error
            }
            
            VPNLogger.shared.log("VPN status updated: \(self.tunnelStatus.rawValue)")
        }
    }
    
    private func createOrUpdateTunnelConfiguration(completion: @escaping (Bool) -> Void) {
        // First check if we already have configurations
        NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
            guard let self = self else { return completion(false) }
            
            if let error = error {
                VPNLogger.shared.log("Error loading preferences: \(error.localizedDescription)")
                return completion(false)
            }
            
            let manager: NETunnelProviderManager
            if let existingManagers = managers, !existingManagers.isEmpty {
                if let matchingManager = existingManagers.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleId
                }) {
                    manager = matchingManager
                    VPNLogger.shared.log("Updating existing tunnel configuration")
                } else {
                    manager = existingManagers[0]
                    VPNLogger.shared.log("Using first available tunnel configuration")
                }
            } else {
                // Create a new manager if none exists
                manager = NETunnelProviderManager()
                VPNLogger.shared.log("Creating new tunnel configuration")
            }
            
            manager.localizedDescription = "StosVPN"
            
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleId
            proto.serverAddress = "StosVPN's Local Network Tunnel"
            manager.protocolConfiguration = proto
            
            let onDemandRule = NEOnDemandRuleEvaluateConnection()
            onDemandRule.interfaceTypeMatch = .any
            onDemandRule.connectionRules = [NEEvaluateConnectionRule(
                matchDomains: ["localhost"],
                andAction: .connectIfNeeded
            )]
            
            manager.onDemandRules = [onDemandRule]
            manager.isOnDemandEnabled = true
            manager.isEnabled = true
            
            manager.saveToPreferences { [weak self] error in
                guard let self = self else { return completion(false) }
                
                DispatchQueue.main.async {
                    if let error = error {
                        VPNLogger.shared.log("Error saving tunnel configuration: \(error.localizedDescription)")
                        completion(false)
                        return
                    }
                    
                    self.vpnManager = manager
                    VPNLogger.shared.log("Tunnel configuration saved successfully")
                    completion(true)
                }
            }
        }
    }
    
    // MARK: - Public Methods
    
    func toggleVPNConnection() {
        if tunnelStatus == .connected || tunnelStatus == .connecting {
            stopVPN()
        } else {
            startVPN()
        }
    }
    
    func startVPN() {
        if let manager = vpnManager {
            startExistingVPN(manager: manager)
        } else {
            createOrUpdateTunnelConfiguration { [weak self] success in
                guard let self = self, success else { return }
                self.loadTunnelPreferences()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let manager = self.vpnManager {
                        self.startExistingVPN(manager: manager)
                    }
                }
            }
        }
    }
    
    private func startExistingVPN(manager: NETunnelProviderManager) {
        guard tunnelStatus != .connected else {
            VPNLogger.shared.log("Network tunnel is already connected")
            return
        }
        
        tunnelStatus = .connecting
        
        let options: [String: NSObject] = [
            "TunnelDeviceIP": tunnelDeviceIp as NSObject,
            "TunnelFakeIP": tunnelFakeIp as NSObject,
            "TunnelSubnetMask": tunnelSubnetMask as NSObject
        ]
        
        do {
            try manager.connection.startVPNTunnel(options: options)
            VPNLogger.shared.log("Network tunnel start initiated")
        } catch {
            tunnelStatus = .error
            VPNLogger.shared.log("Failed to start tunnel: \(error.localizedDescription)")
        }
    }
    
    func stopVPN() {
        guard let manager = vpnManager else { return }
        
        tunnelStatus = .disconnecting
        manager.connection.stopVPNTunnel()
        VPNLogger.shared.log("Network tunnel stop initiated")
    }
    
    deinit {
        if let observer = vpnObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @State private var showSettings = false
    @State var tunnel = false
    @AppStorage("autoConnect") private var autoConnect = false
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                StatusIndicatorView()
                
                ConnectionButton(
                    action: {
                        tunnelManager.tunnelStatus == .connected ? tunnelManager.stopVPN() : tunnelManager.startVPN()
                    }
                )
                
                Spacer()
                
                if tunnelManager.tunnelStatus == .connected {
                    ConnectionStatsView()
                }
            }
            .padding()
            .navigationTitle("StosVPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .foregroundColor(.primary)
                    }
                }
            }
            .onAppear() {
                if tunnelManager.tunnelStatus != .connected && autoConnect {
                    tunnelManager.startVPN()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $hasNotCompletedSetup) {
                SetupView()
            }
        }
    }
}


struct StatusIndicatorView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @State private var animationAmount = 1.0
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(tunnelManager.tunnelStatus.color.opacity(0.2), lineWidth: 20)
                    .frame(width: 200, height: 200)
                
                Circle()
                    .stroke(tunnelManager.tunnelStatus.color, lineWidth: 10)
                    .frame(width: 200, height: 200)
                    .scaleEffect(animationAmount)
                    .opacity(2 - animationAmount)
                    .animation(isAnimating ? Animation.easeOut(duration: 1.5).repeatForever(autoreverses: false) : .default, value: animationAmount)
                
                VStack(spacing: 10) {
                    Image(systemName: tunnelManager.tunnelStatus.systemImage)
                        .font(.system(size: 50))
                        .foregroundColor(tunnelManager.tunnelStatus.color)
                    
                    Text(tunnelManager.tunnelStatus.rawValue)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
            .onAppear {
                updateAnimation()
            }
            .onChange(of: tunnelManager.tunnelStatus) { _ in
                updateAnimation()
            }
            
            Text(tunnelManager.tunnelStatus == .connected ? "Local tunnel active" : "Local tunnel inactive")
                .font(.subheadline)
                .foregroundColor(tunnelManager.tunnelStatus == .connected ? .green : .secondary)
        }
    }
    
    private func updateAnimation() {
        switch tunnelManager.tunnelStatus {
        case .disconnecting:
            isAnimating = false
            withAnimation {
                animationAmount = 1.0
            }
        case .disconnected:
            isAnimating = false
            animationAmount = 1.0
        default:
            isAnimating = true
            animationAmount = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    animationAmount = 2.0
                }
            }
        }
    }
}


struct ConnectionButton: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(buttonText)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                if tunnelManager.tunnelStatus == .connecting || tunnelManager.tunnelStatus == .disconnecting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.leading, 5)
                }
            }
            .frame(width: 200, height: 50)
            .background(buttonBackground)
            .foregroundColor(.white)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
        .disabled(tunnelManager.tunnelStatus == .connecting || tunnelManager.tunnelStatus == .disconnecting)
    }
    
    private var buttonText: String {
        if tunnelManager.tunnelStatus == .connected {
            return "Disconnect"
        } else if tunnelManager.tunnelStatus == .connecting {
            return "Connecting..."
        } else if tunnelManager.tunnelStatus == .disconnecting {
            return "Disconnecting..."
        } else {
            return "Connect"
        }
    }
    
    private var buttonBackground: some View {
        Group {
            if tunnelManager.tunnelStatus == .connected {
                LinearGradient(
                    gradient: Gradient(colors: [Color.red.opacity(0.8), Color.red]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }
}

struct ConnectionStatsView: View {
    @State private var time = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 25) {
            Text("Local Tunnel Details")
                .font(.headline)
                .foregroundColor(.primary)
            
            HStack(spacing: 30) {
                StatItemView(
                    title: "Time Connected",
                    value: formattedTime,
                    icon: "clock.fill"
                )
                
                StatItemView(
                    title: "Status",
                    value: "Active",
                    icon: "checkmark.circle.fill"
                )
            }
            
            HStack(spacing: 30) {
                StatItemView(
                    title: "Network Interface",
                    value: "Local",
                    icon: "network"
                )
                
                StatItemView(
                    title: "Assigned IP",
                    value: "10.7.0.1",
                    icon: "number"
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.darkGray))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
        .onReceive(timer) { _ in
            time += 1
        }
    }
    
    var formattedTime: String {
        let minutes = (time / 60) % 60
        let hours = time / 3600
        let seconds = time % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct StatItemView: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Updated SettingsView
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("TunnelDeviceIP") private var deviceIP = "10.7.0.0"
    @AppStorage("TunnelFakeIP") private var fakeIP = "10.7.0.1"
    @AppStorage("TunnelSubnetMask") private var subnetMask = "255.255.255.0"
    @AppStorage("autoConnect") private var autoConnect = false
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Connection Settings")) {
                    Toggle("Auto-connect on Launch", isOn: $autoConnect)
                    
                    NavigationLink(destination: ConnectionLogView()) {
                        Label("Connection Logs", systemImage: "doc.text")
                    }
                }
                
                Section(header: Text("Network Configuration")) {
                    HStack {
                        Text("Device IP")
                        Spacer()
                        TextField("Device IP", text: $deviceIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    
                    HStack {
                        Text("Tunnel IP")
                        Spacer()
                        TextField("Tunnel IP", text: $fakeIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    
                    HStack {
                        Text("Subnet Mask")
                        Spacer()
                        TextField("Subnet Mask", text: $subnetMask)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
                    }
                }
                
                Section(header: Text("App Information")) {
                    NavigationLink(destination: PrivacyPolicyView()) {
                        Label("Privacy Policy", systemImage: "lock.shield")
                    }
                    
                    NavigationLink(destination: DataCollectionInfoView()) {
                        Label("Data Collection Policy", systemImage: "hand.raised.slash")
                    }
                    
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    NavigationLink(destination: HelpView()) {
                        Text("Help & Support")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - New Data Collection Info View
struct DataCollectionInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Data Collection Policy")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.bottom, 10)
                
                GroupBox(label: Label("No Data Collection", systemImage: "hand.raised.slash").font(.headline)) {
                    Text("StosVPN does NOT collect any user data, traffic information, or browsing activity. This app creates a purely local network tunnel that stays entirely on your device.")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("Local Processing Only", systemImage: "iphone").font(.headline)) {
                    Text("All network traffic and configurations are processed locally on your device. No information ever leaves your device or is transmitted over the internet.")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("No Third-Party Sharing", systemImage: "person.2.slash").font(.headline)) {
                    Text("Since we collect no data, there is no data shared with third parties. We have no analytics, tracking, or data collection mechanisms in this app.")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("Why Use Network Permissions", systemImage: "network").font(.headline)) {
                    Text("StosVPN requires network extension permissions to create a local network interface on your device. This is used exclusively for local development and testing purposes, such as connecting to local web servers for development.")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("Our Promise", systemImage: "checkmark.seal").font(.headline)) {
                    Text("We're committed to privacy and transparency. This app is designed for developers to test and connect to local servers on their device without any privacy concerns.")
                        .padding(.vertical)
                }
            }
            .padding()
        }
        .navigationTitle("Data Collection")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Updated ConnectionLogView
struct ConnectionLogView: View {
    @StateObject var logger = VPNLogger.shared
    var body: some View {
        List(logger.logs, id: \.self) { log in
            Text(log)
                .font(.system(.body, design: .monospaced))
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Updated PrivacyPolicyView
struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Privacy Policy")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.bottom, 10)
                
                Text("Last Updated: April 2, 2025")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
                
                GroupBox(label: Label("Overview", systemImage: "text.justify").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("StosVPN is designed exclusively to create a purely local network interface for iOS development and testing purposes. This app is fundamentally different from traditional VPN services:")
                            .padding(.vertical, 5)
                        
                        Text("• All network activity remains entirely on your device")
                        Text("• No external servers are involved in the operation of this app")
                        Text("• No internet traffic is routed through our servers or any third-party services")
                        Text("• The app functions entirely locally on your device")
                    }
                    .padding(.vertical)
                }
                
                GroupBox(label: Label("Zero Data Collection", systemImage: "lock.shield").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("StosVPN does NOT collect any data whatsoever, including:")
                            .fontWeight(.medium)
                            .padding(.bottom, 5)
                        
                        Text("• Personal information (name, email, phone number, address)")
                        Text("• Device identifiers (IP address, IDFA, IDFV, device name)")
                        Text("• Usage statistics or app analytics")
                        Text("• Network traffic data or browsing history")
                        Text("• Location information")
                        Text("• User content or files")
                        Text("• Network requests or connection details")
                        Text("• Technical device information")
                        
                        Text("We are committed to absolute zero data collection. No information of any kind is ever transmitted from your device, logged, or stored by our app.")
                            .fontWeight(.medium)
                            .padding(.top, 10)
                    }
                    .padding(.vertical)
                }
                
                GroupBox(label: Label("How StosVPN Works", systemImage: "gear").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Technical Implementation:")
                            .fontWeight(.medium)
                            .padding(.bottom, 5)
                        
                        Text("StosVPN uses Apple's Network Extension framework to create a local network interface directly on your device. This technology:")
                            .padding(.bottom, 5)
                        
                        Text("• Creates a virtual network adapter on your iOS device")
                        Text("• Configures this adapter with user-specified local IP addresses")
                        Text("• Enables routing between your apps and locally hosted servers")
                        Text("• Operates entirely within your device's memory")
                        Text("• Does not modify, intercept, or process any internet traffic")
                        
                        Text("This functionality is specifically designed for developers testing iOS applications that need to communicate with locally hosted web or API servers.")
                            .padding(.top, 10)
                    }
                    .padding(.vertical)
                }
                
                GroupBox(label: Label("Required Permissions", systemImage: "checkmark.shield").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("StosVPN requires network extension permissions for the sole purpose of creating a virtual network interface on your device.")
                            .padding(.bottom, 5)
                        
                        Text("Apple's Privacy Purpose String:")
                            .fontWeight(.medium)
                            .padding(.top, 5)
                        
                        Text("\"StosVPN requires network extension permissions to create a local virtual network interface used exclusively for development and testing. This permission is not used to monitor, collect, or transmit any user data.\"")
                            .italic()
                            .padding(.horizontal)
                            .padding(.vertical, 5)
                        
                        Text("These permissions are never used to:")
                            .fontWeight(.medium)
                            .padding(.top, 5)
                        
                        Text("• Monitor network traffic")
                        Text("• Access your browsing history")
                        Text("• Read or transmit personal information")
                        Text("• Track your location or device usage")
                    }
                    .padding(.vertical)
                }
                
                GroupBox(label: Label("No Third-Party Sharing", systemImage: "person.2.slash").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("StosVPN does not share data with third parties because:")
                            .padding(.bottom, 5)
                        
                        Text("• We collect absolutely no data")
                        Text("• The app contains no analytics frameworks")
                        Text("• No advertising or tracking SDKs are included")
                        Text("• No external servers are contacted during operation")
                        Text("• No cookies or other tracking technologies are used")
                        
                        Text("All functionality is implemented using Apple's native frameworks, with no third-party services or libraries that could potentially access user data.")
                            .padding(.top, 10)
                            .fontWeight(.medium)
                    }
                    .padding(.vertical)
                }
                
                GroupBox(label: Label("Children's Privacy", systemImage: "person.crop.circle").font(.headline)) {
                    Text("StosVPN is a developer tool and not intended for use by children under the age of 13. Since we do not collect any personal information from any users, including children, no special provisions are required to comply with children's privacy regulations.")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("Changes to This Policy", systemImage: "arrow.triangle.2.circlepath").font(.headline)) {
                    Text("While our commitment to zero data collection will never change, we may update this privacy policy to clarify our practices or reflect changes in functionality. Any updates will be clearly dated and communicated through app updates.")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("Contact Information", systemImage: "envelope").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("If you have any questions, concerns, or requests regarding this privacy policy or StosVPN, please contact us at:")
                            .padding(.bottom, 5)
                        
                        Text("privacy@stossvpn.com")
                            .fontWeight(.medium)
                        
                        Text("We are committed to addressing any questions or concerns you may have about our privacy practices or this app's functionality.")
                            .padding(.top, 10)
                    }
                    .padding(.vertical)
                }
                
                GroupBox(label: Label("Your Rights", systemImage: "person.text.rectangle").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Although we collect no personal data, you have the right to:")
                            .padding(.bottom, 5)
                        
                        Text("• Request information about our data practices")
                        Text("• Verify our zero-collection policy")
                        Text("• Remove the app and all its local configuration at any time")
                        
                        Text("Since all configuration is stored locally on your device, uninstalling the app removes all data created by StosVPN.")
                            .padding(.top, 10)
                    }
                    .padding(.vertical)
                }
                
                GroupBox(label: Label("Apple App Store Compliance", systemImage: "apple.logo").font(.headline)) {
                    Text("This app complies with all Apple App Store Review Guidelines, including guidelines 2.1 and 5.4 regarding data collection and VPN apps. StosVPN is a local development tool that uses VPN technology solely for creating a local network interface without any remote server connections or data collection.")
                        .padding(.vertical)
                }
            }
            .padding()
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Updated HelpView
struct HelpView: View {
    var body: some View {
        List {
            Section(header: Text("Frequently Asked Questions")) {
                NavigationLink("What does this app do?") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("StosVPN creates a local network interface that can be used for development and testing purposes. It does not route traffic through any external servers - everything stays on your device.")
                            .padding(.bottom, 10)
                        
                        Text("Common use cases include:")
                            .fontWeight(.medium)
                        
                        Text("• Testing web applications with local web servers")
                        Text("• Developing and debugging network-related features")
                        Text("• Accessing locally hosted development environments")
                        Text("• Testing applications that require specific network configurations")
                    }
                    .padding()
                }
                
                NavigationLink("Is this a traditional VPN?") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("No, StosVPN is NOT a traditional VPN service. It does not:")
                            .padding(.bottom, 10)
                            .fontWeight(.medium)
                        
                        Text("• Route your traffic through external servers")
                        Text("• Provide privacy or anonymity for internet browsing")
                        Text("• Connect to remote VPN servers")
                        Text("• Encrypt or route your internet traffic")
                        
                        Text("StosVPN only creates a local network interface on your device to help developers connect to local services and servers for testing and development purposes.")
                            .padding(.top, 10)
                    }
                    .padding()
                }
                
                NavigationLink("Why does the connection fail?") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Connection failures could be due to system permission issues, configuration errors, or iOS restrictions.")
                            .padding(.bottom, 10)
                        
                        Text("Troubleshooting steps:")
                            .fontWeight(.medium)
                        
                        Text("• Ensure you've approved the network extension permission")
                        Text("• Try restarting the app")
                        Text("• Check if your IP configuration is valid")
                        Text("• Restart your device if issues persist")
                    }
                    .padding()
                }
                
                NavigationLink("Who is this app for?") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("StosVPN is primarily designed for:")
                            .fontWeight(.medium)
                            .padding(.bottom, 10)
                        
                        Text("• Developers testing local web servers")
                        Text("• App developers testing network features")
                        Text("• QA engineers testing applications in isolated network environments")
                        Text("• Anyone who needs to access locally hosted services on their iOS device")
                        
                        Text("This app is available to the general public and is especially useful for developers who need to test applications with network features on iOS devices.")
                            .padding(.top, 10)
                    }
                    .padding()
                }
            }
            
            Section(header: Text("Business Model Information")) {
                NavigationLink("How does StosVPN work?") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("StosVPN is a completely free app available to the general public. There are no paid features, subscriptions, or in-app purchases.")
                            .padding(.bottom, 10)
                        
                        Text("Key points about our business model:")
                            .fontWeight(.medium)
                        
                        Text("• The app is not restricted to any specific company or group")
                        Text("• Anyone can download and use the app from the App Store")
                        Text("• No account creation is required to use the app")
                        Text("• All features are available to all users free of charge")
                        Text("• The app is developed and maintained as an open utility for the iOS development community")
                    }
                    .padding()
                }
            }
            
            Section(header: Text("App Information")) {
                HStack {
                    Image(systemName: "exclamationmark.shield")
                    Text("Requires iOS 16.0 or later")
                }
                
                HStack {
                    Image(systemName: "lock.shield")
                    Text("Uses Apple's Network Extension APIs")
                }
            }
        }
        .navigationTitle("Help & Support")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true
    @State private var currentPage = 0
    
    let pages = [
        SetupPage(
            title: "Welcome to StosVPN",
            description: "A simple local network tunnel for developers",
            imageName: "checkmark.shield.fill",
            details: "StosVPN creates a local network interface on your device for development, testing, and accessing local servers. This app does NOT collect any user data or route traffic through external servers."
        ),
        SetupPage(
            title: "Why Use StosVPN?",
            description: "Perfect for iOS developers",
            imageName: "person.2.fill",
            details: "• Access local web servers and development environments\n• Test applications that require specific network configurations\n• Connect to local network services without complex setup\n• Create isolated network environments for testing"
        ),
        SetupPage(
            title: "Easy to Use",
            description: "Just one tap to connect",
            imageName: "hand.tap.fill",
            details: "StosVPN is designed to be simple and straightforward. Just tap the connect button to establish a local network tunnel with pre-configured settings that work for most developer testing needs."
        ),
        SetupPage(
            title: "Privacy Focused",
            description: "Your data stays on your device",
            imageName: "lock.shield.fill",
            details: "StosVPN creates a local tunnel that doesn't route traffic through external servers. All network traffic remains on your device, ensuring your privacy and security. No data is collected or shared with third parties."
        )
    ]
    
    var body: some View {
        NavigationStack {
            VStack {
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        SetupPageView(page: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                
                Spacer()
                
                if currentPage == pages.count - 1 {
                    Button {
                        hasNotCompletedSetup = false
                        dismiss()
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                } else {
                    Button {
                        withAnimation {
                            currentPage += 1
                        }
                    } label: {
                        Text("Next")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        hasNotCompletedSetup = false
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SetupPage {
    let title: String
    let description: String
    let imageName: String
    let details: String
}

struct SetupPageView: View {
    let page: SetupPage
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: page.imageName)
                .font(.system(size: 80))
                .foregroundColor(.blue)
                .padding(.top, 50)
            
            Text(page.title)
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text(page.description)
                .font(.headline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            ScrollView {
                Text(page.details)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
