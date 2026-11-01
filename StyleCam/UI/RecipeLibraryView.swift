import SwiftUI
import CoreImage

/// 风格库：保存当前参考图为配方，随时切换、删除
struct RecipeLibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var askName = false
    @State private var showCabinet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showCabinet = true } label: {
                        HStack(spacing: 12) {
                            FilmCanister(stock: LookPresets.all[4].stock).frame(width: 26, height: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("胶卷柜").font(.system(.headline, design: .serif))
                                Text("\(LookPresets.all.count) 款富士 / 佳能同款滤镜，按情绪分组")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        newName = "风格 \(store.recipes.count + 1)"
                        askName = true
                    } label: {
                        Label("把当前参考图存为风格", systemImage: "plus.circle.fill")
                    }
                    .disabled(model.referenceImage == nil)
                } footer: {
                    Text("保存的是参考图本身（含拍摄参数）+ 版本 + 强度。下次打开 App 会自动恢复上次使用的风格。")
                }

                Section("我的风格（\(store.recipes.count)）") {
                    if store.recipes.isEmpty {
                        Text("还没有保存的风格").foregroundStyle(.secondary)
                    }
                    ForEach(store.recipes) { r in
                        Button {
                            Task {
                                await model.applyRecipe(r)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Group {
                                    if let t = store.thumbnail(r) {
                                        Image(uiImage: t).resizable().scaledToFill()
                                    } else {
                                        Color.gray.opacity(0.3)
                                    }
                                }
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.name).font(.subheadline.bold()).foregroundStyle(.primary)
                                    Text("\(r.variant) · 强度 \(Fmt.percent(r.strength))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(r.created.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.currentRecipeID == r.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx { store.delete(store.recipes[i]) }
                    }
                }
            }
            .sheet(isPresented: $showCabinet) {
                FilmCabinetView().environmentObject(model)
            }
            .navigationTitle("风格库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .alert("保存风格", isPresented: $askName) {
                TextField("名称", text: $newName)
                Button("保存") { model.saveRecipe(name: newName) }
                Button("取消", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }
}
