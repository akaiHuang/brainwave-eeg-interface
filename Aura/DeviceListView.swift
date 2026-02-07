//
//  DeviceListView.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/14.
//

import SwiftUI
import UIKit
import CoreBluetooth
import ExternalAccessory

struct DeviceListView: View {
    @ObservedObject var viewModel: BrainwaveViewModel
    @ObservedObject var bluetoothManager: BluetoothManager
    @ObservedObject var mindLinkManager: MindLinkManager
    let onDeviceSelected: (CBPeripheral) -> Void
    let onMindLinkSelected: (EAAccessory) -> Void
    
    @State private var isAnimatingGuide = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 系統藍牙狀態（可保留，用於看系統藍牙狀態）
            BluetoothStatusView(bluetoothManager: bluetoothManager)
            
            // 教學卡片：未連接且非連線中時顯示
            if !mindLinkManager.isConnected && mindLinkManager.connectionState != .connecting {
                GuideCard(
                    onOpenSettings: openAppSettings,
                    onRefresh: refreshDevices,
                    isAnimating: $isAnimatingGuide
                )
                .padding(.horizontal)
                .padding(.top, 12)
                .transition(.scale.combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: mindLinkManager.isConnected)
                .onAppear {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.3)) {
                        isAnimatingGuide = true
                    }
                }
            }
            
            // 設備列表（保留）
            List {
                // Mind Link (NeuroSky) 裝置區段
                Section(header: Text("Mind Link 裝置 (藍牙經典)")) {
                    if mindLinkManager.availableAccessories.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("未找到 Mind Link 裝置")
                                    .font(.headline)
                                Text("請先於 設定 → 藍牙 中連接 Mind Link，完成後回到本頁下拉刷新。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(mindLinkManager.availableAccessories, id: \.connectionID) { accessory in
                            MindLinkDeviceRow(
                                accessory: accessory,
                                isConnected: mindLinkManager.connectedAccessory?.connectionID == accessory.connectionID,
                                connectionState: mindLinkManager.connectionState
                            ) {
                                onMindLinkSelected(accessory)
                            }
                        }
                    }
                }
                
                /*
                // BLE 區段暫時關閉
                Section(header: Text("BLE 裝置")) { ... }
                */
            }
            .listStyle(.insetGrouped)
            .refreshable {
                refreshDevices()
            }
        }
        // 注意：不再在這裡設定 .navigationTitle 或 .toolbar
        // 由上層 ContentView 的 NavigationView 控制標題與右上角狀態燈
        .onAppear {
            refreshDevices()
        }
    }
    
    private func openAppSettings() {
        // 嘗試直接開啟系統藍牙設定頁面
        if let url = URL(string: "App-prefs:Bluetooth") {
            UIApplication.shared.open(url, options: [:]) { success in
                if !success {
                    // 如果失敗（iOS 某些版本不支援），則開啟設定首頁
                    if let settingsUrl = URL(string: "App-prefs:") {
                        UIApplication.shared.open(settingsUrl)
                    }
                }
            }
        }
    }
    
    private func refreshDevices() {
        mindLinkManager.scanForDevices()
        if bluetoothManager.isScanning { bluetoothManager.stopScanning() }
    }
}

// ========== 子視圖（保留） ==========

struct GuideCard: View {
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
    @Binding var isAnimating: Bool
    
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.purple)
                        .scaleEffect(isAnimating ? 1.0 : 0.8)
                        .animation(.easeOut(duration: 0.6).repeatCount(1, autoreverses: false), value: isAnimating)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("連接 Mind Link 裝置")
                        .font(.headline)
                    Text("請先在 系統設定 → 藍牙 中完成配對與連接，回到此頁後下拉刷新即可顯示。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 8) {
                GuideStepRow(icon: "gearshape", title: "打開「設定」App")
                GuideStepRow(icon: "wave.3.right", title: "進入「藍牙」，配對 Mind Link")
                GuideStepRow(icon: "arrow.clockwise", title: "返回本頁，下拉刷新清單")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
            
            HStack {
                Button {
                    onOpenSettings()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("前往設定")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.purple.opacity(0.2)))
                }
                
                Spacer(minLength: 12)
                
                Button {
                    onRefresh()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("已完成，重新整理")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().stroke(Color.secondary.opacity(0.4)))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
        )
        .opacity(isAnimating ? 1 : 0)
        .scaleEffect(isAnimating ? 1 : 0.98)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: isAnimating)
    }
}

struct GuideStepRow: View {
    let icon: String
    let title: String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.purple)
                .frame(width: 18)
            Text(title)
                .font(.subheadline)
            Spacer()
        }
    }
}

struct BluetoothStatusView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    
    var body: some View {
        VStack {
            HStack {
                Circle()
                    .fill(bluetoothStateColor)
                    .frame(width: 12, height: 12)
                Text(bluetoothStateText)
                    .font(.subheadline)
                Spacer()
            }
            .padding(.horizontal)
            
            if case .connecting = bluetoothManager.connectionState {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("正在連接...")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    Spacer()
                }
                .padding(.horizontal)
            }
            
            if let errorMessage = bluetoothManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
    }
    
    private var bluetoothStateColor: Color {
        switch bluetoothManager.bluetoothState {
        case .poweredOn: return .green
        case .poweredOff: return .red
        case .unauthorized, .unsupported: return .orange
        default: return .gray
        }
    }
    
    private var bluetoothStateText: String {
        switch bluetoothManager.bluetoothState {
        case .poweredOn: return "藍牙已開啟"
        case .poweredOff: return "藍牙已關閉"
        case .unauthorized: return "無藍牙權限"
        case .unsupported: return "不支持藍牙"
        case .resetting: return "藍牙重置中"
        default: return "藍牙狀態未知"
        }
    }
}

struct MindLinkDeviceRow: View {
    let accessory: EAAccessory
    let isConnected: Bool
    let connectionState: MindLinkManager.ConnectionState
    let onTap: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.purple)
                    Text(accessory.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                
                HStack {
                    Text("Mind Link 裝置")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("協定: \(accessory.protocolStrings.first ?? "未知")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button(action: onTap) {
                Text(isConnected ? "已連接" : "連接")
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isConnected ? Color.green.opacity(0.2) : Color.purple.opacity(0.2))
                    .foregroundColor(isConnected ? .green : .purple)
                    .cornerRadius(8)
            }
            .disabled(isConnected)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    DeviceListView(
        viewModel: BrainwaveViewModel(),
        bluetoothManager: BluetoothManager(),
        mindLinkManager: MindLinkManager(),
        onDeviceSelected: { _ in },
        onMindLinkSelected: { _ in }
    )
}

