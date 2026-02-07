//
//  BluetoothManager.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/14.
//

import SwiftUI
import CoreBluetooth
import Combine

class BluetoothManager: NSObject, ObservableObject {
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isScanning = false
    @Published var receivedData: Data?
    @Published var errorMessage: String?
    @Published var bluetoothState: CBManagerState = .unknown
    
    private var centralManager: CBCentralManager!
    private var targetCharacteristic: CBCharacteristic?
    
    // 腦波裝置常見的服務 UUID（需要根據你的具體設備調整）
    private let brainwaveServiceUUID = CBUUID(string: "12345678-1234-1234-1234-123456789abc")
    private let dataCharacteristicUUID = CBUUID(string: "87654321-4321-4321-4321-cba987654321")
    
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            errorMessage = "藍牙未開啟或不可用"
            return
        }
        
        discoveredDevices.removeAll()
        isScanning = true
        errorMessage = nil
        
        // 掃描特定服務的設備，如果不確定可以傳入 nil 掃描所有設備
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }
    
    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }
    
    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        connectionState = .connecting
        centralManager.connect(peripheral, options: nil)
    }
    
    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    private func setupNotifications(for peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([brainwaveServiceUUID])
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        
        switch central.state {
        case .poweredOn:
            print("藍牙已開啟，可以開始掃描")
        case .poweredOff:
            errorMessage = "請開啟藍牙"
            connectionState = .error("藍牙已關閉")
        case .unauthorized:
            errorMessage = "請允許藍牙權限"
            connectionState = .error("無藍牙權限")
        case .unsupported:
            errorMessage = "設備不支持藍牙"
            connectionState = .error("不支持藍牙")
        default:
            errorMessage = "藍牙狀態未知"
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // 過濾重複設備
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        connectionState = .connected
        setupNotifications(for: peripheral)
        print("已連接到設備: \(peripheral.name ?? "未知設備")")
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .error("連接失敗: \(error?.localizedDescription ?? "未知錯誤")")
        errorMessage = "連接失敗"
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral == connectedPeripheral {
            connectedPeripheral = nil
            connectionState = .disconnected
            targetCharacteristic = nil
            
            if let error = error {
                errorMessage = "連接斷開: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            print("未發現服務")
            return
        }
        
        for service in services {
            print("發現服務: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else {
            print("未發現特徵")
            return
        }
        
        for characteristic in characteristics {
            print("發現特徵: \(characteristic.uuid)")
            
            // 檢查是否支持通知
            if characteristic.properties.contains(.notify) {
                targetCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                print("已訂閱特徵通知: \(characteristic.uuid)")
            }
            
            // 如果支持讀取，也可以嘗試讀取一次
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else {
            print("收到空數據")
            return
        }
        
        DispatchQueue.main.async {
            self.receivedData = data
        }
        
        print("收到數據: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("設置通知失敗: \(error.localizedDescription)")
        } else {
            print("通知狀態更新成功: \(characteristic.isNotifying)")
        }
    }
}