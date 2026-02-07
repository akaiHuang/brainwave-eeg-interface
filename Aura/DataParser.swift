//
//  DataParser.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/14.
//

import Foundation

struct BrainwaveData {
    let timestamp: Date
    let values: [Double]
    let rawData: Data
}

class DataParser {
    static func parseBrainwaveData(_ data: Data) -> BrainwaveData? {
        guard !data.isEmpty else { return nil }
        
        // 這裡需要根據你的腦波設備的數據格式來調整
        // 以下是一個通用的解析示例
        
        let bytes = Array(data)
        var values: [Double] = []
        
        // 假設每2個字節組成一個16位整數
        for i in stride(from: 0, to: bytes.count - 1, by: 2) {
            let lowByte = UInt16(bytes[i])
            let highByte = UInt16(bytes[i + 1])
            let rawValue = (highByte << 8) | lowByte
            
            // 轉換為電壓值（假設參考電壓為3.3V，12位ADC）
            let voltage = Double(rawValue) * 3.3 / 4095.0
            values.append(voltage)
        }
        
        return BrainwaveData(
            timestamp: Date(),
            values: values,
            rawData: data
        )
    }
    
    static func parseEEGData(_ data: Data) -> [Double] {
        // 專門用於EEG數據的解析
        let bytes = Array(data)
        var samples: [Double] = []
        
        // 假設是單字節數據，範圍0-255，轉換為-1到1的範圍
        for byte in bytes {
            let normalized = (Double(byte) / 255.0) * 2.0 - 1.0
            samples.append(normalized)
        }
        
        return samples
    }
    
    static func calculateFFT(_ samples: [Double]) -> [Double] {
        // 這裡可以實現FFT計算，用於頻域分析
        // 為了簡化，這裡返回模擬的頻譜數據
        let frequencies = Array(0..<samples.count/2).map { _ in Double.random(in: 0...1) }
        return frequencies
    }
}