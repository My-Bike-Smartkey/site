// BikeState.swift — Vehicle state models

import Foundation
import CoreBluetooth

// MARK: - Bike Info

struct BikeInfo: Equatable {
    var name: String = ""
    var serial: String = ""
    var model: String = ""
    var firmware: String = ""
    var deviceToken: String = ""
    
    var isEmpty: Bool {
        name.isEmpty && serial.isEmpty && model.isEmpty
    }
}

// MARK: - Telemetry Data

struct BatteryTelemetry: Codable, Equatable {
    var voltage: Double?
    var current: Double?
    var soc: BatterySOC?
    var NTCs: [Double]?
    
    struct BatterySOC: Codable, Equatable {
        var soc: Double?
        var cycles: Double?
    }
}

struct DashboardTelemetry: Equatable {
    var odometerKm: Float = 0
    var speedKmh: Float = 0
    var motorTemp: Float = 0
    var controllerTemp: Float = 0
    
    init() {}
    
    init(from data: Data) {
        guard data.count >= 40 else { return }
        odometerKm = getFloat(from: data, at: 0)
        speedKmh = getFloat(from: data, at: 4)
        motorTemp = getFloat(from: data, at: 20)
        controllerTemp = getFloat(from: data, at: 24)
    }
    
    private func getFloat(from data: Data, at offset: Int) -> Float {
        guard data.count >= offset + 4 else { return 0 }
        let bytes = [UInt8](data[offset..<offset+4])
        let value = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Float(bitPattern: value)
    }
}

// MARK: - Discovered Bike

struct DiscoveredBike: Identifiable, Equatable {
    var id: String { peripheral.identifier.uuidString }
    let peripheral: CBPeripheral
    let name: String
    var rssi: Int
    
    static func == (lhs: DiscoveredBike, rhs: DiscoveredBike) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Connection State

enum ConnectionState: Equatable {
    case bluetoothOff
    case disconnected
    case scanning
    case connecting
    case authenticating
    case pairingRequired
    case ready
    case error(String)
    
    var displayText: String {
        switch self {
        case .bluetoothOff:     return "Bluetooth tắt"
        case .disconnected:     return "Đã ngắt kết nối"
        case .scanning:         return "Đang quét..."
        case .connecting:       return "Đang kết nối..."
        case .authenticating:   return "Đang xác thực..."
        case .pairingRequired:  return "Yêu cầu quẹt thẻ NFC"
        case .ready:            return "Đã kết nối"
        case .error(let msg):   return "Lỗi: \(msg)"
        }
    }
    
    var isConnected: Bool {
        self == .ready
    }
    
    var isWorking: Bool {
        switch self {
        case .scanning, .connecting, .authenticating, .pairingRequired: return true
        default: return false
        }
    }
    
    var systemImage: String {
        switch self {
        case .bluetoothOff:     return "antenna.radiowaves.left.and.right.slash"
        case .disconnected:     return "antenna.radiowaves.left.and.right.slash"
        case .scanning:         return "antenna.radiowaves.left.and.right"
        case .connecting:       return "bolt.horizontal.circle"
        case .authenticating:   return "lock.shield"
        case .pairingRequired:  return "sensor.tag.radiowaves.forward"
        case .ready:            return "checkmark.circle.fill"
        case .error:            return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Log Entry

struct BLELogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
    
    enum LogLevel: String {
        case info = "[INFO]"
        case success = "[SUCCESS]"
        case warning = "[WARNING]"
        case error = "[ERROR]"
        case ble = "[BLE]"
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}
