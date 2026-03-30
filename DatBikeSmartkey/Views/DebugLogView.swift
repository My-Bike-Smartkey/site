// DebugLogView.swift — Displays raw BLE logs
import SwiftUI

struct DebugLogView: View {
    let logs: [BLELogEntry]
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(logs) { log in
                            HStack(alignment: .top, spacing: 8) {
                                Text(log.formattedTime)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .frame(width: 85, alignment: .leading)
                                
                                Text("\(log.level.rawValue) \(log.message)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(color(for: log.level))
                            }
                            .padding(.vertical, 2)
                            .id(log.id)
                        }
                    }
                    .padding()
                }
                .background(Color(red: 0.05, green: 0.05, blue: 0.08))
                .onChange(of: logs.count) { _ in
                    if let last = logs.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = logs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("BLE Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") {
                        dismiss()
                    }
                    .font(.headline)
                }
            }
        }
        .preferredColorScheme(.dark)
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

#Preview {
    DebugLogView(logs: [
        BLELogEntry(timestamp: Date(), level: .ble, message: "[TX] WRITE REQ: 1234abcd"),
        BLELogEntry(timestamp: Date(), level: .success, message: "PIN được chấp nhận")
    ])
}
