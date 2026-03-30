// BLEConstants.swift — Dat Bike Quantum S3 BLE Protocol Constants
// Reverse-engineered from btsnoop_hci.log

import CoreBluetooth

// MARK: - Service UUIDs

enum BLEService {
    /// Primary scan/advertisement service UUID
    static let scan          = CBUUID(string: "0000FCF1-0000-1000-8000-00805F9B34FB")
    
    /// Authentication service (handles 0x00a–0x010)
    static let auth          = CBUUID(string: "10CB0217-FF02-4474-A1EF-6FD88B5BDAEA")
    
    /// Configuration service (handles 0x011–0x017)
    static let config        = CBUUID(string: "CF6900A7-4520-4A4C-977C-82979E8BACCF")
    
    /// Main vehicle control service (handles 0x018–0x03e)
    static let main          = CBUUID(string: "D4905F67-8931-4FAA-8C61-86EC7490F3C5")
    
    /// Extended service (handles 0x03f–0xffff)
    static let ext           = CBUUID(string: "5B6D1069-A0BC-4875-BA5B-FDC94647D918")
    
    /// Alternate scan service UUID seen in some advertisements
    static let altScan       = CBUUID(string: "15111100-3023-455B-86CE-615F79EE8ECE")
    
    /// All services to discover after connection
    static let allServices: [CBUUID] = [auth, config, main, ext]
}

// MARK: - Characteristic UUIDs

enum BLECharacteristic {
    // — Auth Service —
    
    /// Auth challenge/PIN write (handle 0x00c)
    /// Write PIN here to authenticate. First write triggers SMP pairing if not bonded.
    static let authChallenge   = CBUUID(string: "C8EAF27B-9FB7-4BC3-B11A-BF68C97B1B1F")
    
    /// Auth response (handle 0x00e)
    static let authResponse    = CBUUID(string: "C75EBE03-EA2F-4C0E-A720-1E7112A72D81")
    
    /// Auth token (handle 0x010)
    static let authToken       = CBUUID(string: "91E84EB0-DEA0-436F-A157-F21D89443B32")
    
    // — Config Service —
    
    /// Cấu hình và Dashboard (handle 0x013)
    static let dashboardData   = CBUUID(string: "6D2EB205-6F9B-4ECF-BB1B-A5FAD127C66C")
    
    /// Nhật ký Pin / Battery Info (JSON format)
    static let batteryData     = CBUUID(string: "84C7BE0B-7619-45C1-A503-95F4FF8736ED")
    
    /// Bike Config JSON (name, model, frame, firmware, controller, mainPcb data)
    /// NOTE: trước đây gọi nhim là "pairingCode" nhưng thực tế là BIKE_CONFIG_JSON
    static let bikeConfigJson  = CBUUID(string: "018E6A6F-4BDA-7B07-8586-1298248A8D5C")
    

    
    // — Main Service —
    
    /// Vehicle status / BIKE_NAME (handle 0x01a) — READ returns device name string
    static let vehicleStatus   = CBUUID(string: "88C30D2C-F80F-43F8-B0CB-FC1E4AE49BE9")
    
    /// STATUS_FLAGS (handle 0x01c) — 0x08 0x00 observed
    /// NOTE: trước đây gọi là "lockState" nhưng đây là STATUS_FLAGS, không phải LOCK_STATUS
    static let statusFlags     = CBUUID(string: "5D681587-C268-4BD3-9560-66EC79DBFDC8")
    
    /// Device serial (alternate, handle 0x022)
    static let deviceSerialAlt = CBUUID(string: "041D5A06-E35F-42D3-92C8-0D421186D2F3")
    
    /// Device model (alternate, handle 0x028)
    static let deviceModelAlt  = CBUUID(string: "4AAE98E9-90B5-492F-8180-9538FA2C843D")
    
    /// Session token (handle 0x02e) — Write random 5-digit session ID after auth
    static let sessionToken    = CBUUID(string: "44E2BDE6-9CD5-4159-9D43-A3E3F4E9C737")
    
    /// Unlock command (handle 0x030) — WRITE '0' (0x30) to unlock
    static let unlockCmd       = CBUUID(string: "7F13FE5C-1971-4FEC-97FD-F90E16CF8C28")
    
    /// Auto-unlock / proximity token (handle 0x032)
    static let autoUnlock      = CBUUID(string: "87EFAB0D-9E32-4AB8-8916-ED7CB72D819A")
    
    /// Find bike command (handle 0x034) — WRITE '1' start, '0' stop
    static let findBike        = CBUUID(string: "350D9A82-B3F3-4213-BDDA-6403BE495F53")
    
    /// Smartkey echo / lock command (handle 0x036)
    /// READ: status byte. WRITE '1' (0x31) to lock/arm.
    static let smartkeyEcho    = CBUUID(string: "EEC8FD7F-4709-441A-A838-B9EB3066EDE4")
    
    /// Commit hash string (handle 0x03a) — e.g. "9036bee-#-b2330b8-157a3c1"
    /// NOTE: trước đây gọi là "deviceToken" nhưng thực tế là COMMIT_HASH
    static let commitHash      = CBUUID(string: "73D50009-ED01-4BB1-BDC2-E89B725A91DB")
    
    /// Firmware version string (handle 0x02a) — e.g. "1.10.1"
    static let fwVersion       = CBUUID(string: "D1DA175E-7E4B-42DB-9EC5-BDD7E929EB6C")
    
