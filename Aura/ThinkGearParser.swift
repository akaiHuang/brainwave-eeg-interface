//
//  ThinkGearParser.swift
//  Aura
//
//  Created by Stub to satisfy BrainwaveViewModel interfaces.
//

import Foundation

/// 對齊 BrainwaveViewModel 期待的事件型別
public struct TGEvent {
    public var rawSamples: [Int16]        // 0x80 收到的 raw（每筆 Int16）
    public var bands: [String: UInt32]?   // 0x83 八頻段
    public var attention: UInt8?          // 0x04
    public var meditation: UInt8?         // 0x05
    public var poorSignal: UInt8?         // 0x02（0~200，200=最差）
    
    public init(rawSamples: [Int16] = [],
                bands: [String: UInt32]? = nil,
                attention: UInt8? = nil,
                meditation: UInt8? = nil,
                poorSignal: UInt8? = nil) {
        self.rawSamples = rawSamples
        self.bands = bands
        self.attention = attention
        self.meditation = meditation
        self.poorSignal = poorSignal
    }
}

/// 最小可編譯版本：parseChunk 回傳 [TGEvent]
/// 目前先回空陣列，確保編譯通過；之後再補上協定解析（0xAA 0xAA / length / payload / checksum）
public final class ThinkGearParser {
    public init() {}

    public func parseChunk(_ data: Data) -> [TGEvent] {
        // TODO: 解析 ThinkGear 協定，產生 TGEvent 陣列
        return []
    }
}

