//
//  SimulatedDataSource.swift
//  Aura
//
//  模擬 NeuroSky RAW EEG 資料與 8 段頻帶能量。
//
//  符合 NeuroSky 官方規格：
//  - RAW 數據：Int16，範圍 -2048 ~ +2048，採樣率 512 Hz
//  - 電壓轉換：V = [rawValue × (1.8 / 4096)] / 2000 μV
//  - 傳輸格式：將 Int16 編碼為 2 個位元組（大端序，符合 ThinkGear 協定）
//  - 頻帶能量：依時間用平滑的正弦函數合成各段值，輸出 Float
//

import Foundation
import Combine

final class SimulatedDataSource: ObservableObject {
    // 公開 Publisher（對齊 BrainwaveViewModel）
    public var dataPublisher: AnyPublisher<Data, Never> {
        dataSubject.eraseToAnyPublisher()
    }
    public var bandPublisher: AnyPublisher<[String: Float], Never> {
        bandSubject.eraseToAnyPublisher()
    }
    
    // 生成狀態
    @Published var isGenerating: Bool = false
    
    // 私有成員
    private var timer: Timer?
    private let dataSubject = PassthroughSubject<Data, Never>()
    private let bandSubject = PassthroughSubject<[String: Float], Never>()
    
    // NeuroSky RAW 規格參數
    private let sampleRate: Double = 512.0  // Hz
    private var sampleIndex: Int = 0        // 累積樣本計數器（用於相位連續性）
    
    // 🎯 頻帶更新頻率控制（對齊 NeuroSky 規格：1 Hz）
    private var bandUpdateCounter: Int = 0
    private let bandUpdateInterval: Int = 51  // 512 Hz ÷ 10 samples/batch ≈ 51.2 批次 = 1 秒
    
    // 🎯 Print 頻率控制（避免 Console 輸出消耗 CPU）
    private var lastBandPrintTime: Date = Date()
    
    deinit {
        stopGenerating()
    }
    
    // MARK: - Public control
    
    func startGenerating() {
        guard !isGenerating else { return }
        isGenerating = true
        sampleIndex = 0  // 重置樣本計數器
        bandUpdateCounter = 0  // 重置頻帶更新計數器
        lastBandPrintTime = Date()  // 重置 print 時間戳
        
        // 以 512 Hz 採樣率計算：每次產生 10 個樣本，timer 間隔 = 10/512 ≈ 0.0195s
        let samplesPerBatch = 10
        let timerInterval = Double(samplesPerBatch) / sampleRate
        
        let t = Timer(timeInterval: timerInterval, repeats: true) { [weak self] (_: Timer) in
            guard let self else { return }
            
            // ✅ RAW 數據：每次都生成（512 Hz）
            self.generateSimulatedBrainwaveData(count: samplesPerBatch)
            
            // 🎯 頻帶能量：每 51 次才生成一次（1 Hz，對齊 NeuroSky 規格）
            self.bandUpdateCounter += 1
            if self.bandUpdateCounter >= self.bandUpdateInterval {
                self.generateSimulatedBands()
                self.bandUpdateCounter = 0
            }
        }
        RunLoop.main.add(t, forMode: RunLoop.Mode.common)
        timer = t
    }
    
    func stopGenerating() {
        isGenerating = false
        timer?.invalidate()
        timer = nil
        sampleIndex = 0
        bandUpdateCounter = 0
    }
    
    // MARK: - Simulated Raw EEG (NeuroSky format)
    
    /// 產生符合 NeuroSky 規格的 RAW EEG 數據
    /// - Parameter count: 要產生的樣本數量
    /// - Returns: 編碼後的 Data（每個樣本 2 bytes，大端序）
    private func generateSimulatedBrainwaveData(count: Int) {
        var rawSamples: [Int16] = []
        rawSamples.reserveCapacity(count)
        
        for i in 0..<count {
            // 計算當前樣本的相位（使用累積計數器確保相位連續）
            let phase = 2.0 * Double.pi * Double(sampleIndex) / sampleRate
            
            // 合成多個頻段的腦波（符合真實 EEG 頻譜分佈）
            // 振幅設定參考真實腦波的典型微伏級振幅（已轉換為 ADC 數值）
            let delta  = sin(2.0 * phase) * 150.0      // 2 Hz (delta)  ~33 μV
            let theta  = sin(5.0 * phase) * 200.0      // 5 Hz (theta)  ~44 μV
            let alpha  = sin(10.0 * phase) * 400.0     // 10 Hz (alpha) ~88 μV - 主要成分
            let beta   = sin(20.0 * phase) * 250.0     // 20 Hz (beta)  ~55 μV
            let gamma  = sin(35.0 * phase) * 100.0     // 35 Hz (gamma) ~22 μV
            
            // 添加少量噪聲（模擬環境干擾和生理雜訊）
            let noise = Double.random(in: -50...50)
            
            let combined = delta + theta + alpha + beta + gamma + noise
            
            // 限制在 NeuroSky 規格範圍：-2048 ~ +2048
            let clamped = max(-2048.0, min(2048.0, combined))
            let rawValue = Int16(clamped)
            
            rawSamples.append(rawValue)
            sampleIndex += 1
        }
        
        // 編碼為 Data：每個 Int16 轉為 2 bytes（大端序，符合 ThinkGear 0x80 格式）
        var data = Data()
        data.reserveCapacity(count * 2)
        for sample in rawSamples {
            // 大端序：高位元組在前
            let highByte = UInt8((sample >> 8) & 0xFF)
            let lowByte = UInt8(sample & 0xFF)
            data.append(highByte)
            data.append(lowByte)
        }
        
        // 🔍 Print 第一個樣本的詳細資訊（用於驗證數據格式）
        if let firstSample = rawSamples.first {
            print("📤 [SimulatedData] 產生 \(count) 樣本 | 第1個樣本: Int16=\(firstSample) | 範圍: \(rawSamples.min()!)~\(rawSamples.max()!) | Data bytes=\(data.count)")
        }
        
        dataSubject.send(data)
    }
    
