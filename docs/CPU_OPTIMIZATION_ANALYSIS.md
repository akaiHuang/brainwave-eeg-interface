# CPU 120-140% 問題診斷與 GPU 優化方案

## 🔍 問題診斷：為什麼未開啟分析時 CPU 120-140%？

### 根本原因分析

#### 問題 1: Timer 頻率過高 + 主線程阻塞

**SimulatedDataSource.swift** line 51-58:
```swift
let timerInterval = Double(samplesPerBatch) / sampleRate
// = 10 / 512 ≈ 0.0195 秒 = 19.5 毫秒

let t = Timer(timeInterval: timerInterval, repeats: true) { [weak self] in
    self.generateSimulatedBrainwaveData(count: samplesPerBatch)
    self.generateSimulatedBands()  // ← 每 19.5ms 調用一次！
}
RunLoop.main.add(t, forMode: RunLoop.Mode.common)  // ← 主線程！
```

**計算實際負載**：
```
Timer 觸發頻率: 1 / 0.0195 ≈ 51.2 Hz

每次觸發執行：
1. generateSimulatedBrainwaveData() - 生成 10 個樣本
   • 5 個 sin() 計算（delta, theta, alpha, beta, gamma）
   • 10 次循環
   • Data 編碼（20 bytes）
   • ≈ 0.5-1 ms

2. generateSimulatedBands() - 生成 8 段能量
   • 8 個 modulation() 調用
     - 每個包含 Date(), sin(), random()
   • 歸一化計算
   • String format（print）
   • ≈ 2-3 ms

3. bandSubject.send() - Combine Publisher
   • 立即在主線程觸發所有訂閱者
   • BrainwaveViewModel 處理
   • SwiftUI 狀態更新
   • UI 重繪
   • ≈ 5-10 ms

總計每次: 7.5-14 ms
頻率: 51.2 Hz
理論 CPU 負載: 7.5-14 ms × 51.2 = 384-716 ms/秒 = 38-72% (單核)
```

**但為什麼實際達到 120-140%？**

#### 問題 2: SwiftUI 過度重繪

**BrainwaveViewModel.swift** 訂閱 bandPublisher:
```swift
simBandsCancellable = simulator?.bandPublisher
    .sink { [weak self] bands in
        self?.bandPowers = bands  // ← @Published 屬性
    }
```

**級聯效應**：
```
bandPublisher 發送 (51.2 Hz)
  ↓
BrainwaveViewModel.bandPowers 更新 (@Published)
  ↓
所有訂閱此屬性的 View 重繪：
  • DataDisplayView
    - BandPowersCard (8 個 ProgressView)
    - WaveformPreviewCard
    - StatisticsCard
  • ContentView (MindLinkStatusBadge)
  ↓
SwiftUI 佈局引擎計算
  ↓
每次重繪 ≈ 10-20 ms
  ↓
實際負載: 10-20 ms × 51.2 = 512-1024 ms/秒 = 51-102% (單核)

加上主線程其他工作 + Timer 自身開銷 → 120-140% CPU
```

#### 問題 3: 不必要的高頻更新

**NeuroSky 真實設備**：
- RAW 數據：512 Hz
- 8 段能量：**1 Hz**（每秒 1 次）

**當前模擬**：
- RAW 數據：512 Hz ✅
- 8 段能量：**51.2 Hz**（每秒 51 次）❌ **過度 51 倍！**

---

## ✅ 優化方案

### 方案 1: 降低 8 波更新頻率（推薦，立即見效）

**原理**：8 波能量變化緩慢，不需要 51.2 Hz 更新

**實作**：

```swift
// SimulatedDataSource.swift
final class SimulatedDataSource: ObservableObject {
    private var timer: Timer?
    private var bandUpdateCounter: Int = 0
    private let bandUpdateInterval: Int = 51  // 每 51 次 RAW 更新，才更新 1 次 8 波 (≈1 Hz)
    
    func startGenerating() {
        // ...
        let t = Timer(timeInterval: timerInterval, repeats: true) { [weak self] in
            guard let self else { return }
            self.generateSimulatedBrainwaveData(count: samplesPerBatch)
            
            // 只在特定次數才更新 8 波（降低頻率）
            self.bandUpdateCounter += 1
            if self.bandUpdateCounter >= self.bandUpdateInterval {
                self.generateSimulatedBands()
                self.bandUpdateCounter = 0
            }
        }
        // ...
    }
}
```

