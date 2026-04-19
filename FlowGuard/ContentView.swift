//
//  ContentView.swift
//  FlowGuard
//
//  Created by uvays on 28.03.2026.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var copiedLogs = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Tunnel") {
                    HStack {
                        Text("State")
                        Spacer()
                        Text(viewModel.providerState.rawValue.capitalized)
                            .foregroundStyle(.secondary)
                    }

                    Stepper(
                        "SOCKS5 Port: \(viewModel.profile.socksPort)",
                        value: $viewModel.profile.socksPort,
                        in: 1025...65535
                    )

                    Picker("DNS Mode", selection: $viewModel.profile.dnsMode) {
                        ForEach(DNSMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Picker("Preset", selection: $viewModel.profile.preset) {
                        ForEach(ByeDPIPreset.allCases, id: \.self) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Toggle("Enable IPv6", isOn: $viewModel.profile.ipv6Enabled)
                }

                Section("Actions") {
                    Button("Install Configuration") {
                        viewModel.installConfiguration()
                    }
                    .disabled(viewModel.isBusy)

                    Button("Save Profile") {
                        viewModel.saveProfile()
                    }

                    Button("Load Profile") {
                        viewModel.loadProfileFromDisk()
                    }

                    Button("Connect") {
                        viewModel.connect()
                    }
                    .disabled(viewModel.isBusy)

                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnect()
                    }
                    .disabled(viewModel.isBusy)

                    Button("Reload In Provider") {
                        viewModel.reloadProfileInProvider()
                    }
                    .disabled(viewModel.isBusy)

                    Button("Request Stats") {
                        viewModel.requestStats()
                    }

                    Button("Fetch Provider Logs") {
                        viewModel.refreshLogsFromProvider()
                    }
                    .disabled(viewModel.isBusy)

                    Button("Refresh Disk Logs") {
                        viewModel.refreshLogsFromDisk()
                    }
                }

                Section("Runtime Stats") {
                    LabeledContent("Uptime", value: "\(Int(viewModel.runtimeStats.uptimeSeconds))s")
                    LabeledContent("Bytes In", value: "\(viewModel.runtimeStats.bytesIn)")
                    LabeledContent("Bytes Out", value: "\(viewModel.runtimeStats.bytesOut)")
                    LabeledContent("Preset", value: viewModel.runtimeStats.selectedPreset.rawValue)
                    if let lastError = viewModel.runtimeStats.lastError {
                        Text(lastError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Runtime Logs") {
                    HStack {
                        Button("Copy Logs") {
                            copyLogsToClipboard()
                        }
                        Spacer()
                        if copiedLogs {
                            Text("Copied")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ScrollView {
                        Text(viewModel.logPreview)
                            .font(.footnote.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160)
                }

                Section("Status") {
                    Text(viewModel.statusMessage)
                }
            }
            .navigationTitle("FlowGuard")
        }
    }

    private func copyLogsToClipboard() {
        #if canImport(UIKit)
        UIPasteboard.general.string = viewModel.logPreview
        #endif
        copiedLogs = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copiedLogs = false
        }
    }
}

private extension DNSMode {
    var title: String {
        switch self {
        case .system:
            return "System"
        case .doh:
            return "DoH"
        case .plain:
            return "Plain"
        }
    }
}

private extension ByeDPIPreset {
    var title: String {
        switch self {
        case .conservative:
            return "Conservative"
        case .balanced:
            return "Balanced"
        case .aggressive:
            return "Aggressive"
        case .forYoutube:
            return "For Youtube"
        case .strategyBasicTorst:
            return "Strategy: Basic (torst)"
        case .strategyYoutubeStable:
            return "Strategy: YouTube Stable"
        case .strategyLinuxFakeMD5:
            return "Strategy: Linux fake+md5"
        case .strategyWindowsSplitFake:
            return "Strategy: Windows split+fake"
        }
    }
}

#Preview {
    ContentView()
}
