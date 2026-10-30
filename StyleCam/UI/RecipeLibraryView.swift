import SwiftUI
import CoreImage

/// 风格库：保存当前参考图为配方，随时切换、删除
struct RecipeLibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var askName = false
    @State private var brand: PresetBrand?
    @StateObject private var thumbs = PresetThumbnails()

    private var presets: [LookPreset] { LookPresets.all.filter { brand == nil || $0.brand == brand } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("品牌", selection: $brand) {
                        Text("全部").tag(PresetBrand?.none)
                        ForEach(PresetBrand.allCases) { Text($0.rawValue).tag(PresetBrand?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("内置滤镜 · 富士 / 佳能同款（\(LookPresets.all.count)）")
                } footer: {
                    Text("缩略图是用当前取景画面实时生成的。仿色风格：参数按各胶片模拟 / 照片风格公开的观感特征近似，非厂商官方配置；颗粒按画面已有噪点只补差值。")
                }

                ForEach(PresetMood.allCases) { mood in
                    let items = presets.filter { $0.mood == mood }
                    if !items.isEmpty {
                        Section("\(mood.emoji) \(mood.rawValue)") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 10) {
                                    ForEach(items) { p in presetCell(p) }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
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
            .onAppear { thumbs.render(from: model.camera.frameStore.latest(original: true)) }
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

    private func presetCell(_ p: LookPreset) -> some View {
        Button {
            Task {
                await model.applyPreset(p)
                dismiss()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let t = thumbs.images[p.id] {
                            Image(uiImage: t).resizable().scaledToFill()
                        } else {
                            Color.gray.opacity(0.25)
                        }
                    }
                    .frame(width: 96, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow, lineWidth: model.currentPreset?.id == p.id ? 2 : 0))
                    Text(p.brand.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(p.brand == .fuji ? Color.green.opacity(0.8) : Color.red.opacity(0.8), in: Capsule())
                        .padding(4)
                }
                Text(p.name).font(.caption2.bold()).foregroundStyle(.primary)
                    .lineLimit(2).frame(width: 96, alignment: .leading)
                Text(p.note).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(3).frame(width: 96, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 用当前取景画面给每个内置滤镜生成小样（只套色彩影调，不加颗粒）
@MainActor
final class PresetThumbnails: ObservableObject {
    @Published var images: [String: UIImage] = [:]
    private var busy = false

    func render(from frame: CIImage?) {
        guard !busy, let frame else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let ctx = CIContext()
            let e = frame.extent
            let s = 260 / max(e.width, e.height)
            let scaled = frame.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            // 取景帧的像素缓冲会被复用，先拷贝出来
            guard let base = ctx.createCGImage(scaled, from: scaled.extent.integral) else {
                await MainActor.run { self.busy = false }
                return
            }
            let small = CIImage(cgImage: base)
            let renderer = StyleRenderer()
            for p in LookPresets.all {
                var g = p.grading
                g.grain = 0; g.grainAddSigma = 0
                let st = StyleRenderer.State(params: g, lut: LUTBuilder.build(g),
                                             skinLut: LUTBuilder.build(g, skinVersion: true), enabled: true)
                let out = renderer.apply(small, state: st)
                if let cg = ctx.createCGImage(out, from: out.extent) {
                    let img = UIImage(cgImage: cg)
                    await MainActor.run { self.images[p.id] = img }
                }
            }
            await MainActor.run { self.busy = false }
        }
    }
}
