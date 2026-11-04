import SwiftUI

/// The panel's Reply tab (V6): the notes in document order, each a solid card (its lines, the
/// passage, the note's text), the verdict, an optional summary and the Markdown it makes, then
/// Send (⌘↩) at the bottom. The draft is the page's (Page.reply), saved per document.
struct ReplyTab: View {
    @Bindable var page: Page
    @FocusState private var focus: UUID?
    @State private var confirmClear = false
    @State private var previewOpen = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var ordered: [Note] { page.reply.notes.sorted { ($0.start, $0.created) < ($1.start, $1.created) } }

    /// A note's binding by id, not index: deleting one never leaves a row pointing past the end.
    private func binding(_ note: Note) -> Binding<Note> {
        Binding(get: { page.reply.notes.first { $0.id == note.id } ?? note },
                set: { new in if let i = page.reply.notes.firstIndex(where: { $0.id == note.id }) { page.reply.notes[i] = new } })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if page.reply.notes.isEmpty {
                            PanelHint(text: Text("Select a passage in the page, then press m or click Add Note."))
                                .padding(.bottom, 6)
                        }
                        ForEach(ordered) { note in
                            NoteCard(note: binding(note), focus: $focus,
                                     go: { page.go(toLine: note.start) },
                                     delete: { page.reply.notes.removeAll { $0.id == note.id } })
                                .id(note.id)
                        }
                        verdict.padding(.top, 6)
                        field("Summary (optional)", text: $page.reply.summary)
                        preview
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .onChange(of: page.noteFocus, initial: true) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                    focus = id
                    page.noteFocus = nil
                }
            }
            Divider()
            footer
        }
    }

    private var verdict: some View {
        Picker("Verdict", selection: $page.reply.verdict) {
            Text("Approve").tag(Verdict?.some(.approve))
            Text("Request changes").tag(Verdict?.some(.changes))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Verdict")
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(title, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(1...6)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .hairline), lineWidth: 1))
            .accessibilityLabel(title)
    }

    /// The Markdown that Send hands over, as it will read.
    private var preview: some View {
        DisclosureGroup(isExpanded: $previewOpen) {
            Text(verbatim: page.replyMarkdown)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .hairline), lineWidth: 1))
        } label: {
            Text("Preview").font(.system(size: 12, weight: .medium))
        }
        .padding(.top, 2)
    }

    /// Where Send goes, what the last one did, Clear and Send.
    private var footer: some View {
        let empty = page.reply == Reply()
        // Its temp dir goes when the CLI stops waiting (timeout, Ctrl-C): checked as the tab draws.
        let waiting = page.waiting.map { FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if let sent = page.sent { Text(verbatim: sent) }
                else if waiting { Text("An agent is waiting for this reply.") }
                else { Text("Send copies the reply to the clipboard.") }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(GlassLabel.style(strong: page.sent != nil, opaque: reduceTransparency))
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear") { confirmClear = true }
                    .actionButton()
                    .disabled(empty)
                    .confirmationDialog("Clear this reply?", isPresented: $confirmClear) {
                        Button("Clear Reply", role: .destructive) { page.reply = Reply() }
                    } message: {
                        Text("Its notes, verdict and summary go. The document is not changed.")
                    }
                Spacer()
                Button { page.sendReply() } label: { waiting ? Text("Send to Agent") : Text("Send") }
                    .primaryButton()
                    .disabled(!page.reply.canSend)
                    .help(Text(verbatim: KeyboardShortcut.sendReply.glyph))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// One note: its lines (a button back to the passage), the passage, its text and a delete button.
private struct NoteCard: View {
    @Binding var note: Note
    var focus: FocusState<UUID?>.Binding
    let go: () -> Void
    let delete: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let lines = note.start == note.end ? "L\(note.start)" : "L\(note.start)–\(note.end)"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button(action: go) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: lines)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                        Text(verbatim: note.quote)
                            .font(.system(size: 12))
                            .foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
                            .lineLimit(3)
                            .padding(.leading, 7)
                            .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: lines + ", " + note.quote))
                .accessibilityHint("Shows the passage in the page")
                Button(action: delete) {
                    Image(systemName: "trash").font(.system(size: 12)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete Note")
                .accessibilityLabel("Delete Note")
                .frame(maxHeight: .infinity, alignment: .top)
            }
            TextField("Note", text: $note.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...8)
                .focused(focus, equals: note.id)
                .accessibilityLabel(Text("Note text") + Text(verbatim: ", " + lines))
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .hairline), lineWidth: 1))
    }
}
