// The task list: add, edit titles, check off, drag to reorder, delete, and tag.

import SwiftUI
import TetherCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var newTitle = ""
    @State private var showsDebug = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New item", text: $newTitle)
                            .onSubmit(add)
                        Button("Add", systemImage: "plus.circle.fill", action: add)
                            .labelStyle(.iconOnly)
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(model.items) { item in
                        ItemRow(item: item, model: model)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                    .onDelete { model.delete(at: $0) }
                }
            }
            .navigationTitle(model.title)
            .toolbar {
                Button("Debug", systemImage: "ladybug") { showsDebug.toggle() }
            }
            .safeAreaInset(edge: .bottom) {
                if showsDebug { DebugOverlay(info: model.debug, itemCount: model.items.count) }
            }
            .overlay {
                if let failure = model.failure {
                    ContentUnavailableView(
                        "Sync stopped", systemImage: "exclamationmark.triangle",
                        description: Text(failure))
                }
            }
        }
        .task { await model.start() }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        model.add(title)
        newTitle = ""
    }
}

private struct ItemRow: View {
    let item: Item
    let model: AppModel
    @State private var draft = ""

    var body: some View {
        HStack {
            Button(
                item.done ? "Mark not done" : "Mark done",
                systemImage: item.done ? "checkmark.circle.fill" : "circle"
            ) {
                model.toggle(item)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            TextField("Title", text: $draft)
                .strikethrough(item.done)
                .onSubmit { model.rename(item, to: draft) }

            ForEach(item.tags.sorted(), id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .background(.tint.opacity(0.2), in: .capsule)
            }
        }
        .onChange(of: item.title, initial: true) { draft = item.title }
        .contextMenu {
            Button(
                item.tags.contains("urgent") ? "Remove “urgent”" : "Tag “urgent”",
                systemImage: "tag"
            ) {
                model.toggleTag("urgent", on: item)
            }
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(item) }
        }
    }
}
