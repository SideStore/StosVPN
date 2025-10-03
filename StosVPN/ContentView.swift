//
//  ContentView.swift
//  StosVPN
//
//  Created by Stossy11 on 28/03/2025.
//

import SwiftUI
import Foundation
import NetworkExtension

import NavigationBackport

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var tunnelBundleID: String { bundleIdentifier!.appending(".TunnelProv") }
}

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

// MARK: - Tunnel Manager
class TunnelManager: ObservableObject {
    @Published var hasLocalDeviceSupport = false
    @Published var tunnelStatus: TunnelStatus = .disconnected
    
    static var shared = TunnelManager()
    
    @Published var waitingOnSettings: Bool = false
    @Published var vpnManager: NETunnelProviderManager?
    private var vpnObserver: NSObjectProtocol?
    private var isProcessingStatusChange = false
    
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
    
    enum TunnelStatus {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case error
        
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
        
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .disconnected:
                return "disconnected"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            case .disconnecting:
                return "disconnecting"
            case .error:
                return "error"
            }
        }
    }
    
    private init() {
        setupStatusObserver()
        loadTunnelPreferences()
    }
    
    // MARK: - Private Methods
    private func loadTunnelPreferences() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    VPNLogger.shared.log("Error loading preferences: \(error.localizedDescription)")
                    self.tunnelStatus = .error
                    self.waitingOnSettings = true
                    return
                }
                
                self.hasLocalDeviceSupport = true
                self.waitingOnSettings = true
                
                if let managers = managers, !managers.isEmpty {
                    let stosManagers = managers.filter { manager in
                        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                            return false
                        }
                        return proto.providerBundleIdentifier == self.tunnelBundleId
                    }
                    
                    if !stosManagers.isEmpty {
                        if stosManagers.count > 1 {
                            self.cleanupDuplicateManagers(stosManagers)
                        } else if let manager = stosManagers.first {
                            self.vpnManager = manager
                            let currentStatus = manager.connection.status
                            VPNLogger.shared.log("Loaded existing StosVPN tunnel configuration with status: \(currentStatus.rawValue)")
                            self.updateTunnelStatus(from: currentStatus)
                        }
                    } else {
                        VPNLogger.shared.log("No StosVPN tunnel configuration found")
                    }
                } else {
                    VPNLogger.shared.log("No existing tunnel configurations found")
                }
            }
        }
    }
    
    private func cleanupDuplicateManagers(_ managers: [NETunnelProviderManager]) {
        VPNLogger.shared.log("Found \(managers.count) StosVPN configurations. Cleaning up duplicates...")
        
        let activeManager = managers.first {
            $0.connection.status == .connected || $0.connection.status == .connecting
        }
        
        let managerToKeep = activeManager ?? managers.first!
        
        DispatchQueue.main.async { [weak self] in
            self?.vpnManager = managerToKeep
            self?.updateTunnelStatus(from: managerToKeep.connection.status)
        }
        
        for manager in managers where manager != managerToKeep {
            manager.removeFromPreferences { error in
                if let error = error {
                    VPNLogger.shared.log("Error removing duplicate VPN: \(error.localizedDescription)")
                } else {
                    VPNLogger.shared.log("Successfully removed duplicate VPN configuration")
                }
            }
        }
    }
    
    private func setupStatusObserver() {
        vpnObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let connection = notification.object as? NEVPNConnection else { return }
            
            VPNLogger.shared.log("VPN Status notification received: \(connection.status.rawValue)")
            
            // Update status immediately if it's our manager
            if let manager = self.vpnManager, connection == manager.connection {
                self.updateTunnelStatus(from: connection.status)
            }
            
            self.handleVPNStatusChange(notification: notification)
        }
    }
    
    private func updateTunnelStatus(from connectionStatus: NEVPNStatus) {
        let newStatus: TunnelStatus
        switch connectionStatus {
        case .invalid, .disconnected:
            newStatus = .disconnected
        case .connecting:
            newStatus = .connecting
        case .connected:
            newStatus = .connected
        case .disconnecting:
            newStatus = .disconnecting
        case .reasserting:
            newStatus = .connecting
        @unknown default:
            newStatus = .error
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.tunnelStatus != newStatus {
                VPNLogger.shared.log("StosVPN status updated from \(self.tunnelStatus) to \(newStatus)")
            }
            self.tunnelStatus = newStatus
        }
    }
    
    private func createStosVPNConfiguration(completion: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
            guard let self = self else {
                completion(nil)
                return
            }
            
            if let error = error {
                VPNLogger.shared.log("Error checking existing VPN configurations: \(error.localizedDescription)")
                completion(nil)
                return
            }
            
            if let managers = managers {
                let stosManagers = managers.filter { manager in
                    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                        return false
                    }
                    return proto.providerBundleIdentifier == self.tunnelBundleId
                }
                
                if let existingManager = stosManagers.first {
                    VPNLogger.shared.log("Found existing StosVPN configuration, using it instead of creating new one")
                    completion(existingManager)
                    return
                }
            }
            
            let manager = NETunnelProviderManager()
            manager.localizedDescription = "StosVPN"
            
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleId
            proto.serverAddress = "StosVPN's Local Network Tunnel"
            manager.protocolConfiguration = proto
            
            let onDemandRule = NEOnDemandRuleEvaluateConnection()
            onDemandRule.interfaceTypeMatch = .any
            onDemandRule.connectionRules = [NEEvaluateConnectionRule(
                matchDomains: ["10.7.0.0", "10.7.0.1"],
                andAction: .connectIfNeeded
            )]
            
            manager.onDemandRules = [onDemandRule]
            manager.isOnDemandEnabled = true
            manager.isEnabled = true
            
            manager.saveToPreferences { error in
                DispatchQueue.main.async {
                    if let error = error {
                        VPNLogger.shared.log("Error creating StosVPN configuration: \(error.localizedDescription)")
                        completion(nil)
                        return
                    }
                    
                    VPNLogger.shared.log("StosVPN configuration created successfully")
                    completion(manager)
                }
            }
        }
    }
    
    private func getActiveVPNManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                VPNLogger.shared.log("Error loading VPN configurations: \(error.localizedDescription)")
                completion(nil)
                return
            }
            
            guard let managers = managers else {
                completion(nil)
                return
            }
            
            let activeManager = managers.first { manager in
                manager.connection.status == .connected || manager.connection.status == .connecting
            }
            
            completion(activeManager)
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
            let currentStatus = manager.connection.status
            VPNLogger.shared.log("Current manager status: \(currentStatus.rawValue)")
            
            if currentStatus == .connected {
                VPNLogger.shared.log("VPN already connected, updating UI")
                DispatchQueue.main.async { [weak self] in
                    self?.tunnelStatus = .connected
                }
                return
            }
            
            if currentStatus == .connecting {
                VPNLogger.shared.log("VPN already connecting, updating UI")
                DispatchQueue.main.async { [weak self] in
                    self?.tunnelStatus = .connecting
                }
                return
            }
        }
        
        getActiveVPNManager { [weak self] activeManager in
            guard let self = self else { return }
            
            if let activeManager = activeManager,
               (activeManager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier != self.tunnelBundleId {
                VPNLogger.shared.log("Disconnecting existing VPN connection before starting StosVPN")
                
                UserDefaults.standard.set(true, forKey: "ShouldStartStosVPNAfterDisconnect")
                activeManager.connection.stopVPNTunnel()
                return
            }
            
            self.initializeAndStartStosVPN()
        }
    }
    
    private func initializeAndStartStosVPN() {
        if let manager = vpnManager {
            manager.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                
                if let error = error {
                    VPNLogger.shared.log("Error reloading manager: \(error.localizedDescription)")
                    self.createAndStartVPN()
                    return
                }
                
                self.startExistingVPN(manager: manager)
            }
        } else {
            createAndStartVPN()
        }
    }
    
    private func createAndStartVPN() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                VPNLogger.shared.log("Error reloading VPN configurations: \(error.localizedDescription)")
            }
            
            if let managers = managers {
                let stosManagers = managers.filter { manager in
                    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                        return false
                    }
                    return proto.providerBundleIdentifier == self.tunnelBundleId
                }
                
                if !stosManagers.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.vpnManager = stosManagers.first
                    }
                    
                    if stosManagers.count > 1 {
                        self.cleanupDuplicateManagers(stosManagers)
                    }
                    
                    if let manager = stosManagers.first {
                        self.startExistingVPN(manager: manager)
                    }
                    return
                }
            }
            
            self.createStosVPNConfiguration { [weak self] manager in
                guard let self = self, let manager = manager else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.vpnManager = manager
                }
                self.startExistingVPN(manager: manager)
            }
        }
    }
    
    private func startExistingVPN(manager: NETunnelProviderManager) {
        // First check the actual current status
        let currentStatus = manager.connection.status
        VPNLogger.shared.log("Current VPN status before start attempt: \(currentStatus.rawValue)")
        
        if currentStatus == .connected {
            VPNLogger.shared.log("StosVPN tunnel is already connected")
            DispatchQueue.main.async { [weak self] in
                self?.tunnelStatus = .connected
            }
            return
        }
        
        if currentStatus == .connecting {
            VPNLogger.shared.log("StosVPN tunnel is already connecting")
            DispatchQueue.main.async { [weak self] in
                self?.tunnelStatus = .connecting
            }
            return
        }
        
        manager.isEnabled = true
        manager.saveToPreferences { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                VPNLogger.shared.log("Error saving preferences: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.tunnelStatus = .error
                }
                return
            }
            
            manager.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                
                if let error = error {
                    VPNLogger.shared.log("Error reloading preferences: \(error.localizedDescription)")
                    DispatchQueue.main.async { [weak self] in
                        self?.tunnelStatus = .error
                    }
                    return
                }
                
                // Check status again after reload
                let statusAfterReload = manager.connection.status
                VPNLogger.shared.log("VPN status after reload: \(statusAfterReload.rawValue)")
                
                if statusAfterReload == .connected {
                    VPNLogger.shared.log("VPN is already connected after reload")
                    DispatchQueue.main.async { [weak self] in
                        self?.tunnelStatus = .connected
                    }
                    return
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.tunnelStatus = .connecting
                }
                
                let options: [String: NSObject] = [
                    "TunnelDeviceIP": self.tunnelDeviceIp as NSObject,
                    "TunnelFakeIP": self.tunnelFakeIp as NSObject,
                    "TunnelSubnetMask": self.tunnelSubnetMask as NSObject
                ]
                
                do {
                    try manager.connection.startVPNTunnel(options: options)
                    VPNLogger.shared.log("StosVPN tunnel start initiated")
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.tunnelStatus = .error
                    }
                    VPNLogger.shared.log("Failed to start StosVPN tunnel: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func stopVPN() {
        guard let manager = vpnManager else {
            VPNLogger.shared.log("No VPN manager available to stop")
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.tunnelStatus = .disconnecting
        }
        
        manager.connection.stopVPNTunnel()
        VPNLogger.shared.log("StosVPN tunnel stop initiated")
        
        UserDefaults.standard.removeObject(forKey: "ShouldStartStosVPNAfterDisconnect")
    }
    
    func handleVPNStatusChange(notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        
        VPNLogger.shared.log("Handling VPN status change: \(connection.status.rawValue)")
        
        // Always update status if it's our manager's connection
        if let manager = vpnManager, connection == manager.connection {
            VPNLogger.shared.log("Status change is for our StosVPN manager")
            updateTunnelStatus(from: connection.status)
        }
        
        if connection.status == .disconnected &&
           UserDefaults.standard.bool(forKey: "ShouldStartStosVPNAfterDisconnect") {
            UserDefaults.standard.removeObject(forKey: "ShouldStartStosVPNAfterDisconnect")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.initializeAndStartStosVPN()
            }
            return
        }
        
        // Prevent recursive calls when checking for duplicates
        guard !isProcessingStatusChange else { return }
        isProcessingStatusChange = true
        
        // Check for duplicates asynchronously without blocking
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
                guard let self = self, let managers = managers, !managers.isEmpty else {
                    DispatchQueue.main.async { [weak self] in
                        self?.isProcessingStatusChange = false
                    }
                    return
                }
                
                let stosManagers = managers.filter { manager in
                    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                        return false
                    }
                    return proto.providerBundleIdentifier == self.tunnelBundleId
                }
                
                if stosManagers.count > 1 {
                    DispatchQueue.main.async { [weak self] in
                        self?.cleanupDuplicateManagers(stosManagers)
                    }
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.isProcessingStatusChange = false
                }
            }
        }
    }
    
    // MARK: - Cleanup Utilities
    
    func cleanupAllVPNConfigurations() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                VPNLogger.shared.log("Error loading VPN configurations for cleanup: \(error.localizedDescription)")
                return
            }
            
            guard let managers = managers else { return }
            
            for manager in managers {
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                      proto.providerBundleIdentifier == self.tunnelBundleId else {
                    continue
                }
                
                if manager.connection.status == .connected || manager.connection.status == .connecting {
                    manager.connection.stopVPNTunnel()
                }
                
                manager.removeFromPreferences { error in
                    if let error = error {
                        VPNLogger.shared.log("Error removing VPN configuration: \(error.localizedDescription)")
                    } else {
                        VPNLogger.shared.log("Successfully removed VPN configuration")
                    }
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.vpnManager = nil
                self?.tunnelStatus = .disconnected
            }
        }
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
        NBNavigationStack {
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
            .tvOSNavigationBarTitleDisplayMode(.inline)
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
            .onChange(of: tunnelManager.waitingOnSettings) { finished in
                if tunnelManager.tunnelStatus != .connected && autoConnect && finished {
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

extension View {
    @ViewBuilder
    func tvOSNavigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(displayMode)
        #else
        self
        #endif
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
                    
                    Text(tunnelManager.tunnelStatus.localizedTitle)
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
            Text(tunnelManager.tunnelStatus == .connected ? 
                NSLocalizedString("local_tunnel_active", comment: "") : 
                NSLocalizedString("local_tunnel_inactive", comment: ""))
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
        switch tunnelManager.tunnelStatus {
        case .connected:
            return NSLocalizedString("disconnect", comment: "")
        case .connecting:
            return NSLocalizedString("connecting_ellipsis", comment: "")
        case .disconnecting:
            return NSLocalizedString("disconnecting_ellipsis", comment: "")
        default:
            return NSLocalizedString("connect", comment: "")
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
            Text("local_tunnel_details")
                .font(.headline)
                .foregroundColor(.primary)
            HStack(spacing: 30) {
                StatItemView(
                    title: "time_connected",
                    value: formattedTime,
                    icon: "clock.fill"
                )
                StatItemView(
                    title: "status",
                    value: "active",
                    icon: "checkmark.circle.fill"
                )
            }
            HStack(spacing: 30) {
                StatItemView(
                    title: "network_interface",
                    value: "local",
                    icon: "network"
                )
                StatItemView(
                    title: "assigned_ip",
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
    let title: LocalizedStringKey
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
    @Environment(\.presentationMode) var presentationMode
    @AppStorage("selectedLanguage") private var selectedLanguage = Locale.current.languageCode ?? "en"
    @AppStorage("TunnelDeviceIP") private var deviceIP = "10.7.0.0"
    @AppStorage("TunnelFakeIP") private var fakeIP = "10.7.0.1"
    @AppStorage("TunnelSubnetMask") private var subnetMask = "255.255.255.0"
    @AppStorage("autoConnect") private var autoConnect = false
    @AppStorage("shownTunnelAlert") private var shownTunnelAlert = false
    @StateObject private var tunnelManager = TunnelManager.shared
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true

    @State private var showNetworkWarning = false
    
    var body: some View {
        NBNavigationStack {
            List {
                Section(header: Text("connection_settings")) {
                    Toggle("auto_connect_on_launch", isOn: $autoConnect)
                    NavigationLink(destination: ConnectionLogView()) {
                        Label("connection_logs", systemImage: "doc.text")
                    }
                }

                Section(header: Text("network_configuration")) {
                    Group {
                        networkConfigRow(label: "tunnel_ip", text: $deviceIP)
                        networkConfigRow(label: "device_ip", text: $fakeIP)
                        networkConfigRow(label: "subnet_mask", text: $subnetMask)
                    }
                }

                Section(header: Text("app_information")) {
                    Button {
                        UIApplication.shared.open(URL(string: "https://github.com/stossy11/PrivacyPolicy/blob/main/PrivacyPolicy.md")!, options: [:])
                    } label: {
                        Label("privacy_policy", systemImage: "lock.shield")
                    }
                    NavigationLink(destination: DataCollectionInfoView()) {
                        Label("data_collection_policy", systemImage: "hand.raised.slash")
                    }
                    HStack {
                        Text("app_version")
                        Spacer()
                        Text(Bundle.main.shortVersion)
                            .foregroundColor(.secondary)
                    }
                    NavigationLink(destination: HelpView()) {
                        Text("help_and_support")
                    }
                }

                Section(header: Text("language")) {
                    Picker("language", selection: $selectedLanguage) {
                        Text("English").tag("en")
                        Text("Spanish").tag("es")
                        Text("Italian").tag("it")
                        Text("Polish").tag("pl")
                    }
                    .onChange(of: selectedLanguage) { newValue in
                        let languageCode = newValue
                        LanguageManager.shared.updateLanguage(to: languageCode)
                    }
                }
            }
            .alert(isPresented: $showNetworkWarning) {
                Alert(
                    title: Text("warning_alert"),
                    message: Text("warning_message"),
                    dismissButton: .cancel(Text("understand_button")) {
                        shownTunnelAlert = true
                        
                        deviceIP = "10.7.0.0"
                        fakeIP = "10.7.0.1"
                        subnetMask = "255.255.255.0"
                    }
                )
            }
            .navigationTitle(Text("settings"))
            .tvOSNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
    
    private func networkConfigRow(label: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.secondary)
                .keyboardType(.numbersAndPunctuation)
                .onChange(of: text.wrappedValue) { newValue in
                    if !shownTunnelAlert {
                        showNetworkWarning = true
                    }
                    
                    tunnelManager.vpnManager?.saveToPreferences { error in
                        if let error = error {
                            VPNLogger.shared.log(error.localizedDescription)
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
                Text("data_collection_policy_title")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.bottom, 10)
                
                GroupBox(label: Label("no_data_collection", systemImage: "hand.raised.slash").font(.headline)) {
                    Text("no_data_collection_description")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("local_processing_only", systemImage: "iphone").font(.headline)) {
                    Text("local_processing_only_description")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("no_third_party_sharing", systemImage: "person.2.slash").font(.headline)) {
                    Text("no_third_party_sharing_description")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("why_use_network_permissions", systemImage: "network").font(.headline)) {
                    Text("why_use_network_permissions_description")
                        .padding(.vertical)
                }
                
                GroupBox(label: Label("our_promise", systemImage: "checkmark.seal").font(.headline)) {
                    Text("our_promise_description")
                        .padding(.vertical)
                }
            }
            .padding()
        }
        .navigationTitle(Text("data_collection_policy_nav"))
        .tvOSNavigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionLogView: View {
    @StateObject var logger = VPNLogger.shared
    var body: some View {
        List(logger.logs, id: \.self) { log in
            Text(log)
                .font(.system(.body, design: .monospaced))
        }
        .navigationTitle(Text("logs_nav"))
        .tvOSNavigationBarTitleDisplayMode(.inline)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section(header: Text("faq_header")) {
                NavigationLink("faq_q1") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("faq_q1_a1")
                            .padding(.bottom, 10)
                        Text("faq_common_use_cases")
                            .fontWeight(.medium)
                        Text("faq_case1")
                        Text("faq_case2")
                        Text("faq_case3")
                        Text("faq_case4")
                    }
                    .padding()
                }
                NavigationLink("faq_q2") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("faq_q2_a1")
                            .padding(.bottom, 10)
                            .font(.headline)
                        Text("faq_q2_point1")
                        Text("faq_q2_point2")
                        Text("faq_q2_point3")
                        Text("faq_q2_point4")
                        Text("faq_q2_a2")
                            .padding(.top, 10)
                    }
                    .padding()
                }
                NavigationLink("faq_q3") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("faq_q3_a1")
                            .padding(.bottom, 10)
                        Text("faq_troubleshoot_header")
                            .font(.headline)
                        Text("faq_troubleshoot1")
                        Text("faq_troubleshoot2")
                        Text("faq_troubleshoot3")
                        Text("faq_troubleshoot4")
                    }
                    .padding()
                }
                NavigationLink("faq_q4") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("faq_q4_intro")
                            .font(.headline)
                            .padding(.bottom, 10)
                        Text("faq_q4_case1")
                        Text("faq_q4_case2")
                        Text("faq_q4_case3")
                        Text("faq_q4_case4")
                        Text("faq_q4_conclusion")
                            .padding(.top, 10)
                    }
                    .padding()
                }
            }
            Section(header: Text("business_model_header")) {
                NavigationLink("biz_q1") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("biz_q1_a1")
                            .padding(.bottom, 10)
                        Text("biz_key_points_header")
                            .font(.headline)
                        Text("biz_point1")
                        Text("biz_point2")
                        Text("biz_point3")
                        Text("biz_point4")
                        Text("biz_point5")
                    }
                    .padding()
                }
            }
            Section(header: Text("app_info_header")) {
                HStack {
                    Image(systemName: "exclamationmark.shield")
                    Text("requires_ios")
                }
                HStack {
                    Image(systemName: "lock.shield")
                    Text("uses_network_extension")
                }
            }
        }
        .navigationTitle(Text("help_and_support_nav"))
        .tvOSNavigationBarTitleDisplayMode(.inline)
    }
}

