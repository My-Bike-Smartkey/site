import Combine
import Foundation

/// Một cỗ máy trạng thái (State Machine) đúng nghĩa.
/// Chỉ có một nguồn sự thật duy nhất (Single Source of Truth) thay vì chùm Booleans rác.
class BLEStateMachine {
    
    @Published private(set) var state: IoTConnectionState = .idle
    
    // Publishers chuyên dụng để dập tắt Notification rác.
    // Chỉ báo ra UI khi State thực sự thay đổi.
    lazy var statePublisher: AnyPublisher<IoTConnectionState, Never> = {
        $state.removeDuplicates().eraseToAnyPublisher()
    }()
    
    func transition(to newState: IoTConnectionState) {
        // Có thể áp dụng các quy tắc Guard ngăn chặn vòng lặp sai logic State tại đây.
        // Ví dụ: Không thể sang .active nếu chưa qua .authenticating
        switch (state, newState) {
        case (.active, .connecting):
            // Lỗi loop
            return
        default:
            DispatchQueue.main.async {
                self.state = newState
            }
        }
    }
}
