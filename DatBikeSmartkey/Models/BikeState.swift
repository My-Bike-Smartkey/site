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
    case sessionVerifying
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
        case .sessionVerifying: return "Đang khôi phục phiên..."
        case .authenticating:   return "Đang xác thực..."
        case .pairingRequired:  return "Đang xác thực bằng thẻ NFC"
        case .ready:            return "Đã kết nối"
        case .error(let msg):   return "Lỗi: \(msg)"
        }
    }
    
    var isConnected: Bool {
        self == .ready
    }
    
    var isWorking: Bool {
        switch self {
        case .scanning, .connecting, .sessionVerifying, .authenticating, .pairingRequired: return true
        default: return false
        }
    }
    
    var systemImage: String {
        switch self {
        case .bluetoothOff:     return "antenna.radiowaves.left.and.right.slash"
        case .disconnected:     return "antenna.radiowaves.left.and.right.slash"
        case .scanning:         return "antenna.radiowaves.left.and.right"
        case .connecting:       return "bolt.horizontal.circle"
        case .sessionVerifying: return "arrow.2.squarepath"
        case .authenticating:   return "lock.shield"
        case .pairingRequired:  return "sensor.tag.radiowaves.forward"
        case .ready:            return "checkmark.circle.fill"
        case .error:            return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Log Entry

struct BLELogEntry: Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
    
    enum LogLevel: String, Codable {
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

// MARK: - Persistent Logger

final class PersistentLogger {
    
    static let shared = PersistentLogger()
    
    private let logDir: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.jedix.mybikesmartkey.persistentlogger", qos: .utility)
    private let sessionMarker = "────────── Phiên mới ──────────"
    private let maxKeepDays = 90
    
    // Current day's file handle
    private var currentHandle: FileHandle?
    private var currentDate: String?
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logDir = docs.appendingPathComponent("ble_logs", isDirectory: true)
        
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Create log directory
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        // Cleanup old files on init
        queue.async { [weak self] in
            self?.cleanupOldFiles()
        }
    }
    
    // MARK: - Write
    
    func append(_ entry: BLELogEntry) {
        queue.async { [weak self] in
            guard let self else { return }
            let ts = Int64(entry.timestamp.timeIntervalSince1970 * 1000)
            let escaped = entry.message
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            let line = "\(ts)\t\(entry.level.rawValue)\t\(escaped)\n"
            
            guard let data = line.data(using: .utf8) else { return }
            
            do {
                let handle = try self.getHandle()
                handle.seekToEndOfFile()
                handle.write(data)
            } catch {
                #if DEBUG
                print("[PersistentLogger] Write error: \(error)")
                #endif
            }
        }
    }
    
    func markSessionStart() {
        let entry = BLELogEntry(timestamp: Date(), level: .info, message: sessionMarker)
        append(entry)
    }
    
    // MARK: - Read
    
    /// Load logs from the last N days (inclusive of today). Oldest → newest.
    func loadLogs(daysBack: Int = 7) -> [BLELogEntry] {
        var entries: [BLELogEntry] = []
        let files = getRecentFiles(daysBack: daysBack)
        for file in files {
            entries.append(contentsOf: parseLogFile(file))
        }
        return entries
    }
    
    /// Load ALL logs from storage.
    func loadAllLogs() -> [BLELogEntry] {
        var entries: [BLELogEntry] = []
        for file in getLogFiles() {
            entries.append(contentsOf: parseLogFile(file))
        }
        return entries
    }
    
    /// Get total size of all log files in bytes.
    func totalSizeBytes() -> Int64 {
        getLogFiles().reduce(0) { sum, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return sum + size
        }
    }
    
    /// Get sorted list of all log files (oldest first).
    func getLogFiles() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    /// Export all logs as a single text string for sharing.
    func exportAllAsText() -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        var sb = ""
        for file in getLogFiles() {
            for entry in parseLogFile(file) {
                sb += "\(timeFmt.string(from: entry.timestamp)) \(entry.level.rawValue) \(entry.message)\n"
            }
        }
        return sb
    }
    
    // MARK: - Delete
    
    func clearAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeHandle()
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: self.logDir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
    
    // MARK: - Internal
    
    private func getHandle() throws -> FileHandle {
        let today = dateFormatter.string(from: Date())
        if today != currentDate || currentHandle == nil {
            closeHandle()
            currentDate = today
            let fileURL = logDir.appendingPathComponent("ble_\(today).log")
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            currentHandle = try FileHandle(forWritingTo: fileURL)
        }
        return currentHandle!
    }
    
    private func closeHandle() {
        try? currentHandle?.close()
        currentHandle = nil
    }
    
    private func getRecentFiles(daysBack: Int) -> [URL] {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        var dates: [String] = []
        var date = Date()
        for _ in 0..<daysBack {
            dates.append(dateFormatter.string(from: date))
            date = cal.date(byAdding: .day, value: -1, to: date) ?? date
        }
        
        let fm = FileManager.default
        return dates.reversed().compactMap { dateStr in
            let url = logDir.appendingPathComponent("ble_\(dateStr).log")
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }
    
    private func parseLogFile(_ url: URL) -> [BLELogEntry] {
        var entries: [BLELogEntry] = []
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return entries }
        
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3,
                  let tsMs = Int64(parts[0]) else { continue }
            
            let levelStr = parts[1]
            let level: BLELogEntry.LogLevel
            switch levelStr {
            case "[INFO]":    level = .info
            case "[SUCCESS]": level = .success
            case "[WARNING]": level = .warning
            case "[ERROR]":   level = .error
            case "[BLE]":     level = .ble
            default:          continue
            }
            
            let message = parts.dropFirst(2).joined(separator: "\t")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
            
            let timestamp = Date(timeIntervalSince1970: Double(tsMs) / 1000.0)
            entries.append(BLELogEntry(timestamp: timestamp, level: level, message: message))
        }
        return entries
    }
    
    private func cleanupOldFiles() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -maxKeepDays, to: Date()) else { return }
        let cutoffStr = dateFormatter.string(from: cutoff)
        
        for file in getLogFiles() {
            let dateStr = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ble_", with: "")
            if dateStr < cutoffStr {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