**效果**：
- 8 波更新：51.2 Hz → **1 Hz**（對齊真實設備）
- CPU 預估：120-140% → **30-50%**
- UI 仍流暢（8 波變化本來就慢）

---

### 方案 2: 背景線程生成數據

**原理**：將計算移出主線程

**實作**：

```swift
// SimulatedDataSource.swift
final class SimulatedDataSource: ObservableObject {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.aura.simulator", qos: .userInitiated)
    
    func startGenerating() {
        guard !isGenerating else { return }
        isGenerating = true
        sampleIndex = 0
        
        let samplesPerBatch = 10
        let timerInterval = Double(samplesPerBatch) / sampleRate
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: timerInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            
            // 在背景線程生成數據
            let rawData = self.generateSimulatedBrainwaveData(count: samplesPerBatch)
            
            // 發送到主線程
            DispatchQueue.main.async {
                self.dataSubject.send(rawData)
            }
            
            // 降頻更新 8 波
            self.bandUpdateCounter += 1
            if self.bandUpdateCounter >= self.bandUpdateInterval {
                let bands = self.generateSimulatedBandsSync()
                DispatchQueue.main.async {
                    self.bandSubject.send(bands)
                }
                self.bandUpdateCounter = 0
            }
        }
        timer.resume()
        self.timer = timer
    }
    
    private func generateSimulatedBrainwaveData(count: Int) -> Data {
        // 返回 Data 而非直接 send
        // ... (原本的邏輯)
        return data
    }
    
    private func generateSimulatedBandsSync() -> [String: Float] {
        // 返回字典而非直接 send
        // ... (原本的邏輯)
        return bands
    }
}
```

**效果**：
- 主線程負載大幅降低
- CPU 分散到背景線程
- UI 更流暢

---

### 方案 3: 使用 AsyncStream 替代 Combine

**原理**：現代異步 API，性能更優

**實作**：

```swift
// SimulatedDataSource.swift
final class SimulatedDataSource: ObservableObject {
    // 替換 Publisher 為 AsyncStream
    private var dataContinuation: AsyncStream<Data>.Continuation?
    private var bandContinuation: AsyncStream<[String: Float]>.Continuation?
    
    var dataStream: AsyncStream<Data> {
        AsyncStream { continuation in
            self.dataContinuation = continuation
        }
    }
    
    var bandStream: AsyncStream<[String: Float]> {
        AsyncStream { continuation in
            self.bandContinuation = continuation
        }
    }
    
    func startGenerating() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            
            let interval = UInt64(0.0195 * 1_000_000_000)  // 納秒
            var counter = 0
            
            while !Task.isCancelled {
                let data = await self.generateData()
                self.dataContinuation?.yield(data)
                
                counter += 1
                if counter >= 51 {
                    let bands = await self.generateBands()
                    self.bandContinuation?.yield(bands)
                    counter = 0
                }
                
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }
}
```

**效果**：
- 更現代的異步模式
- 更好的背壓處理
- 減少 Combine 開銷

---

## 🎮 GPU 運算方案

### 問題：GPU 對本專案幫助有限

**原因**：

1. **計算量不足**：
   ```
   RAW 生成：10 個 sin() + 編碼 ≈ 0.5 ms
   8 波生成：8 個 modulation() ≈ 2 ms
   FFT 分析：512 點 FFT ≈ 1-2 ms (Accelerate 已高度優化)
   ```
   GPU 啟動開銷 > 實際計算時間

2. **數據傳輸開銷**：
   ```
   CPU → GPU 記憶體拷貝 ≈ 1-5 ms
   GPU 計算 ≈ 0.1-0.5 ms
   GPU → CPU 記憶體拷貝 ≈ 1-5 ms
   總計 ≈ 2-10.5 ms > 直接 CPU 計算 (2-3 ms)
   ```

3. **適合 GPU 的場景**：
   - 大量平行計算（數千到數百萬次）
   - 矩陣運算（神經網路、圖像處理）
   - 本專案：512 個樣本 FFT（太小）

### 如果仍想使用 GPU（Metal）

**適用場景**：
- 頻譜圖視覺化（數千點）
- 即時濾波器（IIR, FIR）
- 機器學習推論（Core ML）

**實作範例**（Metal FFT）：

