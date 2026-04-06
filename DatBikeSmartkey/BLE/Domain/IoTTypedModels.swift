import Foundation

/// Thể hiện trạng thái kết nối tổng quát (Hỗ trợ State Machine).
enum IoTConnectionState: Equatable {
    case idle
    case scanning
    case connecting
    case pairingRequired // Bổ sung trạng thái chờ xác thực/NFC
    case authenticating
    /// Kết nối thành công, auth hoàn tất, data sẵn sàng.
    case active
    case error(String)
    
    var isConnected: Bool {
        if case .active = self { return true }
        return false
    }
    
    var isWorking: Bool {
        switch self {
        case .scanning, .connecting, .authenticating, .pairingRequired: return true
        default: return false
        }
    }
    
    var displayText: String {
        switch self {
        case .idle: return "Chưa kết nối"
        case .scanning: return "Đang tìm xe..."
        case .connecting: return "Đang kết nối..."
        case .pairingRequired: return "Chờ xác thực thẻ NFC..."
        case .authenticating: return "Đang xác thực bảo mật..."
        case .active: return "Đã kết nối"
        case .error(let msg): return "Lỗi: \(msg)"
        }
    }
}

/// Trạng thái khóa của mảng byte 0x36.
enum IoTLockState: Equatable, CustomStringConvertible {
    case locked
    case unlocked
    case armed
    case unknown(Data)
    
    var isLocked: Bool {
        return self == .locked || self == .armed
    }
    
    var description: String {
        switch self {
        case .locked: return "Đã tắt/khoá"
        case .unlocked: return "Đang bật"
        case .armed: return "Chống trộm (Arm)"
        case .unknown: return "Đang tải..."
        }
    }
    
    /// Parse từ raw data đọc từ smartkeyEcho/lockStatus (đồng bộ 64623aa)
    /// 00 00 = LOCKED (xe đang tắt)
    /// 02 00 = UNLOCKED (xe đang bật)
    /// 07 00 = ARMED (chống trộm)
    static func parse(from data: Data) -> IoTLockState {
        switch data {
        case Data(), Data([0x00]), Data([0x00, 0x00]), Data([0x30]), Data([0x30, 0x00]):
            return .locked
        case Data([0x02]), Data([0x02, 0x00]), Data([0x31]), Data([0x31, 0x00]):
            return .unlocked
        case Data([0x07]), Data([0x07, 0x00]):
            return .armed
        default:
            return .unknown(data)
        }
    }
}

/// Dữ liệu đo đạc (Telemetry) an toàn, đã được dịch khối byte.
struct IoTTelemetryData: Equatable {
    var soc: Float = 0        // Battery percentage 0-100%
    var motorTemp: Float = 0
    var controllerTemp: Float = 0
    var odometerKm: Float = 0
    var speedKmh: Float = 0
}

/// Cấu trúc thông tin cơ bản xe trả về
struct IoTVehicleInfo: Equatable {
    var name: String = "Dat Bike"
    var serialNumber: String = ""
    var modelNumber: String = ""
    var firmwareVersion: String = ""
    var deviceToken: String = ""
    
    // Compat accessors cho Views
    var serial: String { serialNumber }
    var model: String { modelNumber }
    var firmware: String { firmwareVersion }
    var isEmpty: Bool { name == "Dat Bike" && serialNumber.isEmpty }
}
