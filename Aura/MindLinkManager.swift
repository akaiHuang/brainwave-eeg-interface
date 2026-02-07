//
//  MindLinkManager.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/15.
//

import Foundation
import ExternalAccessory
import Combine

/// Mind Link (NeuroSky) 裝置管理器
class MindLinkManager: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var connectedAccessory: EAAccessory?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var receivedData: Data?
    @Published var errorMessage: String?
    @Published var availableAccessories: [EAAccessory] = []
    
    private var session: EASession?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private let thinkGearProtocol = "com.neurosky.thinkgear"
    
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    override init() {
        super.init()
        setupAccessoryNotifications()
        updateAvailableAccessories()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        disconnect()
    }
    
    func scanForDevices() {
        updateAvailableAccessories()
        if availableAccessories.isEmpty {
            errorMessage = "未找到 Mind Link 裝置"
            connectionState = .error("未找到裝置")
        } else {
            errorMessage = nil
        }
    }
    
    func connect(to accessory: EAAccessory) {
        disconnect()
        connectionState = .connecting
        errorMessage = nil
        let protocolToUse = accessory.protocolStrings.first ?? thinkGearProtocol
        openSession(for: accessory, protocol: protocolToUse)
    }
    
    func disconnect() {
        inputStream?.close()
        outputStream?.close()
        inputStream?.remove(from: .current, forMode: .default)
        outputStream?.remove(from: .current, forMode: .default)
        inputStream = nil
        outputStream = nil
        session = nil
        connectedAccessory = nil
        isConnected = false
        connectionState = .disconnected
    }
    
    private func setupAccessoryNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidConnect),
            name: .EAAccessoryDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidDisconnect),
            name: .EAAccessoryDidDisconnect,
            object: nil
        )
        EAAccessoryManager.shared().registerForLocalNotifications()
    }
    
    private func updateAvailableAccessories() {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        availableAccessories = accessories.filter { accessory in
            return accessory.protocolStrings.contains(thinkGearProtocol) ||
                   accessory.name.lowercased().contains("mindset") ||
                   accessory.name.lowercased().contains("neurosky") ||
                   accessory.name.lowercased().contains("mindlink")
        }
    }
    
    private func openSession(for accessory: EAAccessory, protocol: String) {
        session = EASession(accessory: accessory, forProtocol: `protocol`)
        guard let session = session else {
            connectionState = .error("無法創建會話")
            return
        }
        
        inputStream = session.inputStream
        outputStream = session.outputStream
        inputStream?.delegate = self
        inputStream?.schedule(in: .current, forMode: .default)
        inputStream?.open()
        outputStream?.delegate = self
        outputStream?.schedule(in: .current, forMode: .default)
        outputStream?.open()
        
        connectedAccessory = accessory
        isConnected = true
        connectionState = .connected
    }
    
    @objc private func accessoryDidConnect(_ notification: Notification) {
        updateAvailableAccessories()
    }
    
    @objc private func accessoryDidDisconnect(_ notification: Notification) {
        if let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory,
           accessory == connectedAccessory {
            disconnect()
        }
        updateAvailableAccessories()
    }
    
    func parseThinkGearData(_ data: Data) -> ThinkGearPacket? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        guard bytes[0] == 0xAA && bytes[1] == 0xAA else { return nil }
        let payloadLength = Int(bytes[2])
        guard bytes.count >= (4 + payloadLength) else { return nil }
        let payload = Array(bytes[3..<(3 + payloadLength)])
        let checksum = bytes[3 + payloadLength]
        
        // 安全的校驗和計算，避免溢出
        var sum: UInt8 = 0
        for byte in payload {
            sum = sum &+ byte  // 使用溢出加法操作符
        }
        let calculatedChecksum = ~sum  // 取反
        
        guard checksum == calculatedChecksum else { 
            print("❌ 校驗和錯誤: 期望 \(String(format: "0x%02X", calculatedChecksum)), 實際 \(String(format: "0x%02X", checksum))")
            return nil 
        }
        return ThinkGearPacket(payload: payload)
    }
}

extension MindLinkManager: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let inputStream = inputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                DispatchQueue.main.async {
                    self.receivedData = data
                }
                print("📶 收到 Mind Link 數據: \(bytesRead) bytes")
                // 只在數據量不太大時打印十六進制，避免日誌過多
                if bytesRead <= 32 {
                    print("   十六進制: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                }
            }
        case .errorOccurred:
            print("❌ 數據流錯誤")
            DispatchQueue.main.async {
                self.connectionState = .error("數據流錯誤")
            }
        case .endEncountered:
            print("🔌 數據流結束")
            DispatchQueue.main.async {
                self.disconnect()
            }
        default:
            break
        }
    }
}

struct ThinkGearPacket {
    let payload: [UInt8]
    
    var poorSignal: UInt8? {
        return getValue(for: 0x02)
    }
    
    var attention: UInt8? {
        return getValue(for: 0x04)
    }
    
    var meditation: UInt8? {
        return getValue(for: 0x05)
    }
    
    var blinkStrength: UInt8? {
        return getValue(for: 0x16)
    }
    
    private func getValue(for code: UInt8) -> UInt8? {
        var i = 0
        while i < payload.count {
            if payload[i] == code && i + 1 < payload.count {
                return payload[i + 1]
            }
            i += 2
        }
        return nil
    }
}
