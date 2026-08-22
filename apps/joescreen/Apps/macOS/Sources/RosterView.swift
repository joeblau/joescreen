import SwiftUI
import JoeScreenKit

/// Native session navigator. One tagged selection enum drives the detail area; there are no
/// per-row selection booleans. The List keeps its system sidebar material and keyboard behavior.
struct SessionSidebar: View {
    @Environment(AppModel.self) private var model
    let onLeave: () -> Void

    private var sortedParticipants: [ParticipantID] {
        model.participants.sorted {
            let lhs = model.displayLabel(for: $0).localizedCaseInsensitiveCompare(model.displayLabel(for: $1))
            return lhs == .orderedSame ? $0.uuidString < $1.uuidString : lhs == .orderedAscending
        }
    }

    /// A native single-selection List uses an optional binding. Refuse nil writes so the detail area
    /// always has exactly one `SidebarSelection` source of truth in AppModel.
    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: { model.sidebarSelection },
            set: { if let selection = $0 { model.sidebarSelection = selection } })
    }

    var body: some View {
        @Bindable var model = model
        List(selection: selection) {
            Section(isExpanded: $model.screenSharesSectionExpanded) {
                HStack {
                    Label("All Screens", systemImage: "rectangle.grid.2x2")
                    Spacer()
                    Text("\(model.sharedWindowsSorted.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(SidebarSelection.screenShares)
            } header: {
                Text("Screen Shares")
            }

            Section(isExpanded: $model.notesSectionExpanded) {
                Label("Meeting Notes", systemImage: "note.text")
                    .tag(SidebarSelection.notes)
            } header: {
                Text("Notes")
            }

            Section(isExpanded: $model.participantsSectionExpanded) {
                if sortedParticipants.isEmpty {
                    Label("Waiting for participants…", systemImage: "person.2")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedParticipants, id: \.self) { id in
                        RosterRow(id: id, isLocal: id == model.localParticipantID)
                            .tag(SidebarSelection.participant(id))
                    }
                }
            } header: {
                Text("Participants")
            }
        }
        .listStyle(.sidebar)
        // Same macOS 26 resize-crash guard as SessionDetail: keep this column's reported min/max
        // size constant through a live-resize constraint pass. Min width matches the column floor.
        .frame(minWidth: 190, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        // Keep the leading navigation item owned by the sidebar column. This lets AppKit animate
        // the sidebar and its toolbar region as one native split-view transaction.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onLeave) {
                    Label("Leave Session", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Leave the session")
            }
        }
    }
}

struct RosterRow: View {
    @Environment(AppModel.self) private var model
    let id: ParticipantID
    let isLocal: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.color(for: id))
                .frame(width: 12, height: 12)
            Text(model.displayLabel(for: id))
                .font(.body)
            if isLocal {
                Text("(you)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isLocal, model.isCoLocated(id) {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Co-located: your mic auto-yields while this participant speaks")
            }
            let count = model.room.windows(ownedBy: id).count
            if count > 0 {
                Image(systemName: "macwindow")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !isLocal {
                Button(model.isCoLocated(id) ? "Unmark as Co-located" : "Mark as Co-located") {
                    model.setCoLocated(id, !model.isCoLocated(id))
                }
            }
        }
    }
}
