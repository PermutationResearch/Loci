import SwiftUI

struct WikiEditorView: View {
    var slug: String
    var vaultRoot: URL
    @State private var content = ""
    @State private var originalContent = ""
    @State private var isSaving = false
    @State private var showSaveConfirmation = false
    @Environment(\.dismiss) private var dismiss

    private var hasChanges: Bool { content != originalContent }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider().opacity(0.3)
            textEditor
        }
        .background(Color.white)
        .task(id: slug) {
            loadContent()
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                    Text("Back")
                        .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                }
                .foregroundStyle(.black.opacity(0.58))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.045), in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Text(slug.replacingOccurrences(of: "-", with: " ").capitalized)
                .lociFont(size: 12, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(.black.opacity(0.72))

            Spacer()

            if hasChanges {
                Button {
                    saveContent()
                } label: {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "checkmark")
                                .lociFont(size: 9, weight: .bold, relativeTo: .caption2)
                        }
                        Text("Save")
                            .lociFont(size: 11, weight: .semibold, relativeTo: .caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.78), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var textEditor: some View {
        TextEditor(text: $content)
            .lociFont(size: 12, design: .monospaced, relativeTo: .caption)
            .foregroundStyle(.black.opacity(0.78))
            .scrollContentBackground(.hidden)
            .padding(16)
    }

    private func loadContent() {
        let url = vaultRoot.appendingPathComponent("wiki/references/\(slug).md")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            content = text
            originalContent = text
        }
    }

    private func saveContent() {
        isSaving = true
        let url = vaultRoot.appendingPathComponent("wiki/references/\(slug).md")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            originalContent = content
            showSaveConfirmation = true
        } catch {
            print("Failed to save wiki page: \(error)")
        }
        isSaving = false
    }
}
