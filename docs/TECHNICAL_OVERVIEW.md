# Aura 技術文檔總覽

> 本文檔整合了所有技術細節，包含 NeuroSky 規格、FFT 分析、硬體對齊、模擬數據等內容。

---

## 📚 目錄

1. [NeuroSky 規格說明](#neurosky-規格說明)
2. [FFT 分析實作](#fft-分析實作)
3. [工程級優化](#工程級優化)
4. [硬體對齊](#硬體對齊)
5. [模擬數據](#模擬數據)
6. [波形顯示](#波形顯示)
7. [問題診斷與修復](#問題診斷與修復)

---

## NeuroSky 規格說明

### RAW EEG 數據格式

**基本規格**：
- **採樣率**: 512 Hz
- **數據格式**: Int16（大端序）
- **數值範圍**: -2048 ~ +2048
- **實際動態範圍**: 12-bit ADC
- **電壓轉換**: V = [rawValue × (1.8 / 4096)] / 2000 μV

**ThinkGear 協定**：
```
0xAA 0xAA [PLENGTH] [PAYLOAD...] [CHECKSUM]

RAW 數據包 (0x80):
0xAA 0xAA 0x04 0x80 0x02 [HIGH] [LOW] [CHECKSUM]
```

**解析示例**：
```swift
// 大端序解析
let highByte = data[i]
let lowByte = data[i + 1]
let combined = (Int(highByte) << 8) | Int(lowByte)

// 符號擴展
let rawValue: Int16 = combined > 32767 ? Int16(combined - 65536) : Int16(combined)

// 歸一化到 ±1.0（用於顯示）
let normalized = Double(rawValue) / 2048.0
```

### 8 段頻帶能量

**頻段劃分**（NeuroSky ASIC 規格）：

| 頻段 | 頻率範圍 (Hz) | 說明 |
|------|--------------|------|
| Delta | 0.5 - 2.75 | 深度睡眠 |
| Theta | 3.5 - 6.75 | 淺睡、冥想 |
| Low Alpha | 7.5 - 9.25 | 放鬆前期 |
| High Alpha | 10.0 - 11.75 | 深度放鬆 |
| Low Beta | 13.0 - 16.75 | 專注前期 |
| High Beta | 18.0 - 29.75 | 高度專注 |
| Low Gamma | 31.0 - 39.75 | 認知處理 |
| Mid Gamma | 41.0 - 49.75 | 高階認知 |

**數據格式**：
- 0x83 包：8 個 UInt32（3 bytes each，24-bit）
- 輸出頻率：1 Hz（每秒 1 次）
- 歸一化：相對能量（總和 = 1.0）

---

## FFT 分析實作

### 核心算法

**EEGAnalyzer.swift** 使用 Accelerate 框架實作：

```swift
// 參數配置
sampleRate: 512 Hz
windowSize: 512 samples
hopSize: 512 samples (100% 跳躍，對齊 NeuroSky 1 Hz 輸出)
window: Hann (vDSP_hann_window)
useRelative: true (相對能量歸一化)
```

**處理流程**：

```
1. 去 DC (移除平均值)
   vDSP_meanv() → vDSP_vsadd()

2. 加窗 (Hann 窗)
   vDSP_vmul(signal, window)

3. FFT (實數 FFT)
   zrip 打包 → vDSP_fft_zrip()

4. 功率譜計算
   DC: powerBins[0] = real[0]²
   1~N/2-1: powerBins[k] = (real[k]² + imag[k]²) × 2.0 (雙邊校正)
   Nyquist: powerBins[N/2] = imag[0]²

5. FFT 尺度校正
   powerBins × (1/N)

6. Hann 窗功率校正
   powerBins × (1/0.375)

7. 頻段積分 (部分 bin 加權)
   sumBandWeighted(loHz, hiHz)

8. 歸一化 (相對能量)
   bands[k] /= sum(bands)
```

### 工程級優化

#### 1. 部分 Bin 加權

**問題**：頻段邊界不在整數 bin 位置（0.5 Hz, 2.75 Hz...）

**解決**：線性插值加權
```swift
// Delta: 0.5 - 2.75 Hz
// bin[0] = 0-1 Hz，只取 0.5-1 Hz 部分 (50%)
let loWeight = 1.0 - (0.5 - 0.0) = 0.5
acc += powerBins[0] × 0.5

// bin[2] = 2-3 Hz，只取 2-2.75 Hz 部分 (75%)
let hiWeight = 2.75 - 2.0 = 0.75
acc += powerBins[2] × 0.75
```

#### 2. Hann 窗 ENBW 校正

**問題**：Hann 窗等效雜訊頻寬 ≈ 1.5 bins，功率增益 ≈ 0.375

**解決**：
```swift
let hannPowerGain: Float = 0.375
var windowScale = 1.0 / hannPowerGain
vDSP_vsmul(powerBins, 1, &windowScale, &powerBins, 1, ...)
```

#### 3. 雙邊頻譜校正

**問題**：實數 FFT 的 bin[1~N/2-1] 包含正負頻率

**解決**：
```swift
// DC 和 Nyquist：單邊
powerBins[0] = real[0]²
powerBins[N/2] = imag[0]²

// 常規頻率：雙邊，需 ×2
for k in 1..<N/2 {
    powerBins[k] = (real[k]² + imag[k]²) × 2.0
}
```

#### 4. Parseval 定理驗證

**驗證能量守恆**：
```swift
時域能量 = Σ(sample²) / N
頻域能量 = Σ(powerBins)

誤差 = |時域 - 頻域| / 時域 < 1% ✅
```

---

## 硬體對齊

### 對齊策略

1. **輸出頻率**：1 Hz（與 NeuroSky ASIC 一致）
2. **RAW 歸一化**：±2048（而非 ±32768）
3. **相對能量**：總和歸一化到 1.0
4. **頻段劃分**：精確對齊 NeuroSky 規格

### 驗證結果

**測試條件**：
- 真實 NeuroSky Mind Link 設備
- 同時接收 RAW 和 0x83 八段數據
- 比對 FFT 分析結果 vs 硬體輸出

**誤差範圍**：
- 主要頻段（alpha, beta）: < 5%
- 次要頻段（delta, theta）: < 10%
- 高頻段（gamma）: < 15%（能量低，相對誤差大）

**剩餘差異來源**：
- 濾波器實作差異（FFT vs. IIR）
- 窗函數差異
- 採樣誤差

---

## 模擬數據

### SimulatedDataSource.swift

**RAW 數據生成**（符合 NeuroSky 規格）：

```swift
// 512 Hz 採樣率
sampleRate: 512.0

// 每次產生 10 個樣本，間隔 0.0195 秒
samplesPerBatch: 10
timerInterval: 10 / 512 ≈ 0.0195s

// 合成多個頻段
let delta  = sin(2.0 × phase) × 150.0   // 2 Hz
let theta  = sin(5.0 × phase) × 200.0   // 5 Hz
let alpha  = sin(10.0 × phase) × 400.0  // 10 Hz (主要)
let beta   = sin(20.0 × phase) × 250.0  // 20 Hz
let gamma  = sin(35.0 × phase) × 100.0  // 35 Hz

// 限制在 NeuroSky 範圍
let rawValue = max(-2048, min(2048, combined))

// 編碼為大端序
data.append(UInt8((rawValue >> 8) & 0xFF))  // 高位元組
data.append(UInt8(rawValue & 0xFF))         // 低位元組
```

**8 波直接生成**（對齊 RAW 功率分佈）：

```swift
// 基於 RAW 頻率成分的功率計算
// 振幅²: delta=22500(8%), theta=40000(14%), alpha=160000(54%), 
//        beta=62500(21%), gamma=10000(3%)

bands["delta"]     = modulation(..., baseLevel: 0.08, ...)
bands["theta"]     = modulation(..., baseLevel: 0.14, ...)
bands["lowAlpha"]  = modulation(..., baseLevel: 0.05, ...)
bands["highAlpha"] = modulation(..., baseLevel: 0.52, ...)  // 主導
bands["lowBeta"]   = modulation(..., baseLevel: 0.03, ...)
bands["highBeta"]  = modulation(..., baseLevel: 0.20, ...)
bands["lowGamma"]  = modulation(..., baseLevel: 0.03, ...)
bands["midGamma"]  = modulation(..., baseLevel: 0.01, ...)
```

### 一致性驗證

**測試結果**：
- 直接模擬：highAlpha = 0.52
- FFT 分析：highAlpha = 0.54
- 差異：|0.54 - 0.52| = 0.02 < 0.05 ✅

---

## 波形顯示

### WaveformBuffer.swift

**數據管理**：
```swift
maxSamples: 2000  // 顯示最近 2000 個樣本
updateInterval: 無節流（已移除）
```

**重要修復**：移除了錯誤的節流邏輯
```swift
// 修復前（錯誤）
guard now.timeIntervalSince(lastUpdateTime) >= updateInterval else {
    return  // ❌ 丟棄數據，導致波形速度減半
}

// 修復後（正確）
DispatchQueue.main.async {
    self.samples.append(contentsOf: values)
    // SwiftUI 自動合併更新，不需要手動節流
}
```

### WaveformView.swift

**功能**：
- 自動縮放（autoScale）
- 網格顯示（showGrid）
- 平滑曲線（smooth）
- 面積填充（showFill）
- 顏色自訂（baseColor, overlayColor）
- 降採樣顯示（getDownsampledData）

---

## 問題診斷與修復

### 問題 1: 模擬數據 8 波不一致

**症狀**：
- RAW → FFT 分析：highAlpha = 0.54
- 直接模擬 8 波：highAlpha = 0.25
- 差異：115% ❌

**原因**：
- 模擬 RAW 包含 10 Hz alpha (振幅 400 → 功率 54%)
- 但直接模擬 8 波設定 highAlpha = 0.25
- 兩者不匹配

**修復**：
- 重新計算模擬 8 波的基準值
- 對齊到 RAW 數據的功率分佈
- highAlpha: 0.25 → 0.52

**結果**：差異從 115% 降到 4% ✅

---

### 問題 2: 波形前進速度變慢

**症狀**：
- 開啟「分析 Raw」後波形速度減半
- CPU 從 120% 降到 40%

**原因**：
- WaveformBuffer 節流邏輯錯誤
- 每 0.0195s 產生數據，但每 0.0333s 才接受
- 每 2 次調用丟棄 1 次數據

**修復**：
- 移除 `updateInterval` 和 `lastUpdateTime`
- 移除節流檢查，讓所有數據進入
- SwiftUI 自動合併更新

**結果**：
- 波形速度恢復正常 ✅
- CPU 降到 60-80%（合理）
- 數據完整性 100% ✅

---

### 問題 3: LED 綠燈不穩定

**症狀**：
- 連接後綠燈頻繁閃爍

**原因**：
- EEG watchdog 超時時間過短（1.5 秒）
- 正常情況下也可能 1.5 秒沒收到指標

**修復**：
- 延長超時時間：1.5 秒 → 3.0 秒
- 減少誤判

---

### 問題 4: 教學卡片未隱藏

**症狀**：
- 連接後教學卡片仍顯示

**原因**：
- 只檢查 `!isConnected`
- 連線中（connecting）狀態仍顯示

**修復**：
```swift
// 修復前
if !mindLinkManager.isConnected {

// 修復後
if !mindLinkManager.isConnected && mindLinkManager.connectionState != .connecting {
```

---

### 問題 5: 設定按鈕跳轉錯誤

**症狀**：
- 點擊「前往設定」跳到 App 設定
- 應該跳到系統藍牙設定

**原因**：
- 使用 `UIApplication.openSettingsURLString`

**修復**：
```swift
// 修復前
URL(string: UIApplication.openSettingsURLString)

// 修復後
URL(string: "App-prefs:Bluetooth")
```

---

## 📊 性能指標

### CPU 使用率

| 模式 | CPU | 說明 |
|------|-----|------|
| 關閉模擬 | 5-10% | 僅 UI 運行 |
| 模擬 Raw（無分析） | 60-80% | Timer + UI 更新 |
| 模擬 Raw（有分析） | 40-60% | FFT 背景執行，UI 更新頻率低 |

### 記憶體使用

| 組件 | 大小 | 說明 |
|------|------|------|
| WaveformBuffer | ~16 KB | 2000 樣本 × 8 bytes |
| FFT Window | ~2 KB | 512 float × 4 bytes |
| Ring Buffer | ~2-4 KB | 512-1024 樣本 |
| 總計 | ~20-25 KB | 極低記憶體使用 |

---

## 🔧 開發建議

### 測試流程

1. **基本功能測試**
   - 開啟模擬數據
   - 檢查波形顯示
   - 檢查 8 波數值

2. **一致性測試**
   - 關閉分析：記錄 8 波
   - 開啟分析：記錄 8 波
   - 計算差異 < 5%

3. **性能測試**
   - CPU < 80%
   - 記憶體 < 50 MB
   - 波形流暢（60 FPS）

### 除錯技巧

1. **Console 輸出分析**
   ```
   📤 [SimulatedData] - 數據產生
   🔧 [VM] - 數據處理
   🔬 [Analyzer] - FFT 分析
   📈 [WF] - 波形緩衝
   📊 [VM] - UI 更新
   ```

2. **Parseval 驗證**
   ```
   🔬Parseval: 時域=0.456 頻域=0.456 誤差=0.01%
   ```
   - 誤差 < 1% → FFT 正確 ✅
   - 誤差 > 5% → 檢查尺度校正 ❌

3. **數值合理性**
   ```
   highAlpha ≈ 0.5-0.6 → 正常（放鬆狀態）
   delta > 0.8 → 異常（睡眠/閉眼）
   所有頻段 = 0 → 無數據
   ```

---

**最後更新**: 2025年10月17日  
**版本**: v1.0  
**作者**: Aura Development Team
