import Foundation

/// Bộ xử lý dịch mã nhị phân Bluetooth thành Dữ liệu người dùng (SoC, Nhiệt độ, Odo).
struct BLETelemetryParser {
    
    static func parseLockState(from data: Data) -> IoTLockState {
        guard data.count >= 2 else { return .unknown(data) }
        
        switch data {
        case Data([0x00, 0x00]), Data([0x30]), Data([0x30, 0x00]), Data([0x00]):
            return .locked
        case Data([0x02, 0x00]), Data([0x31]), Data([0x31, 0x00]), Data([0x02]):
            return .unlocked
        case Data([0x07, 0x00]):
            return .armed
        default:
            return .unknown(data)
        }
    }
    
    static func parseTelemetry(from data: Data) -> IoTTelemetryData {
        var result = IoTTelemetryData()
        guard data.count >= 13 else { return result }
        
        // 1. Phân tích Motor Temp (Index 5)
        let motorTempByte = data[5]
        result.motorTemp = Float(motorTempByte)
        
        // 2. Phân tích Odometer (Index 7, 8, 9, 10 - Little Endian)
        let odoSub = data.subdata(in: 7..<11)
        let odoMeters = odoSub.withUnsafeBytes { $0.load(as: UInt32.self) }
        result.odometerKm = Float(odoMeters) / 1000.0
        
        // 3. Phân tích Controller Temp (Index 12)
        let controllerTempByte = data[12]
        result.controllerTemp = Float(controllerTempByte)
        
        return result
    }
    
    static func parseBattery(from data: Data) -> Float {
        guard data.count >= 6 else { return 0 }
        let socByte = data[5]
        return Float(socByte) / 100.0 // Giả sử quy đổi 0-1
    }
}
