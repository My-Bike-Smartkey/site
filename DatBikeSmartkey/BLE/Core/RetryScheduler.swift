import Foundation

/// §3.7 (P2) — RetryScheduler: CHỦ DUY NHẤT của mọi retry trì hoãn trong app.
///
/// Vấn đề cũ: retry rải rác dưới dạng `DispatchQueue.main.asyncAfter` không track —
/// nhiều chuỗi chồng nhau chạy song song (log: MIC retry + Phantom Guard + connect()
/// cùng lúc), và retry "bypass" PAUSE vì closure không qua guard nào.
///
/// Quy tắc:
/// 1. Mọi retry đăng ký qua `schedule(label:group:delay:body:)` — body chạy trên MainActor.
/// 2. Retry gắn với **sessionID hiện tại** (một xe = một session; đổi savedPeripheralUUID
///    ⇒ session mới ⇒ mọi token cũ tự chết, body không chạy).
/// 3. Nhóm (`group`) đảm bảo "một chủ retry": khi handler A nhận quyền, nó cancel
///    nhóm của handler B (VD: MIC nhận quyền ⇒ Phantom Guard bị void).
/// 4. Body PHẢI tự kiểm tra pause/intent (connect() đã có guard) — scheduler không
///    quyết định nghiệp vụ, chỉ đảm bảo trật tự và vòng đời.
actor RetryScheduler {

    private struct Entry {
        let id: UUID
        let label: String
        let group: String?
        let task: Task<Void, Never>
    }

    /// Session mà các retry hiện tại phục vụ (thường = UUID của xe đã ghép).
    private(set) var currentSessionID: UUID?

    private var entries: [Entry] = []

    // MARK: - Vòng đời session

    /// Gắn scheduler vào session. Session khác ⇒ mọi retry cũ bị cancel.
    func bind(sessionID: UUID, reason: String) {
        guard currentSessionID != sessionID else { return }
        cancelAll(reason: "bind(\(reason)) → session \(sessionID.uuidString.prefix(8))")
        currentSessionID = sessionID
    }

    // MARK: - Lập lịch

    /// Đăng ký retry. Nếu `group` đã có entry thì entry cũ bị thay (mỗi nhóm 1 chuỗi).
    /// Trả về false nếu delay âm (từ chối lịch). Body chạy trên MainActor.
    @discardableResult
    func schedule(label: String,
                  group: String? = nil,
                  delay: TimeInterval,
                  body: @escaping @Sendable () -> Void) -> Bool {
        guard delay >= 0 else { return false }
        if let group { cancelGroup(group, reason: "thay bằng [\(label)] cùng nhóm") }

        let id = UUID()
        let sessionAtSchedule = currentSessionID
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return // Task bị cancel
            }
            guard let self else { return }
            let shouldRun = await self.isAlive(id, sessionID: sessionAtSchedule)
            guard shouldRun else { return }
            await MainActor.run { body() }
        }
        entries.append(Entry(id: id, label: label, group: group, task: task))
        PersistentLogger.shared.append(BLELogEntry(
            timestamp: Date(), level: .info,
            message: "[RETRY] Đã lập lịch [\(label)]\(group.map { " (nhóm \($0))" } ?? "") delay=\(String(format: "%.1f", delay))s — tổng \(entries.count) retry đang chờ"))
        return true
    }

    /// Token còn sống + session chưa đổi?
    private func isAlive(_ id: UUID, sessionID: UUID?) -> Bool {
        guard entries.contains(where: { $0.id == id }) else { return false }
        guard let sessionID, let currentSessionID else { return true }
        return sessionID == currentSessionID
    }

    // MARK: - Hủy

    func cancelGroup(_ group: String, reason: String) {
        let matching = entries.filter { $0.group == group }
        guard !matching.isEmpty else { return }
        matching.forEach { $0.task.cancel() }
        entries.removeAll { $0.group == group }
        PersistentLogger.shared.append(BLELogEntry(
            timestamp: Date(), level: .info,
            message: "[RETRY] Hủy nhóm '\(group)' (\(matching.map(\.label).joined(separator: ", "))) — \(reason)"))
    }

    func cancelGroups(_ groups: [String], reason: String) {
        groups.forEach { cancelGroup($0, reason: reason) }
    }

    func cancelAll(reason: String) {
        guard !entries.isEmpty else { return }
        PersistentLogger.shared.append(BLELogEntry(
            timestamp: Date(), level: .info,
            message: "[RETRY] Hủy toàn bộ \(entries.count) retry (\(entries.map(\.label).joined(separator: ", "))) — \(reason)"))
        entries.forEach { $0.task.cancel() }
        entries.removeAll()
    }

    func pendingCount() -> Int {
        entries.count
    }
}
