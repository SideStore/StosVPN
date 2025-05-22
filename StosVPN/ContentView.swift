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
    
    import SwiftUI

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
        
        var localizedTitle: String {
            switch self {
            case .disconnected:
                return NSLocalizedString("disconnected", comment: "")
            case .connecting:
                return NSLocalizedString("connecting", comment: "")
            case .connected:
                return NSLocalizedString("connected", comment: "")
            case .disconnecting:
                return NSLocalizedString("disconnecting", comment: "")
            case .error:
                return NSLocalizedString("error", comment: "")
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
                    // Look specifically for StosVPN manager
                    for manager in managers {
                        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                           proto.providerBundleIdentifier == self.tunnelBundleId {
                            self.vpnManager = manager
                            self.updateTunnelStatus(from: manager.connection.status)
                            VPNLogger.shared.log("Loaded existing StosVPN tunnel configuration")
                            break
                        }
                    }
                } else {
                    VPNLogger.shared.log("No existing tunnel configuration found")
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
            guard let self = self,
                  let connection = notification.object as? NEVPNConnection else {
                return
            }
            
            // Only update status if it's our VPN connection
            if let manager = self.vpnManager,
               connection == manager.connection {
                self.updateTunnelStatus(from: connection.status)
            }
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
            
            VPNLogger.shared.log("StosVPN status updated: \(self.tunnelStatus.rawValue)")
        }
    }
    
    private func createStosVPNConfiguration(completion: @escaping (NETunnelProviderManager?) -> Void) {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "StosVPN"
        
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = self.tunnelBundleId
        proto.serverAddress = NSLocalizedString("server_address_name", comment: "")
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
                return manager.connection.status == .connected ||
                       manager.connection.status == .connecting
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
        getActiveVPNManager { [weak self] activeManager in
            guard let self = self else { return }
            
            if let activeManager = activeManager,
               (activeManager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier != self.tunnelBundleId {
                VPNLogger.shared.log("Disconnecting existing VPN connection before starting StosVPN")
                
                // Set a flag to start StosVPN after disconnection
                UserDefaults.standard.set(true, forKey: "ShouldStartStosVPNAfterDisconnect")
                activeManager.connection.stopVPNTunnel()
                return
            }
            
            
            self.initializeAndStartStosVPN()
        }
    }
    
    private func initializeAndStartStosVPN() {
        if let manager = vpnManager {
            startExistingVPN(manager: manager)
        } else {
            createStosVPNConfiguration { [weak self] manager in
                guard let self = self, let manager = manager else { return }
                
                self.vpnManager = manager
                self.startExistingVPN(manager: manager)
            }
        }
    }
    
    private func startExistingVPN(manager: NETunnelProviderManager) {
        guard tunnelStatus != .connected else {
            VPNLogger.shared.log("StosVPN tunnel is already connected")
            return
        }
        
        manager.isEnabled = true
        manager.saveToPreferences { error in
            if let error = error {
                VPNLogger.shared.log(error.localizedDescription)
                return
            }
            
            // Reload it to apply
            manager.loadFromPreferences { error in
                if let error = error {
                    VPNLogger.shared.log(error.localizedDescription)
                    return
                }
                
                self.tunnelStatus = .connecting
                
                let options: [String: NSObject] = [
                    "TunnelDeviceIP": self.tunnelDeviceIp as NSObject,
                    "TunnelFakeIP": self.tunnelFakeIp as NSObject,
                    "TunnelSubnetMask": self.tunnelSubnetMask as NSObject
                ]
                
                do {
                    try manager.connection.startVPNTunnel(options: options)
                    VPNLogger.shared.log("StosVPN tunnel start initiated")
                } catch {
                    self.tunnelStatus = .error
                    VPNLogger.shared.log("Failed to start StosVPN tunnel: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func stopVPN() {
        guard let manager = vpnManager else { return }
        
        tunnelStatus = .disconnecting
        manager.connection.stopVPNTunnel()
        VPNLogger.shared.log("StosVPN tunnel stop initiated")
        
        UserDefaults.standard.removeObject(forKey: "ShouldStartStosVPNAfterDisconnect")
    }
    
    func handleVPNStatusChange(notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        
        if let manager = vpnManager, connection == manager.connection {
            updateTunnelStatus(from: connection.status)
            return
        }
        
        if connection.status == .disconnected &&
           UserDefaults.standard.bool(forKey: "ShouldStartStosVPNAfterDisconnect") {
            UserDefaults.standard.removeObject(forKey: "ShouldStartStosVPNAfterDisconnect")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.initializeAndStartStosVPN()
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
                    title: NSLocalizedString("time_connected", comment: ""),
                    value: formattedTime,
                    icon: "clock.fill"
                )
                StatItemView(
                    title: NSLocalizedString("status", comment: ""),
                    value: NSLocalizedString("active", comment: ""),
                    icon: "checkmark.circle.fill"
                )
            }
            HStack(spacing: 30) {
                StatItemView(
                    title: NSLocalizedString("network_interface", comment: ""),
                    value: NSLocalizedString("local", comment: ""),
                    icon: "network"
                )
                StatItemView(
                    title: NSLocalizedString("assigned_ip", comment: ""),
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
    @AppStorage("selectedLanguage") private var selectedLanguage = Locale.current.languageCode ?? "en"
    @AppStorage("TunnelDeviceIP") private var deviceIP = "10.7.0.0"
    @AppStorage("TunnelFakeIP") private var fakeIP = "10.7.0.1"
    @AppStorage("TunnelSubnetMask") private var subnetMask = "255.255.255.0"
    @AppStorage("autoConnect") private var autoConnect = false

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("connection_settings")) {
                    Toggle("auto_connect_on_launch", isOn: $autoConnect)
                    NavigationLink(destination: ConnectionLogView()) {
                        Label("connection_logs", systemImage: "doc.text")
                    }
                }

                Section(header: Text("network_configuration")) {
                    HStack {
                        Text("device_ip")
                        Spacer()
                        TextField("device_ip", text: $deviceIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Text("tunnel_ip")
                        Spacer()
                        TextField("tunnel_ip", text: $fakeIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Text("subnet_mask")
                        Spacer()
                        TextField("subnet_mask", text: $subnetMask)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
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
                        Text("1.1.0")
                            .foregroundColor(.secondary)
                    }
                    NavigationLink(destination: HelpView()) {
                        Text("help_and_support")
                    }
                }

                Section(header: Text("language")) {
                    Picker("language", selection: $selectedLanguage) {
                        Text("English").tag(0)
                        Text("Spanish").tag(1)
                        Text("Italian").tag(2)
                        Text("French").tag(3)
                    }
                    .onChange(of: selectedLanguage) { newValue in
                        let languageCode = ["en", "es", "it", "fr"][newValue]
                        LanguageManager().updateLanguage(to: languageCode)
                    }
                }
            }
            .navigationTitle(Text("settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") {
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
        .navigationBarTitleDisplayMode(.inline)
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
        .navigationBarTitleDisplayMode(.inline)
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
                            .fontWeight(.medium)
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
                            .fontWeight(.medium)
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
                            .fontWeight(.medium)
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
                            .fontWeight(.medium)
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
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
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
                        Text("setup_get_started")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
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
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                }
            }
            .navigationTitle(Text("setup_nav"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("setup_skip") { hasNotCompletedSetup = false; dismiss() }
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

class LanguageManager: ObservableObject {
    @Published var currentLanguage: String = Locale.current.languageCode ?? "en"
    
    private let supportedLanguages = ["en", "es", "it", "fr"]
    
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

#Preview {
    ContentView()
}