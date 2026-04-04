import CoreBluetooth

// MARK: - Characteristic UUIDs
enum BLECharacteristic {
    /// Auth challenge/PIN write (handle 0x00c)
    static let authChallenge   = CBUUID(string: "c8eaf27b-9fb7-4bc3-b11a-bf68c97b1b1f")
    
    /// Session token (handle 0x02e), TimeSync
    static let sessionToken    = CBUUID(string: "44e2bde6-9cd5-4159-9d43-a3e3f4e9c737")
    
    /// Auto-unlock / proximity (handle 0x032)
    static let autoUnlock      = CBUUID(string: "87efab0d-9e32-4ab8-8916-ed7cb72d819a")
    
    /// Unlock command (handle 0x030)
    static let unlockCmd       = CBUUID(string: "7f13fe5c-1971-4fec-97fd-f90e16cf8c28")
    
    /// Smartkey echo / status (handle 0x036)
    static let smartkeyEcho    = CBUUID(string: "eec8fd7f-4709-441a-a838-b9eb3066ede4")
    
    /// Find bike command (handle 0x034)
    static let findBike        = CBUUID(string: "350d9a82-b3f3-4213-bdda-6403be495f53")
    
    /// Dashboard telemetry (handle 0x013)
    static let dashboardData   = CBUUID(string: "6d2eb205-6f9b-4ecf-bb1b-a5fad127c66c")
    
    /// Device Serial
    static let deviceSerialAlt = CBUUID(string: "041d5a06-e35f-42d3-92c8-0d421186d2f3")
}

// MARK: - Commands
enum BLECommand {
    static let powerOff: Data  = Data([0x30])
    static let powerOn: Data   = Data([0x31])
    static let lock: Data      = Data([0x31])
    static let findStart: Data = Data([0x31])
    static let findStop: Data  = Data([0x30])
}

// MARK: - Data Extension
extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
