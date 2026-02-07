//
//  ContentView.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/14.
//

import SwiftUI
import Foundation
import CoreBluetooth
import ExternalAccessory

struct ContentView: View {
    @StateObject private var viewModel = BrainwaveViewModel()
    
    var body: some View {
        TabView {
            // 設備管理頁面
            NavigationView {
                DeviceListView(
                    viewModel: viewModel,
                    bluetoothManager: viewModel.bluetoothManager,
                    mindLinkManager: viewModel.mindLinkManager,
                    onDeviceSelected: { peripheral in
                        viewModel.connect(to: peripheral)
                    },
                    onMindLinkSelected: { accessory in
                        viewModel.mindLinkManager.connect(to: accessory)
                    }
                )
                .navigationTitle("腦波設備")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        MindLinkStatusBadge(
                            isConnected: viewModel.mindLinkManager.isConnected,
                            connectionState: viewModel.mindLinkManager.connectionState,
                            isReceivingEEG: viewModel.isReceivingEEG,
                            signalQuality: viewModel.signalQuality
                        )
                    }
                }
            }
            .tabItem {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text("設備")
            }
            
            // 合併後的「數據」頁面（移除完整波形以降低延遲）
            NavigationView {
                CombinedDataWaveformView(viewModel: viewModel)
                    .navigationTitle("實時數據")
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            HistoryButton(sessions: viewModel.recordedSessions)
                            MindLinkStatusBadge(
                                isConnected: viewModel.mindLinkManager.isConnected,
                                connectionState: viewModel.mindLinkManager.connectionState,
                                isReceivingEEG: viewModel.isReceivingEEG,
                                signalQuality: viewModel.signalQuality
                            )
                        }
                    }
            }
            .tabItem {
                Image(systemName: "waveform.path.ecg")
                Text("數據")
            }
            
            // 設置頁面（保留：模擬數據、錄製歷史、應用信息）
            NavigationView {
                SettingsView(viewModel: viewModel)
                    .navigationTitle("設置")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            MindLinkStatusBadge(
                                isConnected: viewModel.mindLinkManager.isConnected,
                                connectionState: viewModel.mindLinkManager.connectionState,
                                isReceivingEEG: viewModel.isReceivingEEG,
                                signalQuality: viewModel.signalQuality
                            )
                        }
                    }
            }
            .tabItem {
                Image(systemName: "gearshape")
                Text("設置")
            }
        }
        .preferredColorScheme(.light)
    }
}

// 右上角的全域狀態燈元件（小尺寸）
struct MindLinkStatusBadge: View {
    let isConnected: Bool
    let connectionState: MindLinkManager.ConnectionState
    let isReceivingEEG: Bool
    let signalQuality: Int?
    
    private var color: Color {
        if !isConnected { return .red }                 // 未連接
        switch connectionState {
        case .connecting: return .yellow               // 連接中
        case .connected:
            if isReceivingEEG {
                return .green                          // 有腦波
            } else if signalQuality == 200 {
                return .orange                         // 無腦波（接觸不良）
            } else {
                return .yellow                         // 已連接但初始化/暫無資料
            }
        case .error(_): return .red
        case .disconnected: return .red
        }
    }
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .accessibilityLabel(Text(accessibilityText))
    }
    
    private var accessibilityText: String {
        if !isConnected { return "未連接" }
        switch connectionState {
        case .connecting: return "連接中"
        case .connected:
            if isReceivingEEG { return "接收腦波中" }
            if signalQuality == 200 { return "未偵測到腦波" }
            return "已連接"
        case .error(_): return "連接錯誤"
        case .disconnected: return "未連接"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: BrainwaveViewModel
    @State private var showingSessionHistory = false
    
    var body: some View {
        List {
            // 模擬數據
            Section("模擬數據") {
                Toggle("啟用模擬數據", isOn: $viewModel.simulationEnabled)
                    .onChange(of: viewModel.simulationEnabled) { _, enabled in
                        print("🔄 [UI] 模擬數據開關切換: \(enabled)")
                        if enabled {
                            viewModel.enableSimulation()
                        } else {
                            viewModel.disableSimulation()
                        }
                    }
                Toggle("分析 Raw 產生 8 波（模擬）", isOn: $viewModel.simulateAnalysisFromRaw)
                    .onChange(of: viewModel.simulateAnalysisFromRaw) { _, enabled in
                        print("🔄 [UI] Raw 分析開關切換: \(enabled)")
                    }
                Text("開啟後，模擬資料不再直接注入 8 段能量，而是先將 Raw 樣本送入分析器，由分析器計算頻段能量。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("注意：此為示意計算，用於 UI 驗證。實機可優先使用 ThinkGear 0x83 八段能量。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // 錄製歷史
            Section("錄製歷史") {
                HStack {
                    Text("錄製會話數")
                    Spacer()
                    Text("\(viewModel.recordedSessions.count)")
                        .foregroundColor(.secondary)
                }
                
                if !viewModel.recordedSessions.isEmpty {
                    Button("查看歷史") {
                        showingSessionHistory = true
                    }
                }
            }
            
            // 應用信息
            Section("應用信息") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("開發者")
                    Spacer()
                    Text("Aura Team")
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingSessionHistory) {
            SessionHistoryView(sessions: viewModel.recordedSessions)
        }
    }
}

struct SessionHistoryView: View {
    let sessions: [BrainwaveSession]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List(sessions, id: \.id) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(DateFormatter.sessionFormatter.string(from: session.startTime))
                            .font(.headline)
                        Spacer()
                        Text(formatDuration(session.duration))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("設備: \(session.deviceName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("樣本: \(session.sampleCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("錄製歷史")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension DateFormatter {
    static let sessionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

// 合併視圖：僅保留輕量的數據卡片（錄製控制、預覽、統計）
struct CombinedDataWaveformView: View {
    @ObservedObject var viewModel: BrainwaveViewModel
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 1. 詳細數據展示（只保留預覽卡片）
                DataDisplayView(viewModel: viewModel)
            }
        }
        .navigationTitle("數據與波形")
    }
}

// 工具列「歷史紀錄」按鈕（用 sheet 彈出 SessionHistoryView）
struct HistoryButton: View {
    let sessions: [BrainwaveSession]
    @State private var showing = false
    
    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .accessibilityLabel("歷史紀錄")
        .sheet(isPresented: $showing) {
            SessionHistoryView(sessions: sessions)
        }
    }
}

#Preview {
    ContentView()
}

