import SwiftUI

/// A Space becomes a creative thread when it has an explicit question or direction.
/// References, its Board, and Ask Loci already share the same collection scope.
struct CreativeThreadBriefSheet: View {
    let threadName: String
    @Binding var brief: String
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: LociSpacing.component) {
            VStack(alignment: .leading, spacing: LociSpacing.tight) {
                Text("Creative Thread")
                    .font(LociFont.title)
                    .foregroundStyle(LociColor.ink)
                Text(threadName)
                    .font(LociFont.caption)
                    .foregroundStyle(LociColor.inkTertiary)
            }

            Text("Write the question, feeling, or decision this space is helping you make. Ask Loci can use this as the thread’s north star.")
                .font(LociFont.body)
                .foregroundStyle(LociColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $brief)
                .font(LociFont.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 150)
                .background(LociColor.surfaceRecessed, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LociColor.hairline, lineWidth: 1)
                }
                .accessibilityLabel("Creative brief")

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save brief") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(LociSpacing.panel)
        .frame(width: 520)
        .background(LociColor.surface)
    }
}
