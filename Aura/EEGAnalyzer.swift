//
//  EEGAnalyzer.swift
//  Aura
//
//  Implemented analyzer: Raw -> Band Powers using Accelerate, with debug prints.
//

import Foundation
import Accelerate

@preconcurrency
public struct BandFrame: Sendable {
    public let bands: [String: Float]
    public init(bands: [String: Float]) { self.bands = bands }
}

@preconcurrency
public struct ESenseFrame: Sendable {
    public var attention: UInt8?
    public var meditation: UInt8?
    public var quality: UInt8? // 0~200（0最好）
    public init(attention: UInt8? = nil, meditation: UInt8? = nil, quality: UInt8? = nil) {
        self.attention = attention
        self.meditation = meditation
        self.quality = quality
    }
}

/// 使用 Accelerate/vDSP 從 Raw EEG 計算頻段能量：
/// - 512 Hz 取樣，512 點窗，50% overlap，Hann window
/// - 去直流（移除平均）
/// - 實數 FFT（zrip）：打包 realp=偶數樣本，imagp=奇數樣本
/// - 正確處理 Nyquist（imagp[0]）與 DC（realp[0]）
/// - 計算功率譜後依頻段積分；可選 log10 與 EMA 平滑
public actor EEGAnalyzer {
    // Streams
    private var bandContinuations: [AsyncStream<BandFrame>.Continuation] = []
    private var esenseContinuations: [AsyncStream<ESenseFrame>.Continuation] = []
    
    public var bandStream: AsyncStream<BandFrame> {
        get async {
            AsyncStream<BandFrame> { continuation in
                self.bandContinuations.append(continuation)
            }
        }
    }
    public var esenseStream: AsyncStream<ESenseFrame> {
        get async {
            AsyncStream<ESenseFrame> { continuation in
                self.esenseContinuations.append(continuation)
            }
        }
    }
    
    // Config
    private let sampleRate: Float
    private let windowSize: Int
    private let hopSize: Int
    private let useLog10: Bool
    private let useRelative: Bool
    private let emaAlpha: Float? // nil 表示不平滑
    private let powerFloor: Float = 1e-3 // 對數前的地板
    
    // Hann 窗的等效雜訊頻寬（ENBW）校正係數
    // Hann 窗 ENBW ≈ 1.5 bins，功率增益校正
    private let hannENBW: Float = 1.5
    private let hannPowerGain: Float  // 在 init 中計算
    
    // 可選：增益校正係數（用於與硬體對齊）
    private var gainCalibration: Float = 1.0
    
    // Debug
    private var debugEnabled: Bool = true
    private var frameCounter: Int = 0
    private var lastPrintTime: TimeInterval = 0
    private let printEveryNFrames = 4 // 降低輸出頻率
    
    // FFT state (C API)
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length
    private var window: [Float] = []
    private var ring: [Float] = []
    
    // Smoothing state
    private var lastSmoothed: [String: Float] = [:]
    
    public init(sampleRate: Int = 512,
                windowSize: Int = 512,
                hopSize: Int = 512,         // 改為 512（100% 跳躍）以對齊 NeuroSky 每秒 1 次輸出
                useLog10: Bool = false,     // 關閉 log10（相對能量已足夠，避免負值）
                useRelative: Bool = true,   // 預設相對能量，穩定視覺
                emaAlpha: Float? = 0.2,
                gainCalibration: Float = 1.0) {  // 增益校正係數
        self.sampleRate = Float(sampleRate)
        self.windowSize = windowSize
        self.hopSize = hopSize
        self.useLog10 = useLog10
        self.useRelative = useRelative
        self.emaAlpha = emaAlpha
        self.gainCalibration = gainCalibration
        
        // 計算 Hann 窗的功率增益（用於功率譜校正）
        // Hann 窗的總能量增益 ≈ 0.375（相對於矩形窗）
        self.hannPowerGain = 0.375
        
        // FFT setup（radix-2）
        let l2 = Int(round(log2(Double(windowSize))))
        self.log2n = vDSP_Length(l2)
        self.fftSetup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))
        
        // Hann window（normalized）
        self.window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&self.window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
        
        self.ring.reserveCapacity(windowSize * 2)
        
        if debugEnabled {
            print("🔧 [Analyzer] init sr=\(self.sampleRate)Hz, N=\(self.windowSize), hop=\(self.hopSize), log10=\(self.useLog10), relative=\(self.useRelative), ema=\(self.emaAlpha != nil ? "\(self.emaAlpha!)" : "nil"), gainCal=\(gainCalibration)")
        }
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }
    
    // 可以在外部關/開 debug
    public func setDebug(_ enabled: Bool) {
        debugEnabled = enabled
    }
    
    // MARK: - Ingest APIs
    
    public func ingest(raw sample: Int16) {
        // NeuroSky RAW 實際動態範圍約 ±2048（12-bit ADC）
        // 歸一化時應基於此範圍，而非 Int16 全範圍 ±32768
        let x = Float(sample) / 2048.0  // 正確的 μV 對映範圍
        ring.append(x)
        
        // 🔍 Print 第一個樣本和每 512 個樣本（1 秒）
        if debugEnabled && (ring.count == 1 || ring.count % 512 == 0) {
            print("🧪 [Analyzer] ingest raw: sample=\(sample) → normalized=\(String(format: "%.4f", x)) | ring=\(ring.count)/\(windowSize)")
        }
        
        while ring.count >= windowSize {
            let frame = Array(ring.prefix(windowSize))
            ring.removeFirst(hopSize)
            processFrame(frame)
        }
    }
    
    public func ingest(eSenseAttention: UInt8?, meditation: UInt8?, quality: UInt8?) {
        let frame = ESenseFrame(attention: eSenseAttention, meditation: meditation, quality: quality)
        esenseContinuations.forEach { $0.yield(frame) }
    }
    
    /// 直接注入 0x83 八段（UInt32）
    public func ingest(eightBands bands: [String: UInt32]?) {
        guard let bands = bands else { return }
        var floats = bands.mapValues { Float($0) }
        if debugEnabled {
            let keys = floats.keys.sorted()
            let sample = keys.prefix(3).map { "\($0)=\(floats[$0] ?? 0)" }.joined(separator: ", ")
            print("📥 [Analyzer] ingest 0x83 eightBands keys=\(keys.count) sample{\(sample)}")
        }
        
        // 對注入的 8 波數據進行相對能量歸一化（如果啟用）
        if useRelative {
            let sum = floats.values.reduce(0, +)
            if sum > 1e-9 {
                for k in floats.keys {
                    floats[k]! /= sum
                }
            }
        }
        
        // 應用地板值（防止 log10 出現負無窮或過小值）
        for k in floats.keys {
            floats[k] = max(floats[k] ?? 0, powerFloor)
        }
        
        postprocessAndEmit(&floats)
    }
    
    // MARK: - Processing
    
    private func processFrame(_ frame: [Float]) {
        guard frame.count == windowSize, let fftSetup else { return }
        frameCounter &+= 1
        
        // 去 DC
        var mean: Float = 0
        frame.withUnsafeBufferPointer { fp in
            vDSP_meanv(fp.baseAddress!, 1, &mean, vDSP_Length(windowSize))
        }
        var detrended = [Float](repeating: 0, count: windowSize)
        frame.withUnsafeBufferPointer { fp in
            var m = -mean
            vDSP_vsadd(fp.baseAddress!, 1, &m, &detrended, 1, vDSP_Length(windowSize))
        }
        
        // 乘上窗
        var windowed = [Float](repeating: 0, count: windowSize)
        detrended.withUnsafeBufferPointer { dp in
            window.withUnsafeBufferPointer { wp in
                windowed.withUnsafeMutableBufferPointer { outp in
                    vDSP_vmul(dp.baseAddress!, 1,
                              wp.baseAddress!, 1,
                              outp.baseAddress!, 1,
                              vDSP_Length(windowSize))
                }
            }
        }
        
        // zrip 打包：real=偶數、imag=奇數
        let halfN = windowSize / 2
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        windowed.withUnsafeBufferPointer { wp in
            let base = wp.baseAddress!
            for k in 0..<halfN {
                real[k] = base[2 * k]
                imag[k] = base[2 * k + 1]
            }
        }
        var split = DSPSplitComplex(realp: &real, imagp: &imag)
        
        // 前向 FFT
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        
        // 功率譜（0..Nyquist）
        // 注意：vDSP FFT 不自動做 1/N 尺度，需手動校正
        var powerBins = [Float](repeating: 0, count: halfN + 1)
        
        // DC (單邊頻譜)
        powerBins[0] = real[0] * real[0]
        
        // 常規頻率 bins (雙邊頻譜，需 ×2)
        if halfN > 1 {
            for k in 1..<halfN {
                let r = real[k], im = imag[k]
                powerBins[k] = (r * r + im * im) * 2.0  // 雙邊頻譜校正
            }
        }
        
        // Nyquist (單邊頻譜)
        powerBins[halfN] = imag[0] * imag[0]
        
        // FFT 尺度校正：vDSP 的 FFT 輸出需除以 N
        var fftScale = 1.0 / Float(windowSize)
        vDSP_vsmul(powerBins, 1, &fftScale, &powerBins, 1, vDSP_Length(powerBins.count))
        
        // Hann 窗功率增益校正（可選，用於跨方法比較）
        // 相對能量模式下影響較小，但保持數值一致性
        var windowScale = 1.0 / hannPowerGain
        vDSP_vsmul(powerBins, 1, &windowScale, &powerBins, 1, vDSP_Length(powerBins.count))
        
        // 增益校正（用於與硬體對齊）
        if gainCalibration != 1.0 {
            var gainScale = gainCalibration
            vDSP_vsmul(powerBins, 1, &gainScale, &powerBins, 1, vDSP_Length(powerBins.count))
        }

        
        // 頻段積分（使用部分 bin 加權以精確處理非整數邊界）
        let binHz = sampleRate / Float(windowSize)  // 1 Hz/bin for 512Hz/512pt
        var bands: [String: Float] = [:]
        
        /// 精確頻段積分：對邊界 bin 進行線性插值加權
        /// 例如：0.5 Hz = bin[0] 的 50%，2.75 Hz = bin[2] 的 75%
        /// 特別處理 DC (bin[0]) 和 Nyquist (bin[halfN]) 的單邊特性
        func sumBandWeighted(_ loHz: Float, _ hiHz: Float) -> Float {
            // 計算精確的 bin 位置（浮點數）
            let loF = loHz / binHz
            let hiF = hiHz / binHz
            
            // 起始和結束的整數 bin
            let loIdx = Int(floor(loF))
            let hiIdx = Int(floor(hiF))
            
            // 邊界檢查
            if hiIdx < loIdx || loIdx >= halfN { return 0 }
            let safeLoIdx = max(0, loIdx)
            let safeHiIdx = min(halfN - 1, hiIdx)
            
            var acc: Float = 0
            
            // 處理起始 bin（可能只取部分）
            if safeLoIdx == loIdx && loIdx < halfN {
                let loWeight = 1.0 - (loF - Float(loIdx))  // 高頻部分的權重
                
                // 特別處理 bin[0] (DC)：如果 loHz = 0.5，只取 50%
                // 這樣可以排除 0-0.5 Hz 的超低頻成分
                if loIdx == 0 && loHz > 0 {
                    // bin[0] 代表 0-1 Hz，若起始於 0.5 Hz，只取上半部
                    acc += powerBins[0] * loWeight
                } else {
                    acc += powerBins[safeLoIdx] * loWeight
                }
            }
            
            // 中間完整的 bins
            if safeHiIdx > safeLoIdx {
                for k in (safeLoIdx + 1)...safeHiIdx {
                    if k < halfN {
                        acc += powerBins[k]
                    }
                }
            }
            
            // 處理結束 bin（可能只取部分）
            if safeHiIdx == hiIdx && hiIdx < halfN - 1 {
                let hiWeight = hiF - Float(hiIdx)  // 低頻部分的權重
                acc += powerBins[safeHiIdx + 1] * hiWeight
            }
            
            return acc
        }
        
        let bandDefs: [(alias: String, lo: Float, hi: Float)] = [
            ("delta",     0.5,   2.75),
            ("theta",     3.5,   6.75),
            ("lowAlpha",  7.5,   9.25),
            ("highAlpha", 10.0, 11.75),
            ("lowBeta",   13.0, 16.75),
            ("highBeta",  18.0, 29.75),
            ("lowGamma",  31.0, 39.75),
            ("midGamma",  41.0, 49.75)
        ]
        for def in bandDefs {
            bands[def.alias] = sumBandWeighted(def.lo, def.hi)
        }
        
        // 相對能量（可選）
        var sumBeforeNorm = bands.values.reduce(0, +)
        if useRelative {
            if sumBeforeNorm > 1e-9 {
                for k in bands.keys {
                    bands[k]! /= sumBeforeNorm
                }
            }
        }
        
        // 降噪：對數前做地板
        for k in bands.keys {
            bands[k] = max(bands[k] ?? 0, powerFloor)
        }
        
        // Debug（節流印）
        if debugEnabled && (frameCounter % printEveryNFrames == 0) {
            let now = Date().timeIntervalSince1970
            if now - lastPrintTime > 0.25 {
                lastPrintTime = now
                
                // Parseval 定理驗證：時域能量 = 頻域能量
                var timeDomainEnergy: Float = 0
                frame.withUnsafeBufferPointer { fp in
                    var sum: Float = 0
                    vDSP_svesq(fp.baseAddress!, 1, &sum, vDSP_Length(windowSize))
                    timeDomainEnergy = sum / Float(windowSize)
                }
                let freqDomainEnergy = powerBins.reduce(0, +)
                let parsevalError = abs(timeDomainEnergy - freqDomainEnergy) / max(timeDomainEnergy, 1e-9)
                
                let dc = powerBins.first ?? 0
                let ny = powerBins.last ?? 0
                let delta = bands["delta"] ?? -1
                let lAlpha = bands["lowAlpha"] ?? -1
                let hAlpha = bands["highAlpha"] ?? -1
                let hBeta = bands["highBeta"] ?? -1
                print(String(format: "📊 [Analyzer] frame#%d mean=%.5f DC=%.5f Ny=%.5f sum=%.5f delta=%.5f lowAlpha=%.5f highAlpha=%.5f highBeta=%.5f | 🔬Parseval: 時域=%.5f 頻域=%.5f 誤差=%.2f%%",
                             frameCounter, mean, dc, ny, sumBeforeNorm, delta, lAlpha, hAlpha, hBeta, timeDomainEnergy, freqDomainEnergy, parsevalError * 100))
            }
        }
        
        // 後處理（log/EMA）並送出
        postprocessAndEmit(&bands)
    }
    
    private func postprocessAndEmit(_ bands: inout [String: Float]) {
        // log10（可選）
        if useLog10 {
            for k in bands.keys {
                bands[k] = log10f(bands[k]!)
            }
        }
        // EMA 平滑（可選）
        if let alpha = emaAlpha {
            for k in bands.keys {
                let prev = lastSmoothed[k] ?? bands[k]!
                let cur = bands[k]!
                let smoothed = alpha * cur + (1 - alpha) * prev
                lastSmoothed[k] = smoothed
                bands[k] = smoothed
            }
        }
        if debugEnabled {
            let delta = bands["delta"] ?? -1
            let lAlpha = bands["lowAlpha"] ?? -1
            let hBeta = bands["highBeta"] ?? -1
            let allBands = bands.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.4f", $0.value))" }.joined(separator: " ")
            print("➡️  [Analyzer] emit bands (FFT分析): \(allBands)")
        }
        bandContinuations.forEach { $0.yield(BandFrame(bands: bands)) }
    }
}

