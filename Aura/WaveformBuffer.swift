//
//  WaveformBuffer.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/14.
//

import Foundation
import Combine

class WaveformBuffer: ObservableObject {
    @Published var samples: [Double] = []
    @Published var maxValue: Double = 1.0
    @Published var minValue: Double = -1.0
    
    private let maxSamples: Int
    
    init(maxSamples: Int = 1000) {
        self.maxSamples = maxSamples
    }
    
    func addSample(_ value: Double) {
        DispatchQueue.main.async {
            self.samples.append(value)
            if self.samples.count > self.maxSamples {
                self.samples.removeFirst(self.samples.count - self.maxSamples)
            }
            self.updateMinMax()
            print("📈 [WF] addSample 1 -> total=\(self.samples.count)")
        }
    }
    
    func addSamples(_ values: [Double]) {
        // 移除節流檢查，讓所有數據進入緩衝區
        // SwiftUI 的 @Published 和 DispatchQueue.main.async 會自動合併更新
        // 不會造成過度的 UI 刷新
        DispatchQueue.main.async {
            self.samples.append(contentsOf: values)
            if self.samples.count > self.maxSamples {
                let excess = self.samples.count - self.maxSamples
                self.samples.removeFirst(excess)
            }
            self.updateMinMax()
            
            // 減少 print 頻率，避免 Console 輸出過多
            if self.samples.count % 50 == 0 {
                print("📈 [WF] addSamples values=\(values.count) -> total=\(self.samples.count)")
            }
        }
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.samples.removeAll()
            self.maxValue = 1.0
            self.minValue = -1.0
            print("🧹 [WF] 清空樣本")
        }
    }
    
    private func updateMinMax() {
        guard !samples.isEmpty else { return }
        minValue = samples.min() ?? -1.0
        maxValue = samples.max() ?? 1.0
        if abs(maxValue - minValue) < 0.001 {
            maxValue += 0.5
            minValue -= 0.5
        }
    }
    
    // 獲取降採樣的數據，用於繪圖
    func getDownsampledData(targetPoints: Int) -> [Double] {
        guard samples.count > targetPoints else {
            return samples
        }
        let step = Double(samples.count) / Double(targetPoints)
        var downsampledData: [Double] = []
        for i in 0..<targetPoints {
            let index = Int(Double(i) * step)
            if index < samples.count {
                downsampledData.append(samples[index])
            }
        }
        return downsampledData
    }
    
    // 計算統計信息
    func getStatistics() -> WaveformStatistics {
        guard !samples.isEmpty else {
            return WaveformStatistics(mean: 0, rms: 0, peakToPeak: 0, sampleCount: 0)
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Double(samples.count))
        let peakToPeak = maxValue - minValue
        return WaveformStatistics(
            mean: mean,
            rms: rms,
            peakToPeak: peakToPeak,
            sampleCount: samples.count
        )
    }
}

struct WaveformStatistics {
    let mean: Double
    let rms: Double
    let peakToPeak: Double
    let sampleCount: Int
}
