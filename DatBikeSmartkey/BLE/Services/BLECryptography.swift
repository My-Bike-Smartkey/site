import Foundation
import CryptoKit

/// Lớp nghiệp vụ thuần về Mật mã, hoàn toàn tách biệt khỏi Bluetooth.
/// Có thể dùng Unit Test độc lập.
struct BLECryptography {
    
    /// Nhận `authChallenge` từ xe (4 bytes tuỳ ý), xử lý công thức và trả lại 64 kí tự hash HexString.
    /// - Parameters:
    ///   - challengeBytes: 4 bytes lấy từ characteristic `0x000C`
    ///   - pin: Chuỗi PIN ghép đôi.
    /// - Returns: Hex String dùng để gửi trả lại xe.
    static func solveChallenge(challengeBytes: Data, pin: String) throws -> String {
        guard challengeBytes.count >= 4 else { throw IoTError.invalidResponseFormat }
        
        let subdata = challengeBytes.subdata(in: 0..<4)
        let littleEndianValue = subdata.withUnsafeBytes { $0.load(as: UInt32.self) }
        let shiftedValue = littleEndianValue >> 1
        
        // Hợp nhất `shiftedValue` và `PIN`
        let hashInputStr = String(shiftedValue) + pin
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Auth crypto: raw=\(littleEndianValue) >> 1 = \(shiftedValue), input=\"\(hashInputStr)\""))
        
        guard let inputData = hashInputStr.data(using: .utf8) else {
            throw IoTError.invalidResponseFormat
        }
        
        // Băm SHA-256
        let hash = SHA256.hash(data: inputData)
        
        // Đảo thành Hex
        let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return hexString
    }
}