struct SetupView: View {
    @Environment(\.presentationMode) var presentationMode
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true
    @State private var currentPage = 0
    let pages = [
        SetupPage(
            title: "setup_welcome_title",
            description: "setup_welcome_description",
            imageName: "checkmark.shield.fill",
            details: "setup_welcome_details"
        ),
        SetupPage(
            title: "setup_why_title",
            description: "setup_why_description",
            imageName: "person.2.fill",
            details: "setup_why_details"
        ),
        SetupPage(
            title: "setup_easy_title",
            description: "setup_easy_description",
            imageName: "hand.tap.fill",
            details: "setup_easy_details"
        ),
        SetupPage(
            title: "setup_privacy_title",
            description: "setup_privacy_description",
            imageName: "lock.shield.fill",
            details: "setup_privacy_details"
        )
    ]
    var body: some View {
        NBNavigationStack {
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
                        Text("setup_get_started")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                } else {
                    Button {
                        withAnimation { currentPage += 1 }
                    } label: {
                        Text("setup_next")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                }

            }
            .navigationTitle(Text("setup_nav"))
            .tvOSNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("setup_skip") { hasNotCompletedSetup = false; dismiss() }
                }
            }
        }
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
      }
}

struct SetupPage {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let imageName: String
    let details: LocalizedStringKey
}

