import Combine
import Foundation

// MARK: - App State Publisher

/// Máy trạng thái tổng của ứng dụng đối với kết nối phần cứng
protocol IoTCoordinatorProtocol: AnyObject {
    var connectionState: AnyPublisher<IoTConnectionState, Never> { get }
    var telemetryData: AnyPublisher<IoTTelemetryData, Never> { get }
    var lockState: AnyPublisher<IoTLockState, Never> { get }
    
    func connect()
    func disconnect()
}

// MARK: - Domain Services

/// Dịch vụ Điều khiển (Commands)
protocol IoTCommandService {
    func turnOnBike() async throws
    func turnOffBike() async throws
    func toggleLock() async throws
    
    func armAntiTheft() async throws
    func findBike(start: Bool) async throws
    func syncTime() async throws
}

/// Dịch vụ lấy cấu hình xe
protocol IoTDeviceInfoService {
    func readVehicleInfo() async throws -> IoTVehicleInfo
    func readLockStatus() async throws -> IoTLockState
}

/// Dịch vụ Authenticator
protocol IoTAuthService {
    /// Bắt đầu chuỗi xác thực SHA-256 hoàn chỉnh
    /// Trả về `true` nếu xác thực thành công.
    func authenticate() async throws -> Bool
}
