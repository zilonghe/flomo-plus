import SwiftUI

struct CustomLensSheet: View {
    let store: AppStore
    @State private var input: LensEdit
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore, lens: InsightLens?) {
        self.store = store
        _input = State(initialValue: LensEdit(lens: lens))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $input.name)
                TextField("分类", text: $input.category)
                TextField("描述", text: $input.description, axis: .vertical)
                TextField("分析提示词", text: $input.prompt, axis: .vertical).lineLimit(4...12)
                if input.id != nil { Button("删除视角", role: .destructive) { confirmDelete = true }.disabled(saving) }
                InlineError(message: error)
            }
            .weijiSheetBackground()
            .navigationTitle(input.id == nil ? "新视角" : "编辑视角")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { perform(remove: false) }
                        .disabled(saving || store.api == nil || [input.name, input.category, input.description, input.prompt]
                            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
            .confirmationDialog("删除此视角？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { perform(remove: true) }
            }
        }
        .tint(Theme.active)
        .interactiveDismissDisabled(saving)
    }

    private func perform(remove: Bool) {
        guard let api = store.api else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                if remove, let id = input.id { try await store.insights.deleteLens(id, api: api) }
                else { try await store.insights.saveLens(input, api: api) }
                dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