```swift
import Metal
import MetalPerformanceShaders

class MetalFFTProcessor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var fftDescriptor: MPSMatrixCopyDescriptor?
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
    }
    
    func performFFT(samples: [Float]) -> [Float]? {
        // Metal FFT 實作
        // 但對於 512 點，Accelerate 可能更快
        // ...
    }
}
```

**建議**：**先優化 CPU 使用（方案 1-3），GPU 對本專案幫助不大**

---

## 🚀 立即優化步驟

### Step 1: 降低 8 波更新頻率（5 分鐘，立即見效）

修改 `SimulatedDataSource.swift`:

```swift
private var bandUpdateCounter: Int = 0
private let bandUpdateInterval: Int = 51  // 512 Hz / 10 samples = 51.2, 取 51

// 在 Timer 回調中：
self.generateSimulatedBrainwaveData(count: samplesPerBatch)

self.bandUpdateCounter += 1
if self.bandUpdateCounter >= self.bandUpdateInterval {
    self.generateSimulatedBands()
    self.bandUpdateCounter = 0
}
```

**預期效果**：CPU 120-140% → **40-60%**

---

### Step 2: 移除不必要的 Print（2 分鐘）

**問題**：每 19.5ms 就 print 一次，Console 輸出也消耗 CPU

```swift
// SimulatedDataSource.swift line 186-187
// 改為每秒只 print 一次
private var lastPrintTime: Date = Date()

func generateSimulatedBands() {
    // ... 原本的邏輯 ...
    
    // 🔍 只在間隔 > 1 秒才 print
    let now = Date()
    if now.timeIntervalSince(lastPrintTime) > 1.0 {
        let preview = bands.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.4f", $0.value))" }.joined(separator: " ")
        print("📊 [SimulatedBands] 直接注入: \(preview)")
        lastPrintTime = now
    }
    
    bandSubject.send(bands)
}
```

**預期效果**：額外降低 5-10% CPU

---

### Step 3: 背景線程生成（15 分鐘）

實作方案 2 的背景線程邏輯。

**預期效果**：主線程負載降低，UI 更流暢

---

## 📊 優化效果預估

| 階段 | 當前 CPU | 優化後 CPU | 改善 |
|------|---------|-----------|------|
| 無優化 | 120-140% | - | - |
| Step 1（降頻） | 120-140% | **40-60%** | ✅ -60% |
| Step 2（減少 print） | 40-60% | **35-55%** | ✅ -5% |
| Step 3（背景線程） | 35-55% | **20-35%** | ✅ -15% |

---

## 🔧 開啟分析後變慢的問題

### 原因分析

**當前流程**：
```
SimulatedDataSource (51.2 Hz)
  ↓ bandPublisher
BrainwaveViewModel
  ↓ @Published bandPowers (51.2 Hz)
UI 更新 (51.2 Hz)
```

**開啟分析後**：
```
SimulatedDataSource (51.2 Hz)
  ↓ dataPublisher (RAW)
BrainwaveViewModel
  ↓ Task.detached { analyzer.ingest() }
EEGAnalyzer (FFT 每 512 樣本 = 1 Hz)
  ↓ bandStream (1 Hz)
BrainwaveViewModel
  ↓ @Published bandPowers (1 Hz) ← 頻率驟降
UI 更新 (1 Hz) ← 感覺變慢
```

**解決方案**：

1. **保持波形獨立更新**（RAW 仍 512 Hz）
2. **8 波低頻更新**（1 Hz）
3. **兩者互不影響**

這是**正確且預期**的行為：
- 波形應該快（512 Hz）
- 8 波應該慢（1 Hz，對齊硬體）

如果您覺得「出圖慢」，可能是指波形更新慢？讓我檢查一下 WaveformBuffer 的當前狀態。

---

## 💡 結論

1. **GPU 不推薦**：計算量太小，開銷 > 收益
2. **立即優化**：降低 8 波更新頻率（51.2 Hz → 1 Hz）
3. **根本優化**：背景線程 + AsyncStream
4. **開啟分析變慢**：這是正確行為（1 Hz 對齊硬體），波形應該仍流暢

---

**建議優先順序**：
1. ⭐⭐⭐ Step 1（降低 8 波頻率）- 立即見效
2. ⭐⭐ Step 2（減少 print）- 簡單有效
3. ⭐ Step 3（背景線程）- 長期優化
4. ❌ GPU 運算 - 不推薦

要我開始實作 Step 1 和 Step 2 嗎？