    /// LOCK_STATUS — READ: 00 00 = LOCKED (tắt), 02 00 = UNLOCKED (bật)
    /// Đây là char được dùng trong readLockStatus() (alias cho smartkeyEcho)
    static let lockStatus      = CBUUID(string: "EEC8FD7F-4709-441A-A838-B9EB3066EDE4")
    
    /// SMARTKEY_FLAG (r) — 0x01 = SmartKey enabled
    static let smartkeyFlag    = CBUUID(string: "69C79762-C574-46D0-8E8B-D2B8D8B1019A")
    
    /// Service Changed (standard BLE, handle 0x008)
    static let serviceChanged  = CBUUID(string: "2A05")
}

// MARK: - Commands

enum BLECommand {
    /// Unlock: WRITE ASCII '0' (0x30) → unlockCmd (7F13FE5C)
    /// Confirmed: BLE write "0" = mở khóa xe (REPORT.md §4.2 Step 9)
    static let unlock: Data = Data([0x30])
    
    /// Lock/Arm: WRITE ASCII '1' (0x31) → smartkeyEcho (EEC8FD7F)
    /// Note: lock sequence not observed in logs, keeping as-is
    static let lock: Data   = Data([0x31])
    
    /// Power ON alias — same as unlock
    static let powerOn: Data = Data([0x30])
    
    /// Power OFF alias — write '1' (unknown effect, not confirmed)
    static let powerOff: Data = Data([0x31])
    
    /// Find bike start: WRITE '1' → findBike (h=0x034)
    static let findStart: Data = Data([0x31])
    
    /// Find bike stop: WRITE '0' → findBike (h=0x034)
    static let findStop: Data  = Data([0x30])
}

// MARK: - Lock Status

enum LockStatus: Equatable, CustomStringConvertible {
    case unlocked
    case locked
    case armed
    case unknown(Data)
    
    /// Parse raw bytes from LOCK_STATUS (EEC8FD7F, h=0x036)
    /// Confirmed via Frida dynamic analysis (REPORT.md §4.3):
    ///   00 00 = LOCKED   (xe đang tắt — trạng thái mặc định)
    ///   02 00 = UNLOCKED (xe đang bật — sau khi write 0x31 = powerOn)
    ///   07 00 = in-progress
    init(from data: Data) {
        switch data {
        // 00 00 = LOCKED (xe đang tắt)
        case Data(), Data([0x00]), Data([0x00, 0x00]), Data([0x30]), Data([0x30, 0x00]):
            self = .locked
            
        // 02 00 = UNLOCKED (xe đang bật)
        case Data([0x02]), Data([0x02, 0x00]), Data([0x31]), Data([0x31, 0x00]):
            self = .unlocked
            
        case Data([0x07]), Data([0x07, 0x00]):
            self = .armed
        default:
            self = .unknown(data)
        }
    }
    
    var description: String {
        switch self {
        case .unlocked:        return "Đang bật"
        case .locked:          return "Đang tắt"
        case .armed:           return "Đã vũ trang"
        case .unknown(let d):  return "Không xác định (\(d.hexString))"
        }
    }
    

    
    var isLocked: Bool {
        switch self {
        case .locked, .armed: return true
        default: return false
        }
    }
}

// MARK: - Auth State

/// Auth challenge response byte interpretation
enum AuthState {
    case notBonded      // first byte '7e'
    case bondedNotAuth  // first byte '80'
    case authenticated  // first byte '81' or 'a1'
    case unknown
    
    init(from data: Data) {
        guard let firstByte = data.first else {
            self = .unknown
            return
        }
        switch firstByte {
        case 0x7E:       self = .notBonded
        case 0x80:       self = .bondedNotAuth
        case 0x81, 0xA1: self = .authenticated
        default:         self = .unknown
        }
    }
}

// MARK: - Protocol Constants

enum BLEProtocol {
    /// Default authentication PIN — người dùng set trong Settings
    /// Auth formula: SHA-256( str(challenge_uint32_LE >> 1) + authPIN )
    /// Ví dụ PIN thực tế quan sát: "997812" (cũ), "nguyeanphuactu" (mới)
    static let authPIN = "997812"
    
    /// Legacy numeric pairing code (observed in first-connect flow, session 140947)
    static let pairingCode = "997812"
    
    /// RSSI threshold for auto-unlock (same as ESP32: -65 dBm ≈ 1-2m)
    static let rssiThreshold: Int = -65
    
    /// State restoration identifier for CBCentralManager
    static let centralRestoreID = "DatBikeSmartkeyCentral"
    
    /// Known BLE MAC address of the bike
    static let knownMAC = "74:4D:BD:2B:C9:B9"
    
    /// Device name prefix for scanning
    static let deviceNamePrefix = "Dat Bike"
    
    /// Alternate device name
    static let deviceNameAlt = "QT_S3"
    
    /// Auth sequence timing — exact from btsnoop_hci.log
    static let authConfirmDelay: TimeInterval = 0.12   // 120ms between PIN writes
    static let authSessionDelay: TimeInterval = 0.5    // 500ms before session token
    static let authFinalDelay: TimeInterval = 1.0      // 1s before final PIN confirm
    static let pairingTimeout: TimeInterval = 8.0      // 8s wait for SMP pairing
    
    /// Scan restart interval when in background
    static let backgroundScanInterval: TimeInterval = 10.0
    
    /// RSSI read interval for proximity monitoring
    static let rssiReadInterval: TimeInterval = 2.0
}

// MARK: - Data Extension

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
    
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