    // MARK: - Simulated 8-band powers
    
    /// 產生 8 段頻帶能量（以 Float 表示），鍵名對齊 EEG_BANDS_REFERENCE 的 alias。
    /// 基於上面 generateSimulatedBrainwaveData 產生的頻率內容，模擬對應的能量分佈。
    /// 使用緩慢變化的調制來模擬真實腦波的動態變化。
    private func generateSimulatedBands() {
        let t = Date().timeIntervalSince1970
        
        // 使用非常低頻的正弦波來調制能量（模擬腦波的緩慢變化）
        func modulation(_ hz: Double, phase: Double = 0, baseLevel: Double, amplitude: Double) -> Double {
            let wave = sin(2.0 * .pi * hz * t + phase)
            return baseLevel + amplitude * wave
        }
        
        // 添加小幅隨機擾動
        func jitter(_ value: Double, amount: Double = 0.02) -> Float {
            let jittered = value + Double.random(in: -amount...amount)
            return Float(max(0.0, jittered))
        }
        
        // 基於 generateSimulatedBrainwaveData 中的頻率內容設定基準能量
        // Raw 數據包含: 2Hz(150), 5Hz(200), 10Hz(400), 20Hz(250), 35Hz(100)
        // 功率 = 振幅²: 2Hz(22500), 5Hz(40000), 10Hz(160000), 20Hz(62500), 35Hz(10000)
        // 總功率 = 295000
        // 相對功率: 2Hz(7.6%), 5Hz(13.6%), 10Hz(54.2%), 20Hz(21.2%), 35Hz(3.4%)
        
        var bands: [String: Float] = [:]
        
        // Delta (0.5-2.75 Hz): 包含 2Hz 成分 (150² = 22500 → 7.6%)
        bands["delta"] = jitter(modulation(0.05, phase: 0.0, baseLevel: 0.08, amplitude: 0.03))
        
        // Theta (3.5-6.75 Hz): 包含 5Hz 成分 (200² = 40000 → 13.6%)
        bands["theta"] = jitter(modulation(0.07, phase: 0.5, baseLevel: 0.14, amplitude: 0.05))
        
        // Low Alpha (7.5-9.25 Hz): 不包含主要成分，分配少量 alpha 泄漏能量 (~5%)
        bands["lowAlpha"] = jitter(modulation(0.09, phase: 1.0, baseLevel: 0.05, amplitude: 0.02))
        
        // High Alpha (10-11.75 Hz): 包含 10Hz 主要成分 (400² = 160000 → 54.2%)
        // 這是最強的頻段，應該主導整個頻譜
        bands["highAlpha"] = jitter(modulation(0.11, phase: 1.5, baseLevel: 0.52, amplitude: 0.10))
        
        // Low Beta (13-16.75 Hz): 不包含主要成分，分配少量 beta 泄漏能量 (~3%)
        bands["lowBeta"] = jitter(modulation(0.13, phase: 2.0, baseLevel: 0.03, amplitude: 0.02))
        
        // High Beta (18-29.75 Hz): 包含 20Hz 成分 (250² = 62500 → 21.2%)
        bands["highBeta"] = jitter(modulation(0.15, phase: 2.5, baseLevel: 0.20, amplitude: 0.06))
        
        // Low Gamma (31-39.75 Hz): 包含 35Hz 成分 (100² = 10000 → 3.4%)
        bands["lowGamma"] = jitter(modulation(0.17, phase: 3.0, baseLevel: 0.03, amplitude: 0.01))
        
        // Mid Gamma (41-49.75 Hz): 超出主要頻率範圍 → 最低功率 (~1%)
        bands["midGamma"] = jitter(modulation(0.19, phase: 3.5, baseLevel: 0.01, amplitude: 0.01))        // 歸一化：確保總和為 1.0（相對能量）
        let sum = bands.values.reduce(0, +)
        if sum > 1e-6 {
            for key in bands.keys {
                bands[key]! /= sum
            }
        }
        
        // 確保所有鍵都存在（避免下游視圖找不到鍵）
        for alias in ["delta","theta","lowAlpha","highAlpha","lowBeta","highBeta","lowGamma","midGamma"] {
            if bands[alias] == nil { bands[alias] = 0 }
        }
        
        // 🎯 Print 頻帶能量（降低頻率：每秒最多 1 次）
        let now = Date()
        if now.timeIntervalSince(lastBandPrintTime) >= 1.0 {
            let preview = bands.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.4f", $0.value))" }.joined(separator: " ")
            print("📊 [SimulatedBands] 直接注入 (1 Hz): \(preview)")
            lastBandPrintTime = now
        }
        
        bandSubject.send(bands)
    }
}
