import Foundation
import ActivityKit

public struct DatBikeLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var lockState: String
        public var connectionState: String
        public var batteryLevel: Int
        
        public init(lockState: String, connectionState: String, batteryLevel: Int) {
            self.lockState = lockState
            self.connectionState = connectionState
            self.batteryLevel = batteryLevel
        }
    }
    
    public var bikeName: String
    
    public init(bikeName: String) {
        self.bikeName = bikeName
    }
}
