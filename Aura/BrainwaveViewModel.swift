//
//  BrainwaveViewModel.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/14.
//

import Foundation
import Combine
import CoreBluetooth
import ExternalAccessory

class BrainwaveViewModel: ObservableObject {
    @Published var bluetoothManager = BluetoothManager()
    @Published var mindLinkManager = MindLinkManager()
    @Published var waveformBuffer = WaveformBuffer(maxSamples: 2000)
    @Published var currentView: AppView = .deviceList
    @Published var isRecording = false
    @Published var sessionDuration: TimeInterval = 0
    @Published var recordedSessions: [BrainwaveSession] = []
    @Published var simulationEnabled = false
    
    // 新增：在「模擬數據」下，是否用 Raw → 分析器 產生 8 段
    @Published var simulateAnalysisFromRaw = false
    
    // Mind Link 狀態
    @Published var signalQuality: Int? // 0~200，200 最差
    @Published var isReceivingEEG: Bool = false

    // 解析/分析輸出（後續可用於 UI）
    @Published var bandPowers: [String: Float] = [:]
    @Published var attention: UInt8?
    @Published var meditation: UInt8?
    
    var cancellables = Set<AnyCancellable>()
    private var sessionStartTime: Date?
    private var sessionTimer: Timer?
    
    // 模擬器
    private var simulator: SimulatedDataSource?
    private var simCancellable: AnyCancellable?
    private var simBandsCancellable: AnyCancellable?
    
    // 用於衰退 isReceivingEEG 的時間戳
    private var lastEEGTimestamp: Date?
    private var eegWatchdogTimer: Timer?
    
    // 儲存層
    private let sessionStore = SessionStore()
    private var recordedSampleCount: Int = 0

    // Parser / Analyzer
    private let tgParser = ThinkGearParser()
    private let analyzer = EEGAnalyzer()
    private var analyzerTasks: [Task<Void, Never>] = []
    
    enum AppView {
        case deviceList
        case dataView
        case waveformView
        case statistics
    }
    
    init() {
        let summaries = sessionStore.loadIndex()
        self.recordedSessions = summaries.map {
            BrainwaveSession(id: $0.id,
                             startTime: $0.startTime,
                             duration: $0.duration,
                             sampleCount: $0.sampleCount,
                             deviceName: $0.deviceName)
        }
        setupBindings()
        startEEGWatchdog()
        setupAnalyzerSubscriptions()
    }
    
    deinit {
        eegWatchdogTimer?.invalidate()
        analyzerTasks.forEach { $0.cancel() }
    }
    
    private func setupBindings() {
        bluetoothManager.$receivedData
            .compactMap { $0 }
            .sink { [weak self] data in
                print("📥 [BLE] 收到資料 bytes=\(data.count)")
                self?.processReceivedData(data)
            }
            .store(in: &cancellables)
        
        mindLinkManager.$receivedData
            .compactMap { $0 }
            .sink { [weak self] data in
                print("📥 [EA] 收到資料 bytes=\(data.count)")
                self?.processMindLinkData(data)
            }
            .store(in: &cancellables)
        
        bluetoothManager.$connectionState
            .sink { state in print("🔌 [BLE] 狀態變更: \(state)") }
            .store(in: &cancellables)
        
        mindLinkManager.$connectionState
            .sink { (state: MindLinkManager.ConnectionState) in print("🧠 [EA] 狀態變更: \(state)") }
            .store(in: &cancellables)
    }
    
    private func setupAnalyzerSubscriptions() {
        // Band powers stream → 更新 @Published
        let t1 = Task { [weak self] in
            guard let self else { return }
            for await frame in await analyzer.bandStream {
                await MainActor.run {
                    self.bandPowers = frame.bands
                    // 🔍 Print 更新的頻帶能量
                    let preview = frame.bands.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.4f", $0.value))" }.joined(separator: " ")
                    print("📈 [VM] 更新 bandPowers: \(preview)")
                }
            }
        }
        analyzerTasks.append(t1)
        
