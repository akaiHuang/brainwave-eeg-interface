//
//  DataDisplayView.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/14.
//

import SwiftUI
import Foundation
import CoreBluetooth
import Combine

// 預覽模式：Raw EEG 或 8 段「波」
enum WavePreviewMode: String, CaseIterable, Identifiable {
    case raw = "Raw EEG"
    case bands = "8 波"
    var id: String { rawValue }
}

// 在 View 端維護頻段能量的歷史
final class BandHistoryStore: ObservableObject {
    @Published var history: [String: [Double]] = [:]
    let maxPoints: Int
    
    init(maxPoints: Int = 240) {
        self.maxPoints = maxPoints
    }
    
    func append(frame: [String: Float]) {
        for (k, v) in frame {
            var arr = history[k] ?? []
            arr.append(Double(v))
            if arr.count > maxPoints {
                arr.removeFirst(arr.count - maxPoints)
            }
            history[k] = arr
        }
        for alias in EEG_BANDS_REFERENCE.map({ $0.alias }) where history[alias] == nil {
            history[alias] = []
        }
    }
}

struct DataDisplayView: View {
    @ObservedObject var viewModel: BrainwaveViewModel
    
    @State private var previewMode: WavePreviewMode = .raw
    @StateObject private var bandHistory = BandHistoryStore(maxPoints: 240)
    @State private var isRendering = false  // 控制渲染開關
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 1) 錄製控制
                RecordingControlCard(viewModel: viewModel)
                
                // 2) 波形/8波 預覽（可切換）
                WaveformPreviewCard(
                    waveformBuffer: viewModel.waveformBuffer,
                    bandHistory: bandHistory,
                    mode: $previewMode,
                    isRendering: $isRendering  // 傳遞渲染狀態
                ) {
                    viewModel.showWaveformView()
                }
                .onReceive(viewModel.$bandPowers.receive(on: DispatchQueue.main)) { bands in
                    guard isRendering else { return }  // 不渲染時不更新
                    bandHistory.append(frame: bands)
                }
                
                // 3) 統計數據
                StatisticsCard(waveformBuffer: viewModel.waveformBuffer)
                
                // 4) 頻段能量（完整腦波資訊）
                BandPowersCard(bandPowers: viewModel.bandPowers)
            }
            .padding()
        }
        .navigationTitle("實時數據")
        .onAppear {
            print("📊 數據頁面出現 - 開始渲染")
            isRendering = true
        }
        .onDisappear {
            print("📊 數據頁面消失 - 停止渲染")
            isRendering = false
        }
    }
}

struct RecordingControlCard: View {
    @ObservedObject var viewModel: BrainwaveViewModel
    
