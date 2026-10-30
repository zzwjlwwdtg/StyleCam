import Foundation
import UIKit
import Combine

/// 风格配方：保存参考图原文件（保留 EXIF）+ 版本 + 强度。载入时重新分析，保证与最新算法一致。
struct StyleRecipe: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var created: Date
    var variant: String
    var strength: Double
}

@MainActor
final class RecipeStore: ObservableObject {
    @Published private(set) var recipes: [StyleRecipe] = []

    private let dir: URL
    private let lastKey = "stylecam.lastRecipeID"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Recipes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    private func meta(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    private func image(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).img") }
    private func thumb(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString)_thumb.jpg") }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        recipes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(StyleRecipe.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    @discardableResult
    func save(name: String, referenceData: Data, thumbnail: UIImage?, variant: StyleVariant, strength: Double) -> StyleRecipe {
        let r = StyleRecipe(id: UUID(), name: name.isEmpty ? "未命名风格" : name, created: Date(),
                            variant: variant.rawValue, strength: strength)
        try? referenceData.write(to: image(r.id))
        if let t = thumbnail?.preparingThumbnail(of: CGSize(width: 160, height: 160)),
           let jpg = t.jpegData(compressionQuality: 0.8) {
            try? jpg.write(to: thumb(r.id))
        }
        if let json = try? JSONEncoder().encode(r) { try? json.write(to: meta(r.id)) }
        markLast(r)
        reload()
        return r
    }

    func update(_ r: StyleRecipe) {
        if let json = try? JSONEncoder().encode(r) { try? json.write(to: meta(r.id)) }
        reload()
    }

    func delete(_ r: StyleRecipe) {
        for u in [meta(r.id), image(r.id), thumb(r.id)] { try? FileManager.default.removeItem(at: u) }
        if UserDefaults.standard.string(forKey: lastKey) == r.id.uuidString {
            UserDefaults.standard.removeObject(forKey: lastKey)
        }
        reload()
    }

    func referenceData(_ r: StyleRecipe) -> Data? { try? Data(contentsOf: image(r.id)) }
    func thumbnail(_ r: StyleRecipe) -> UIImage? { UIImage(contentsOfFile: thumb(r.id).path) }

    func markLast(_ r: StyleRecipe) {
        UserDefaults.standard.set(r.id.uuidString, forKey: lastKey)
        try? FileManager.default.removeItem(at: lastReferenceURL)
    }

    func clearLast() {
        UserDefaults.standard.removeObject(forKey: lastKey)
        try? FileManager.default.removeItem(at: lastReferenceURL)
    }

    /// 没有存成配方的参考图也记住，下次打开自动恢复
    private var lastReferenceURL: URL { dir.appendingPathComponent("last-reference.img") }
    func saveLastReference(_ data: Data) {
        UserDefaults.standard.removeObject(forKey: lastKey)
        try? data.write(to: lastReferenceURL)
    }
    func lastReferenceData() -> Data? { try? Data(contentsOf: lastReferenceURL) }

    var lastUsed: StyleRecipe? {
        guard let s = UserDefaults.standard.string(forKey: lastKey) else { return nil }
        return recipes.first { $0.id.uuidString == s }
    }
}