struct SetupPageView: View {
    let page: SetupPage
    
    var body: some View {
        VStack(spacing: tvOSSpacing) {
            Image(systemName: page.imageName)
                .font(.system(size: tvOSImageSize))
                .foregroundColor(.blue)
                .padding(.top, tvOSTopPadding)
            
            Text(page.title)
                .font(tvOSTitleFont)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text(page.description)
                .font(tvOSDescriptionFont)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            ScrollView {
                Text(page.details)
                    .font(tvOSBodyFont)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Conditional sizes for tvOS
    private var tvOSImageSize: CGFloat {
        #if os(tvOS)
        return 60
        #else
        return 80
        #endif
    }
    
    private var tvOSTopPadding: CGFloat {
        #if os(tvOS)
        return 30
        #else
        return 50
        #endif
    }
    
    private var tvOSSpacing: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 30
        #endif
    }
    
    private var tvOSTitleFont: Font {
        #if os(tvOS)
        return .headline //.system(size: 35).bold()
        #else
        return .title
        #endif
    }
    
    private var tvOSDescriptionFont: Font {
        #if os(tvOS)
        return .subheadline
        #else
        return .headline
        #endif
    }
    
    private var tvOSBodyFont: Font {
        #if os(tvOS)
        return .system(size: 18).bold()
        #else
        return .body
        #endif
    }
}


class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var currentLanguage: String = Locale.current.languageCode ?? "en"
    
    private let supportedLanguages = ["en", "es", "it", "pl"]
    
    func updateLanguage(to languageCode: String) {
        if supportedLanguages.contains(languageCode) {
            currentLanguage = languageCode
            UserDefaults.standard.set([languageCode], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        } else {
            currentLanguage = "en" //FALLBACK TO DEFAULT LANGUAGE
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
    }
}

#if os(tvOS)
@ViewBuilder
func GroupBox<Content: View>(
    label: some View,
    @ViewBuilder content: @escaping () -> Content
) -> some View {
    #if os(tvOS)
    tvOSGroupBox(label: {
        label
    }, content: content)
    #else
    SwiftUI.GroupBox(label: label, content: content)
    #endif
}

struct tvOSGroupBox<Label: View, Content: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    init(
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label()
                .font(.headline)
            
            content()
                .padding(.top, 4)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
    }
}
#endif

#Preview {
    ContentView()
}
