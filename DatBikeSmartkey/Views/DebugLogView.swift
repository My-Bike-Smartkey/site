// DebugLogView.swift — BLE Log viewer with export

import SwiftUI
import UniformTypeIdentifiers

struct DebugLogView: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss
    @State private var autoScroll = true
    @State private var searchText = ""
    @State private var showBLELevel = false

    private var filteredLogs: [BLELogEntry] {
        bleManager.logs.filter { entry in
            if !showBLELevel && entry.level == .ble { return false }
            if searchText.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Tìm trong log...", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .foregroundColor(.white)
                }
                .padding(10)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                // Log count + controls
                HStack {
                    Text("\(filteredLogs.count) dòng log")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    // Toggle BLE-level logs
                    Button {
                        showBLELevel.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: showBLELevel ? "eye" : "eye.slash")
                                .font(.system(size: 10))
                            Text("BLE")
                                .font(.system(size: 11, design: .monospaced).bold())
                        }
                        .foregroundColor(showBLELevel ? .cyan : .gray)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(showBLELevel ? Color.cyan.opacity(0.12) : Color.white.opacity(0.06))
                        .cornerRadius(5)
                    }
                    Spacer().frame(width: 8)
                    Button(action: { autoScroll.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: autoScroll ? "arrow.down.to.line" : "pause")
                                .font(.system(size: 10))
                            Text(autoScroll ? "Auto-scroll" : "Tạm dừng")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(autoScroll ? .cyan : .gray)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
                
                // Log list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredLogs) { log in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(log.formattedTime)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.gray)
                                        .frame(width: 80, alignment: .leading)
                                    
                                    Text("\(log.level.rawValue) \(log.message)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(color(for: log.level))
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 1)
                                .padding(.horizontal)
                                .id(log.id)
                            }
                        }
                    }
                    .background(Color(red: 0.03, green: 0.03, blue: 0.06))
                    .onChange(of: bleManager.logs.count) { _ in
                        if autoScroll, let last = filteredLogs.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let last = filteredLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.08))
            .navigationTitle("BLE Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 16) {
                        // Export button (Share Sheet)
                        Button(action: exportLogs) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14))
                        }
                        
                        // Copy button
                        Button(action: copyLogs) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                        }
                        
                        // Clear button
                        Button(action: {
                            bleManager.clearLogs(clearPersisted: true)
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundColor(.red)
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") {
                        dismiss()
                    }
                    .font(.headline)
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let shareURL {
                    ShareSheet(items: [shareURL])
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // UI state for share sheet
    @State private var showingShareSheet = false
    @State private var shareURL: URL?
    
    private func exportLogs() {
        let text = bleManager.logs.map { entry in
            "\(entry.formattedTime) [\(entry.level.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
        
        let fileName = "datbike_ble_log_\(logDateString()).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
            shareURL = tempURL
            showingShareSheet = true
        } catch {
            print("Failed to write log file: \(error)")
        }
    }
    
    private func copyLogs() {
        let text = bleManager.logs.map { entry in
            "\(entry.formattedTime) [\(entry.level.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
    }
    
    private func logDateString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt.string(from: Date())
    }
    
    private func color(for level: BLELogEntry.LogLevel) -> Color {
        switch level {
        case .info: return .white
        case .warning: return .yellow
        case .error: return .red
        case .success: return .green
        case .ble: return .cyan
        }
    }
}

// MARK: - Share Sheet Helper

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