    var body: some View {
        GroupBox("錄製控制") {
            VStack(spacing: 12) {
                HStack {
                    Button(action: {
                        if viewModel.isRecording {
                            viewModel.stopRecording()
                        } else {
                            viewModel.startRecording()
                        }
                    }) {
                        HStack {
                            Image(systemName: viewModel.isRecording ? "stop.fill" : "record.circle")
                            Text(viewModel.isRecording ? "停止錄製" : "開始錄製")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(viewModel.isRecording ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(!(
                        viewModel.mindLinkManager.isConnected ||
                        viewModel.bluetoothManager.connectedPeripheral != nil ||
                        viewModel.simulationEnabled
                    ))
                    
                    Spacer()
                }
                
                if viewModel.isRecording {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("錄製時間:")
                            Text(formatDuration(viewModel.sessionDuration))
                                .font(.system(.body, design: .monospaced)).bold()
                            Spacer()
                        }
                        HStack {
                            Text("樣本數:")
                            Text("\(viewModel.waveformBuffer.samples.count)")
                                .font(.system(.body, design: .monospaced)).bold()
                            Spacer()
                        }
                    }
                    .font(.subheadline)
                }
                
                if !viewModel.recordedSessions.isEmpty {
                    HStack {
                        Text("已錄製會話: \(viewModel.recordedSessions.count)")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
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

struct WaveformPreviewCard: View {
    @ObservedObject var waveformBuffer: WaveformBuffer
    @ObservedObject var bandHistory: BandHistoryStore
    @Binding var mode: WavePreviewMode
    @Binding var isRendering: Bool  // 新增：渲染控制
    let onTapFullView: () -> Void
    
    // 固定 8 段顏色
    private let bandColors: [String: Color] = [
        "delta": .blue,
        "theta": .indigo,
        "lowAlpha": .teal,
        "highAlpha": .green,
        "lowBeta": .yellow,
        "highBeta": .orange,
        "lowGamma": .pink,
        "midGamma": .red
    ]
    private let scaleTailCount = 180 // 只用最近 N 筆做縮放
    
    private func globalMinMax() -> (min: Double, max: Double) {
        var all: [Double] = []
        for b in EEG_BANDS_REFERENCE {
            let arr = bandHistory.history[b.alias] ?? []
            all.append(contentsOf: arr.suffix(scaleTailCount))
        }
        let minV = all.min() ?? 0
        let maxV = all.max() ?? 1
        if maxV - minV < 1e-9 { return (minV, minV + 1) }
        return (minV, maxV)
    }
    
    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack {
                    Text("波形預覽").font(.headline)
                    Spacer()
                    Picker("", selection: $mode) {
                        ForEach(WavePreviewMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                
                Button(action: onTapFullView) {
                    ZStack {
                        switch mode {
                        case .raw:
                            // 🚀 Metal 加速：RAW 波形預覽
                            renderRawWaveformMetal()
                                .frame(height: 100)
                        case .bands:
                            // 🚀 Metal 加速：8 頻段疊加預覽
                            renderBandsOverlayMetal()
                                .frame(height: 180)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background(AuraTheme.secondaryBackground)
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                
                if mode == .bands {
                    BandsLegendView(colors: bandColors)
                }
                
                HStack {
                    Text(mode == .raw ? "點擊查看完整波形" : "8 段能量疊加預覽（最近窗縮放）")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if mode == .raw {
                        Text("樣本數: \(waveformBuffer.samples.count)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    
    // MARK: - Metal 渲染方法
    
    /// Metal 渲染：RAW 波形
    @ViewBuilder
    private func renderRawWaveformMetal() -> some View {
        if isRendering {
            let samples = waveformBuffer.getDownsampledData(targetPoints: 400)
            let normalizedData = normalizeWaveformData(samples: samples, minVal: waveformBuffer.minValue, maxVal: waveformBuffer.maxValue)
            
            MetalWaveformView(
                waveformData: normalizedData,
                color: AuraTheme.waveformRaw,
                lineWidth: 1.5,
                backgroundColor: .clear
            )
        } else {
            // 暫停渲染時顯示佔位
            Color.clear
        }
    }
    
    /// Metal 渲染：8 頻段疊加
    @ViewBuilder
    private func renderBandsOverlayMetal() -> some View {
        if isRendering {
            let (gmin, gmax) = globalMinMax()
            
            ZStack {
                // 背景網格（輕量級 CPU 渲染）
                GridView()
                    .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
                
                // 8 層 Metal 波形疊加
                ForEach(EEG_BANDS_REFERENCE, id: \.alias) { band in
                    let values = bandHistory.history[band.alias] ?? []
                    let normalizedData = normalizeHistoryData(values: values, minVal: gmin, maxVal: gmax)
                    
                    MetalWaveformView(
                        waveformData: normalizedData,
                        color: bandColors[band.alias] ?? .blue,
                        lineWidth: 1.2,
                        backgroundColor: .clear
                    )
                    .opacity(0.9)
                }
            }
        } else {
            // 暫停渲染時顯示佔位
            Color.clear
        }
    }
    
    /// 歸一化波形數據到 -1.0 ~ 1.0
    private func normalizeWaveformData(samples: [Double], minVal: Double, maxVal: Double) -> [Float] {
        guard !samples.isEmpty, maxVal != minVal else {
            return []
        }
        
        let range = maxVal - minVal
        return samples.map { sample in
            let normalized = ((sample - minVal) / range) * 2.0 - 1.0 // 0~1 -> -1~1
            return Float(normalized)
        }
    }
    
    /// 歸一化歷史數據到 -1.0 ~ 1.0
    private func normalizeHistoryData(values: [Double], minVal: Double, maxVal: Double) -> [Float] {
        guard !values.isEmpty, maxVal != minVal else {
            return []
        }
        
        let range = maxVal - minVal
        return values.map { value in
            let normalized = ((value - minVal) / range) * 2.0 - 1.0 // 0~1 -> -1~1
            return Float(normalized)
        }
    }
}

// 疊線圖用 Shape（保留作為備用，已不使用）
struct BandOverlayShape: Shape {
    let values: [Double]
    let minValue: Double
    let maxValue: Double
    
    func path(in rect: CGRect) -> Path {
        guard !values.isEmpty, maxValue != minValue else { return Path() }
        let n = values.count
        let w = rect.width
        let h = rect.height
        let range = maxValue - minValue
        
        var path = Path()
        for (i, v) in values.enumerated() {
            let x = w * CGFloat(i) / CGFloat(max(n - 1, 1))
            let yNorm = (v - minValue) / range
            let y = h * CGFloat(1.0 - yNorm)
            let p = CGPoint(x: x, y: y)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

// 8 段圖例
struct BandsLegendView: View {
    let colors: [String: Color]
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(EEG_BANDS_REFERENCE) { band in
                HStack(spacing: 6) {
                    Circle().fill((colors[band.alias] ?? .blue)).frame(width: 10, height: 10)
                    Text(band.displayName).font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 2)
    }
}

struct StatisticsCard: View {
    @ObservedObject var waveformBuffer: WaveformBuffer
    
    var body: some View {
        GroupBox("統計數據") {
            let stats = waveformBuffer.getStatistics()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatisticItem(title: "平均值", value: String(format: "%.4f", stats.mean))
                StatisticItem(title: "RMS", value: String(format: "%.4f", stats.rms))
                StatisticItem(title: "峰峰值", value: String(format: "%.4f", stats.peakToPeak))
                StatisticItem(title: "樣本數", value: "\(stats.sampleCount)")
            }
        }
    }
}

struct StatisticItem: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(6)
    }
}

// 頻段能量列表
struct BandPowersCard: View {
    let bandPowers: [String: Float]
    
    private var maxPowerInFrame: Float {
        let values = EEG_BANDS_REFERENCE.compactMap { bandPowers[$0.alias] }
        return max(values.max() ?? 0, 1e-6)
    }
    
    var body: some View {
        GroupBox("頻段能量（Band Powers）") {
            VStack(spacing: 10) {
                ForEach(EEG_BANDS_REFERENCE) { band in
                    BandPowerRow(
                        title: band.displayName,
                        subtitle: "\(band.hzRange) · \(band.meaning)",
                        value: bandPowers[band.alias],
                        normalized: (bandPowers[band.alias] ?? 0) / maxPowerInFrame
                    )
                }
            }
        }
    }
}

struct BandPowerRow: View {
    let title: String
    let subtitle: String
    let value: Float?
    let normalized: Float // 0...1
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text(formattedValue(value))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(minWidth: 60, alignment: .trailing)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.12))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [.blue.opacity(0.8), .purple.opacity(0.8)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: CGFloat(max(0, min(1, normalized))) * geo.size.width, height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 4)
    }
    
    private func formattedValue(_ v: Float?) -> String {
        guard let v = v else { return "—" }
        let logv = log10(max(v, 1e-6)) // 只做顯示用的對數
        return String(format: "log10: %.2f", logv)
    }
}

#Preview {
    NavigationView {
        DataDisplayView(viewModel: BrainwaveViewModel())
    }
}

