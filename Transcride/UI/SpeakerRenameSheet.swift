import SwiftUI

/// Speaker rename (TRN-6): one text field per detected speaker. Names are
/// stored in the entry's frontmatter and applied to every rendered view and
/// the generated note; the JSON keeps the stable machine ids (S1, S2, …).
struct SpeakerRenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let entry: Entry
    /// Machine ids in order of first appearance in the transcript.
    let speakerIDs: [String]
    let currentNames: [String: String]

    @State private var names: [String: String] = [:]
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Speakers")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(speakerIDs, id: \.self) { id in
                    GridRow {
                        Text(SpeakerNames.defaultDisplayName(forID: id))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        TextField(
                            SpeakerNames.defaultDisplayName(forID: id),
                            text: binding(for: id)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                    }
                }
            }

            Text("Names apply to this entry only. Leave a field empty to keep the default label. The timed transcript keeps stable ids, so you can rename again anytime.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            for id in speakerIDs {
                names[id] = currentNames[id.uppercased()] ?? ""
            }
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { names[id] ?? "" },
            set: { names[id] = $0 }
        )
    }

    private func save() {
        isSaving = true
        let renames: [String: String?] = Dictionary(uniqueKeysWithValues: speakerIDs.map { id in
            let trimmed = (names[id] ?? "").trimmingCharacters(in: .whitespaces)
            return (id, trimmed.isEmpty ? nil : trimmed)
        })
        Task {
            await model.renameSpeakers(renames, for: entry)
            dismiss()
        }
    }
}
