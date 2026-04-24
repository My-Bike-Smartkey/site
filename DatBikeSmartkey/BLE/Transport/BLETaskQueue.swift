import Foundation

/// Hàng đợi cấp doanh nghiệp đảm bảo mọi thao tác đọc/ghi vào GATT GATT Characteristic
/// được thực thi tuần tự (FIFO), ngăn chặn triệt để tình trạng đè lệnh (GATT collisions) gây treo phần cứng.
actor BLETaskQueue {
    private var isExecuting: Bool = false
    private var pendingTasks: [(UUID, CheckedContinuation<Void, Error>)] = []
    
    /// Thêm một khối lệnh bất đồng bộ vào hàng đợi. Nó sẽ bị treo (await) cho đến khi
    /// phần cứng Bluetooth rảnh rỗi và đến lượt nó thi hành.
    func enqueue<T>(task: @escaping () async throws -> T) async throws -> T {
        let taskID = UUID()
        
        // Đăng kí xếp hàng nếu Queue đang bận
        if isExecuting {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pendingTasks.append((taskID, continuation))
                }
            } onCancel: {
                Task { [weak self] in await self?.cancelTask(id: taskID) }
            }
        }
        
        isExecuting = true
        defer {
            executeNext()
        }
        
        // Bắt đầu thực thi Task
        try Task.checkCancellation()
        return try await task()
    }
    
    private func executeNext() {
        if pendingTasks.isEmpty {
            isExecuting = false
        } else {
            // Cho phép tác vụ tiếp theo (FIFO)
            let next = pendingTasks.removeFirst()
            next.1.resume()
        }
    }
    
    /// Bắn tín hiệu huỷ 1 task duy nhất (Do user huỷ)
    private func cancelTask(id: UUID) {
        if let index = pendingTasks.firstIndex(where: { $0.0 == id }) {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[BLE_QUEUE] Đã huỷ tác vụ đang xếp hàng: \(id)"))
            let removed = pendingTasks.remove(at: index)
            removed.1.resume(throwing: CancellationError())
        }
    }
    
    /// Hủy toàn bộ hàng đợi nếu ngắt kết nối
    func cancelAll() {
        let tasks = pendingTasks
        pendingTasks.removeAll()
        isExecuting = false
        
        for task in tasks {
            task.1.resume(throwing: IoTError.gattOverload) // Báo ngắt toàn bộ liên kết
        }
    }
}
