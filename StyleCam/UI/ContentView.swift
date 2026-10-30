import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraManager

    @State private var pickerItem: PhotosPickerItem?
    @State private var showPanel = false
    @State private var holdOriginal = false
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                viewfinder
                if model.referenceImage != nil { strengthBar }
                lensBar
                bottomBar
            }
            .padding(.bottom, 8)

            if model.isAnalyzing {
                VStack(spacing: 10) {
                    ProgressView().tint(.yellow)
                    Text("正在分析参考图并调整相机…").font(.footnote)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            if flash { Color.white.opacity(0.6).ignoresSafeArea().allowsHitTesting(false) }
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showPanel) {
            ParameterPanel()
                .environmentObject(model)
                .environmentObject(camera)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.loadReference(data)
                    showPanel = true
                }
                pickerItem = nil
            }
        }
        .onChange(of: camera.captureFlash) { _, _ in
            flash = true
            withAnimation(.easeOut(duration: 0.25)) { flash = false }
        }
        .onAppear { camera.start() }
        // Camera Control / 音量键 按下即拍
        .onCameraCaptureEvent { event in
            if event.phase == .ended { camera.capturePhoto() }
        }
    }

    // MARK: - 顶部：参考图、匹配度、改动数

    private var topBar: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                ZStack {
                    if let ref = model.referenceImage {
                        Image(uiImage: ref).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 2) {
                            Image(systemName: "photo.badge.plus")
                            Text("参考图").font(.system(size: 9))
                        }
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.yellow.opacity(model.referenceImage == nil ? 0.3 : 1), lineWidth: 1.5))
            }

            VStack(alignment: .leading, spacing: 2) {
                if let score = camera.matchScore {
                    Text("风格匹配度 \(Int(score * 100))%").font(.subheadline.bold())
                        .foregroundStyle(score > 0.75 ? Color.green : (score > 0.55 ? Color.yellow : Color.orange))
                } else {
                    Text("上传一张喜欢的照片").font(.subheadline.bold())
                }
                Text(model.referenceImage == nil ? "自动调相机参数，拍同款" : "按住取景框可看原图对比")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            if model.referenceImage != nil {
                Button { model.clearReference() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: - 取景框

    private var viewfinder: some View {
        ZStack(alignment: .top) {
            CameraPreview(frameStore: camera.frameStore, showOriginal: holdOriginal)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if model.referenceImage != nil { holdOriginal = true } }
                    .onEnded { _ in holdOriginal = false })

            readoutBar.padding(.top, 8)

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    HistogramView(reference: model.profile?.histogram, live: camera.liveHistogram)
                    Spacer()
                    if holdOriginal {
                        Text("原图").font(.caption.bold()).padding(6)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                }
                .padding(10)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }

    /// 实时读数；被本 App 锁定/修改过的参数标黄
    private var readoutBar: some View {
        let p = model.plan
        return HStack(spacing: 10) {
            readout(camera.readout.aperture, highlighted: p?.aperture != nil)
            readout(camera.readout.shutter, highlighted: p?.shutter != nil)
            readout(camera.readout.iso, highlighted: false)
            readout(camera.readout.bias, highlighted: (p?.bias ?? 0) != 0 || model.autoMatchExposure)
            readout(camera.readout.wb, highlighted: p?.wbOffset != nil)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private func readout(_ text: String, highlighted: Bool) -> some View {
        Text(text).foregroundStyle(highlighted ? Color.yellow : Color.white)
    }

    // MARK: - 风格强度

    private var strengthBar: some View {
        HStack {
            Image(systemName: "camera.filters").foregroundStyle(.secondary)
            Slider(value: $model.strength, in: 0...1).tint(.yellow)
            Text(Fmt.percent(model.strength)).font(.caption.monospacedDigit()).frame(width: 40)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 焦段

    private var lensBar: some View {
        HStack(spacing: 14) {
            ForEach(LensChoice.allCases) { l in
                let selected = camera.lens == l
                Button {
                    Task { await model.selectLens(l) }
                } label: {
                    Text(l.rawValue)
                        .font(.caption.bold())
                        .frame(width: 38, height: 38)
                        .background(selected ? Color.yellow.opacity(0.9) : Color.white.opacity(0.12), in: Circle())
                        .foregroundStyle(selected ? Color.black : Color.white)
                }
                .disabled(!camera.availableLenses.contains(l) || model.isAnalyzing)
                .opacity(camera.availableLenses.contains(l) ? 1 : 0.3)
            }
        }
    }

    // MARK: - 底部：最近照片 / 快门 / 参数面板

    private var bottomBar: some View {
        HStack {
            ZStack {
                if let img = camera.lastPhoto {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
                if camera.isSaving { ProgressView().tint(.white) }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            Button { camera.capturePhoto() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(.white).frame(width: 62, height: 62)
                }
            }

            Spacer()

            Button { showPanel = true } label: {
                VStack(spacing: 2) {
                    Image(systemName: "slider.horizontal.3").font(.title3)
                    Text(model.changes.isEmpty ? "参数" : "已改 \(model.modifiedCount) 项")
                        .font(.system(size: 10))
                }
                .frame(width: 54, height: 54)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 28)
        .overlay(alignment: .top) {
            if let msg = camera.statusMessage ?? model.errorMessage {
                Text(msg).font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule())
                    .offset(y: -30)
                    .onTapGesture { camera.statusMessage = nil; model.errorMessage = nil }
            }
        }
    }
}