        // ESense stream → 更新 attention/meditation/quality + isReceivingEEG
        let t2 = Task { [weak self] in
            guard let self else { return }
            for await es in await analyzer.esenseStream {
                await MainActor.run {
                    if let q = es.quality { self.signalQuality = Int(q) }
                    self.attention = es.attention
                    self.meditation = es.meditation
                    self.lastEEGTimestamp = Date()
                    if self.isReceivingEEG == false { self.isReceivingEEG = true }
                    // 錄製每秒指標
                    if self.isRecording {
                        let metrics = SessionMetricsLine(
                            timestamp: Date(),
                            attention: es.attention.map { Int($0) },
                            meditation: es.meditation.map { Int($0) },
                            signalQuality: es.quality.map { Int($0) },
                            powerBands: nil
                        )
                        self.sessionStore.appendMetrics(metrics)
                    }
                }
            }
        }
        analyzerTasks.append(t2)
    }
    
    private func startEEGWatchdog() {
        eegWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let last = lastEEGTimestamp {
                // 延長到 3.0 秒，避免 LED 頻繁閃爍
                if Date().timeIntervalSince(last) > 3.0, isReceivingEEG {
                    print("⏱️ [EEG] 超過 3.0s 無指標，標記未接收")
                    isReceivingEEG = false
                }
            } else if isReceivingEEG {
                print("⏱️ [EEG] 無最後時間戳，標記未接收")
                isReceivingEEG = false
            }
        }
    }
    
    func processReceivedData(_ data: Data) {
        // 處理模擬數據（NeuroSky 格式：Int16 大端序，每 2 bytes 一個樣本）
        // 或 BLE 路徑的資料
        
        var int16Samples: [Int16] = []
        var displaySamples: [Double] = []
        
        // 判斷數據格式：如果是模擬數據且長度是偶數，解析為 Int16（大端序）
        if simulationEnabled && data.count % 2 == 0 {
            // NeuroSky RAW 格式：每 2 bytes = 1 個 Int16 樣本（大端序）
            int16Samples.reserveCapacity(data.count / 2)
            displaySamples.reserveCapacity(data.count / 2)
            
            for i in stride(from: 0, to: data.count, by: 2) {
                let highByte = Int(data[i])
                let lowByte = Int(data[i + 1])
                // 大端序組合：(high << 8) | low
                let combined = (highByte << 8) | lowByte
                
                // 處理符號擴展（如果最高位為 1，表示負數）
                // 將無符號 16-bit 值轉換為有符號 Int16
                let rawValue: Int16
                if combined > 32767 {
                    rawValue = Int16(combined - 65536)
                } else {
                    rawValue = Int16(combined)
                }
                
                int16Samples.append(rawValue)
                // 顯示用：歸一化到 -1.0 ~ +1.0（基於 ±2048 範圍）
                displaySamples.append(Double(rawValue) / 2048.0)
            }
            
            // 🔍 Print 解析後的資訊
            if let first = int16Samples.first {
                print("🔧 [VM] processReceivedData: 收到 \(data.count) bytes → 解析為 \(int16Samples.count) 樣本 | 第1個: Int16=\(first), 範圍: \(int16Samples.min()!)~\(int16Samples.max()!)")
            }
            
        } else {
            // BLE 路徑或舊格式：UInt8 (0-255) → -128..127
            let samples = data.map { Double(Int($0) - 128) }
            displaySamples = samples
            
            // 轉 Int16（同錄製）
            int16Samples = samples.map { d in
                let scaled = d * 256.0
                let clamped = max(-32768.0, min(32767.0, scaled))
                return Int16(clamped)
            }
        }
        
        // 更新波形緩衝區（用於 UI 顯示）
        waveformBuffer.addSamples(displaySamples)
        
        // 錄製
        if isRecording {
            sessionStore.appendRawSamples(int16Samples)
        }
        
        // 餵給分析器（僅在「模擬分析」開啟時）
        if simulationEnabled && simulateAnalysisFromRaw {
            print("🔬 [VM] 將 \(int16Samples.count) 樣本送入分析器")
            Task.detached { [int16Samples, analyzer] in
                for s in int16Samples {
                    await analyzer.ingest(raw: s)
                }
            }
        }
        
        lastEEGTimestamp = Date()
        if !isReceivingEEG { isReceivingEEG = true }
    }
    
    func processMindLinkData(_ data: Data) {
        // 將 ExternalAccessory 的資料交給 ThinkGearParser
        let events = tgParser.parseChunk(data)
        if events.isEmpty {
            // 後備：沿用舊邏輯（僅 attention/meditation/poorSignal）
            if let packet = mindLinkManager.parseThinkGearData(data) {
                var hasEEGIndicator = false
                if let poorSignal = packet.poorSignal {
                    let value = Int(poorSignal)
                    signalQuality = value
                    if value < 200 { hasEEGIndicator = true }
                    Task { await analyzer.ingest(eSenseAttention: nil, meditation: nil, quality: poorSignal) }
                }
                if let attention = packet.attention {
                    hasEEGIndicator = true
                    Task { await analyzer.ingest(eSenseAttention: attention, meditation: nil, quality: nil) }
                }
                if let meditation = packet.meditation {
                    hasEEGIndicator = true
                    Task { await analyzer.ingest(eSenseAttention: nil, meditation: meditation, quality: nil) }
                }
                if hasEEGIndicator {
                    lastEEGTimestamp = Date()
                    if !isReceivingEEG { isReceivingEEG = true }
                }
            }
            return
        }
        
        var appendedAnyRaw = false
        
        for evt in events {
            // 原始 raw → Analyzer + 錄製 + 預覽
            if !evt.rawSamples.isEmpty {
                appendedAnyRaw = true
                Task.detached { [samples = evt.rawSamples, analyzer] in
                    for s in samples {
                        await analyzer.ingest(raw: s)
                    }
                }
                if isRecording {
                    sessionStore.appendRawSamples(evt.rawSamples)
                }
            }
            // 0x83 八段（可選：落地於 metrics）
            if let bands = evt.bands {
                Task { await analyzer.ingest(eightBands: bands) }
                if isRecording {
                    let metrics = SessionMetricsLine(
                        timestamp: Date(),
                        attention: nil, meditation: nil,
                        signalQuality: nil,
                        powerBands: bands
                    )
                    sessionStore.appendMetrics(metrics)
                }
            }
            // eSense 與信號品質
            if evt.attention != nil || evt.meditation != nil || evt.poorSignal != nil {
                Task { [evt] in
                    await analyzer.ingest(eSenseAttention: evt.attention, meditation: evt.meditation, quality: evt.poorSignal)
                }
            }
        }
        
        // 更新 UI 波形預覽（輕量）
        if appendedAnyRaw {
            let flat = events.flatMap { $0.rawSamples }
            if !flat.isEmpty {
                let preview = flat.map { Double($0) / 32768.0 }
                waveformBuffer.addSamples(preview)
                recordedSampleCount += flat.count
            }
            lastEEGTimestamp = Date()
            if !isReceivingEEG { isReceivingEEG = true }
        }
    }
    
    // MARK: - 模擬模式（冪等）
    func enableSimulation() {
        print("🎬 [VM] 啟動模擬模式 | simulateAnalysisFromRaw=\(simulateAnalysisFromRaw)")
        if simulator == nil {
            simulator = SimulatedDataSource()
            // 原始 bytes → 照舊更新波形/錄製，且在 simulateAnalysisFromRaw 開啟時會在 processReceivedData 內餵 analyzer
            simCancellable = simulator?.dataPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] data in
                    self?.processReceivedData(data)
                }
            // 模擬八段能量：僅在 simulateAnalysisFromRaw = false 時注入（避免與 Raw 分析混用）
            simBandsCancellable = simulator?.bandPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] bands in
                    guard let self else { return }
                    if !self.simulateAnalysisFromRaw {
                        // 轉換 Float → UInt32：模擬數據已經是 0.0~0.5 的相對能量值
                        // 需要放大到合理的功率範圍（例如 100~50000），而非過度放大
                        let u32Bands: [String: UInt32] = bands.mapValues { v in
                            let clamped = max(0.0, v) // 確保非負
                            // 將 0.0~0.5 的範圍映射到 1000~50000 的功率值
                            let scaled = clamped * 100000.0 // 放大到合理範圍
                            return UInt32(scaled.rounded())
                        }
                        Task { await self.analyzer.ingest(eightBands: u32Bands) }
                    }
                }
        }
        if simulator?.isGenerating != true {
            simulator?.startGenerating()
        }
        if !simulationEnabled { simulationEnabled = true }
    }
    
    func disableSimulation() {
        simulator?.stopGenerating()
        simulator = nil
        simCancellable?.cancel()
        simCancellable = nil
        simBandsCancellable?.cancel()
        simBandsCancellable = nil
        simulationEnabled = false
    }
    
    private func labelForCurrentDevice() -> String {
        if simulationEnabled {
            if let realName = bluetoothManager.connectedPeripheral?.name ?? mindLinkManager.connectedAccessory?.name {
                return "\(realName)（模擬資料）"
            } else {
                return "模擬資料"
            }
        }
        return bluetoothManager.connectedPeripheral?.name
            ?? mindLinkManager.connectedAccessory?.name
            ?? "未知設備"
    }
    
    // MARK: - Recording Management
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        sessionStartTime = Date()
        sessionDuration = 0
        waveformBuffer.clear()
        recordedSampleCount = 0
        
        let deviceName = labelForCurrentDevice()
        let meta = SessionMeta(
            id: UUID(),
            startTime: sessionStartTime ?? Date(),
            deviceName: deviceName,
            sampleRate: 512,
            channels: 1
        )
        sessionStore.startSession(meta: meta)
        
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if let startTime = self?.sessionStartTime {
                self?.sessionDuration = Date().timeIntervalSince(startTime)
            }
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        sessionTimer?.invalidate()
        sessionTimer = nil
        
        let endTime = Date()
        if let summary = sessionStore.endSession(endTime: endTime) {
            let session = BrainwaveSession(
                id: summary.id,
                startTime: summary.startTime,
                duration: summary.duration,
                sampleCount: summary.sampleCount,
                deviceName: summary.deviceName
            )
            recordedSessions.insert(session, at: 0)
        } else if let startTime = sessionStartTime {
            let session = BrainwaveSession(
                id: UUID(),
                startTime: startTime,
                duration: sessionDuration,
                sampleCount: recordedSampleCount,
                deviceName: labelForCurrentDevice()
            )
            recordedSessions.insert(session, at: 0)
        }
        
        sessionStartTime = nil
        sessionDuration = 0
        recordedSampleCount = 0
    }
    
    // MARK: - Navigation
    func showDeviceList() { currentView = .deviceList }
    func showDataView() { currentView = .dataView }
    func showWaveformView() { currentView = .waveformView }
    func showStatistics() { currentView = .statistics }
    
    // MARK: - Bluetooth Controls
    func startScanning() { bluetoothManager.startScanning() }
    func stopScanning() { bluetoothManager.stopScanning() }
    func connect(to peripheral: CBPeripheral) { bluetoothManager.connect(to: peripheral) }
    func disconnect() {
        bluetoothManager.disconnect()
        mindLinkManager.disconnect()
    }
}

struct BrainwaveSession {
    let id: UUID
    let startTime: Date
    let duration: TimeInterval
    let sampleCount: Int
    let deviceName: String
}

