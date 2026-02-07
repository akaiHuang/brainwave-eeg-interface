import Foundation

// 會話基本中繼資料
struct SessionMeta: Codable {
    let id: UUID
    let startTime: Date
    let deviceName: String
    let sampleRate: Int
    let channels: Int
}

// 每秒的指標資料（可擴充）
struct SessionMetricsLine: Codable {
    let timestamp: Date
    let attention: Int?
    let meditation: Int?
    let signalQuality: Int?
    // 頻段能量：以標準鍵命名，值為 32-bit 無號整數（ThinkGear 為 3-byte，落地時轉為 UInt32）
    let powerBands: [String: UInt32]?
}

// 會話摘要（索引用）
struct SessionSummary: Codable, Identifiable {
    let id: UUID
    let startTime: Date
    let duration: TimeInterval
    let sampleCount: Int
    let deviceName: String
    let sampleRate: Int
    let channels: Int
}
