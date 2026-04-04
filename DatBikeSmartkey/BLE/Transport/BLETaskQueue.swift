import Foundation

/// Hàng đợi cấp doanh nghiệp đảm bảo mọi thao tác đọc/ghi vào GATT GATT Characteristic
/// được thực thi tuần tự (FIFO), ngăn chặn triệt để tình trạng đè lệnh (GATT collisions) gây treo phần cứng.
actor BLETaskQueue {
    private var isExecuting: Bool = false
    private var pendingTasks: [CheckedContinuation<Void, Error>] = []
    
    /// Thêm một khối lệnh bất đồng bộ vào hàng đợi. Nó sẽ bị treo (await) cho đến khi
    /// phần cứng Bluetooth rảnh rỗi và đến lượt nó thi hành.
    func enqueue<T>(task: @escaping () async throws -> T) async throws -> T {
        // Đăng kí xếp hàng nếu Queue đang bận
        if isExecuting {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingTasks.append(continuation)
            }
        }
        
        isExecuting = true
        defer {
            executeNext()
        }
        
        // Bắt đầu thực thi Task
        return try await task()
    }
    
    private func executeNext() {
        if pendingTasks.isEmpty {
            isExecuting = false
        } else {
            // Cho phép tác vụ tiếp theo (FIFO)
            let next = pendingTasks.removeFirst()
            next.resume()
        }
    }
    
    /// Hủy toàn bộ hàng đợi nếu ngắt kết nối
    func cancelAll() {
        let tasks = pendingTasks
        pendingTasks.removeAll()
        isExecuting = false
        
        for task in tasks {
            task.resume(throwing: IoTError.gattOverload)
        }
    }
}
