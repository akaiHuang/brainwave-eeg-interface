import Foundation

// 為了避免 Swift 6 的 actor 隔離警告，改以檔案層級 DTO（不繼承外部類別的 actor 隔離）
private struct MetricsDTO: Codable {
    let timestamp: Date
    let attention: Int?
    let meditation: Int?
    let signalQuality: Int?
    let powerBands: [String: UInt32]?
}

final class SessionStore {
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "SessionStore.IO")
    
    private var baseURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("AuraSessions", isDirectory: true)
    }
    
    private var indexURL: URL {
        baseURL.appendingPathComponent("sessions_index.json")
    }
    
    // 一個會話的寫入狀態
    private struct CurrentSession {
        let meta: SessionMeta
        let folderURL: URL
        let rawFolderURL: URL
        var metricsHandle: FileHandle?
        var currentChunkHandle: FileHandle?
        var currentChunkIndex: Int = 0
        var samplesInCurrentChunk: Int = 0
        var totalSamples: Int = 0
        let samplesPerChunk: Int // 例如 60 秒一片：sampleRate * 60
    }
    
    private var current: CurrentSession?
    
    // MARK: - Public
    
    func loadIndex() -> [SessionSummary] {
        ioQueue.sync {
            ensureBaseFolder()
            return readIndexUnlocked()
        }
    }
    
    func startSession(meta: SessionMeta) {
        ioQueue.sync {
            ensureBaseFolder()
            let sessionFolder = baseURL.appendingPathComponent(meta.id.uuidString, isDirectory: true)
            let rawFolder = sessionFolder.appendingPathComponent("raw", isDirectory: true)
            do {
                try fileManager.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: rawFolder, withIntermediateDirectories: true)
                
                // 建立 metrics.jsonl
                let metricsURL = sessionFolder.appendingPathComponent("metrics.jsonl")
                fileManager.createFile(atPath: metricsURL.path, contents: nil)
                let metricsHandle = try FileHandle(forWritingTo: metricsURL)
                
                // 準備第一個 raw chunk
                let firstChunkURL = rawFolder.appendingPathComponent(chunkFileName(index: 0))
                fileManager.createFile(atPath: firstChunkURL.path, contents: nil)
                let chunkHandle = try FileHandle(forWritingTo: firstChunkURL)
                
                current = CurrentSession(
                    meta: meta,
                    folderURL: sessionFolder,
                    rawFolderURL: rawFolder,
                    metricsHandle: metricsHandle,
                    currentChunkHandle: chunkHandle,
                    currentChunkIndex: 0,
                    samplesInCurrentChunk: 0,
                    totalSamples: 0,
                    samplesPerChunk: meta.sampleRate * 60 // 每 60 秒一片
                )
                
                // 保存 meta.json
                let metaURL = sessionFolder.appendingPathComponent("meta.json")
                let encoder = JSONEncoder()
                let metaData = try encoder.encode(meta)
                try metaData.write(to: metaURL, options: .atomic)
            } catch {
                print("SessionStore startSession error: \(error)")
                current = nil
            }
        }
    }
    
    func appendRawSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        ioQueue.async {
            guard var cur = self.current else { return }
            do {
                var remaining = samples[...]
                while !remaining.isEmpty {
                    // 需要換片？
                    if cur.samplesInCurrentChunk >= cur.samplesPerChunk {
                        try self.rotateChunk(&cur)
                    }
                    let canWrite = min(cur.samplesPerChunk - cur.samplesInCurrentChunk, remaining.count)
                    let slice = remaining.prefix(canWrite)
                    // 以 little-endian Int16 連續寫入
                    var leData = Data(capacity: slice.count * MemoryLayout<Int16>.size)
                    for v in slice {
                        var le = v.littleEndian
                        withUnsafeBytes(of: &le) { leData.append(contentsOf: $0) }
                    }
                    cur.currentChunkHandle?.write(leData)
                    cur.samplesInCurrentChunk += canWrite
                    cur.totalSamples += canWrite
                    remaining = remaining.dropFirst(canWrite)
                }
                self.current = cur
            } catch {
                print("SessionStore appendRawSamples error: \(error)")
            }
        }
    }
    
    func appendMetrics(_ metrics: SessionMetricsLine) {
        ioQueue.async {
            guard let cur = self.current else { return }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let dto = MetricsDTO(
                    timestamp: metrics.timestamp,
                    attention: metrics.attention,
                    meditation: metrics.meditation,
                    signalQuality: metrics.signalQuality,
                    powerBands: metrics.powerBands
                )
                let data = try encoder.encode(dto)
                if let handle = cur.metricsHandle {
                    handle.write(data)
                    handle.write(Data([0x0A])) // newline
                }
            } catch {
                print("SessionStore appendMetrics error: \(error)")
            }
        }
    }
    
    // 結束會話，回傳摘要（呼叫端可更新 UI/索引）
    func endSession(endTime: Date? = nil) -> SessionSummary? {
        ioQueue.sync {
            guard let cur = current else { return nil }
            do {
                try cur.currentChunkHandle?.close()
                try cur.metricsHandle?.close()
            } catch {
                print("SessionStore endSession close error: \(error)")
            }
            
            let duration: TimeInterval
            if let end = endTime {
                duration = end.timeIntervalSince(cur.meta.startTime)
            } else {
                duration = 0
            }
            let summary = SessionSummary(
                id: cur.meta.id,
                startTime: cur.meta.startTime,
                duration: duration,
                sampleCount: cur.totalSamples,
                deviceName: cur.meta.deviceName,
                sampleRate: cur.meta.sampleRate,
                channels: cur.meta.channels
            )
            self.current = nil
            
            // 在相同 queue 內直接讀取與寫入索引，避免巢狀 sync
            var all = readIndexUnlocked()
            all.append(summary)
            all.sort { $0.startTime > $1.startTime }
            writeIndexUnlocked(all)
            
            return summary
        }
    }
    
    // MARK: - Helpers (unlocked, 要在 ioQueue 內呼叫)
    
    private func ensureBaseFolder() {
        if !fileManager.fileExists(atPath: baseURL.path) {
            try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
    }
    
    private func chunkFileName(index: Int) -> String {
        String(format: "chunk_%06d.bin", index)
    }
    
    private func rotateChunk(_ cur: inout CurrentSession) throws {
        try cur.currentChunkHandle?.close()
        cur.currentChunkIndex += 1
        cur.samplesInCurrentChunk = 0
        let nextURL = cur.rawFolderURL.appendingPathComponent(chunkFileName(index: cur.currentChunkIndex))
        fileManager.createFile(atPath: nextURL.path, contents: nil)
        cur.currentChunkHandle = try FileHandle(forWritingTo: nextURL)
    }
    
    // 只在 ioQueue 內使用，避免再 sync
    private func readIndexUnlocked() -> [SessionSummary] {
        ensureBaseFolder()
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: indexURL)
            let summaries = try JSONDecoder().decode([SessionSummary].self, from: data)
            return summaries.sorted { $0.startTime > $1.startTime }
        } catch {
            print("SessionStore readIndexUnlocked error: \(error)")
            return []
        }
    }
    
    // 只在 ioQueue 內使用
    private func writeIndexUnlocked(_ summaries: [SessionSummary]) {
        do {
            let data = try JSONEncoder().encode(summaries)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("SessionStore writeIndexUnlocked error: \(error)")
        }
    }
}
