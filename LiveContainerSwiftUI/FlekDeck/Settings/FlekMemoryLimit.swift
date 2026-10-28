//
//  FlekMemoryLimit.swift
//  LiveContainerSwiftUI
//
//  How much memory apps in Single Mode can use, shown on the JIT-less
//  diagnosis page with the rest of what FlekDeck's signing gives it.
//
//  An app run in Single Mode runs in FlekDeck's own process, so it can use as
//  much memory as iOS gives FlekDeck. iOS gives an app more with the Increased
//  Memory Limit entitlement, which FlekDeck asks for, but has only where the
//  profile it was installed with grants it. Nothing in
//  FlekDeck can change that, so the section only says how it stands, and what
//  the limit comes to on this device. Parallel mode is not covered: its apps
//  run in LiveProcess, a process with a limit of its own.
//

import os
import SwiftUI

enum FlekMemoryLimit {
    static let entitlement = "com.apple.developer.kernel.increased-memory-limit"

    /// Whether FlekDeck has the entitlement, which iOS reads as it starts it.
    static let isIncreased: Bool = {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) else {
            return false
        }
        return (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false
    }()

    /// How much memory FlekDeck's process may use before iOS ends it, in
    /// bytes, which is what an app in Single Mode gets: what it uses now and
    /// what it has left. Nil where iOS sets no limit, as in the simulator.
    static var limit: UInt64? {
        let available = os_proc_available_memory()
        guard available > 0 else {
            return nil
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return UInt64(available) + info.phys_footprint
    }

    /// The limit to one decimal, the way Settings writes sizes.
    static var limitText: String? {
        limit.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }
    }

    /// The device's memory as it is sold. iOS reports a little under it.
    static var deviceMemoryText: String {
        let gigabytes = (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded(.up)
        return ByteCountFormatter.string(fromByteCount: Int64(gigabytes) * 1_073_741_824, countStyle: .memory)
    }
}

/// Whether apps in Single Mode get the higher limit, and how much memory they
/// can use on this device, as rows laid out like the rest of the diagnosis
/// page's. The (?) says what the green Increased and the grey Standard mean.
struct FlekMemoryLimitSection: View {
    @State private var helpShown = false

    var body: some View {
        Section {
            HStack {
                Text("lc.flek.memory.title".loc)
                Button {
                    helpShown = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                // A button of its own, rather than the whole row.
                .buttonStyle(.borderless)
                .accessibilityLabel("lc.flek.memory.help".loc)
                Spacer()
                Text((FlekMemoryLimit.isIncreased ? "lc.flek.memory.increased" : "lc.flek.memory.standard").loc)
                    .foregroundStyle(FlekMemoryLimit.isIncreased ? Color.green : Color.gray)
            }
            .sheet(isPresented: $helpShown) {
                FlekMemoryLimitHelpView()
            }
            if let limit = FlekMemoryLimit.limitText {
                HStack {
                    Text("lc.flek.memory.limit".loc)
                    Spacer()
                    Text(limit)
                        .foregroundStyle(.gray)
                }
            }
            HStack {
                Text("lc.flek.memory.device".loc)
                Spacer()
                Text(FlekMemoryLimit.deviceMemoryText)
                    .foregroundStyle(.gray)
            }
        }
    }
}

/// What the card's two states mean, each in the colour the card shows it in.
private struct FlekMemoryLimitHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    state("lc.flek.memory.increased".loc, color: .green,
                          meaning: "lc.flek.memory.help.increased".loc)
                    state("lc.flek.memory.standard".loc, color: .gray,
                          meaning: "lc.flek.memory.help.standard".loc)
                } footer: {
                    Text("lc.flek.memory.help.footer".loc)
                }
            }
            .navigationTitle("lc.flek.memory.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func state(_ name: String, color: Color, meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .foregroundStyle(color)
            Text(meaning)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
