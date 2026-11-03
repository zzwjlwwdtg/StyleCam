import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var level: LevelMonitor

    @State private var pickerItem: PhotosPickerItem?
    @State private var showPanel = false
    @State private var holdOriginal = false
    @State private var flash = false
    @State private var showLibrary = false
    @State private var showCabinet = false
    @State private var showTether = false
    @State private var batchItems: [PhotosPickerItem] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                viewfinder
                if model.hasStyle { strengthBar }
                lensBar
                modeBar
                bottomBar
            }
            .padding(.bottom, 8)

            if let p = model.batchProgress {
                VStack(spacing: 10) {
                    ProgressView().tint(.yellow)
                    Text(p).font(.footnote)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

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
        .fullScreenCover(isPresented: $showTether) {
            TetherView(snapshot: model.camera.gradingSnapshot(), preferPerson: (model.profile?.faceCount ?? 1) > 0)
                .environmentObject(model)
        }
        .sheet(isPresented: $showCabinet) {
            FilmCabinetView().environmentObject(model)
        }
        .sheet(isPresented: $showLibrary) {
            RecipeLibraryView(store: model.recipes)
                .environmentObject(model)
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
        .onChange(of: batchItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await model.applyStyle(to: items)
                batchItems = []
            }
        }
        .onChange(of: camera.captureFlash) { _, _ in
            flash = true
            withAnimation(.easeOut(duration: 0.25)) { flash = false }
        }
        .onAppear {
            camera.start()
            level.start()
        }
        // Camera Control / 音量键 按下即拍
        .onCameraCaptureEvent { event in
            if event.phase == .ended { shutter() }
        }
    }

    // MARK: - 顶部：参考图、匹配度、改动数

    private var topBar: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                ZStack {
                    if let ref = model.referenceImage {
                        Image(uiImage: ref).resizable().scaledToFill()
                    } else if let p = model.currentPreset {
                        VStack(spacing: 2) {
                            Text(p.mood.emoji).font(.title3)
                            Text(p.brand.rawValue).font(.system(size: 9))
                        }
                    } else {
                        VStack(spacing: 2) {
                            Image(systemName: "photo.badge.plus")
                            Text("参考图").font(.system(size: 9))
                        }
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.yellow.opacity(model.hasStyle ? 1 : 0.3), lineWidth: 1.5))
            }

            VStack(alignment: .leading, spacing: 2) {
                if let score = camera.matchScore {
                    Text("风格匹配度 \(Int(score * 100))%").font(.subheadline.bold())
                        .foregroundStyle(score > 0.75 ? Color.green : (score > 0.55 ? Color.yellow : Color.orange))
                } else if let p = model.currentPreset {
                    Text(p.name).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text("上传一张喜欢的照片").font(.subheadline.bold())
                }
                Text(model.currentPreset.map { "\($0.mood.rawValue) · 按住取景框看原图" }
                     ?? (model.referenceImage == nil ? "或点下方「胶卷柜」选富士 / 佳能同款" : "按住取景框可看原图对比"))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            if model.referenceImage != nil {
                Button {
                    let all = OverlayMode.allCases
                    model.overlayMode = all[((all.firstIndex(of: model.overlayMode) ?? 0) + 1) % all.count]
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: model.overlayMode.symbol).font(.title3)
                        Text("构图·" + model.overlayMode.rawValue).font(.system(size: 9))
                    }
                    .foregroundStyle(model.overlayMode == .off ? Color.white : Color.yellow)
                }
            }

            if model.hasStyle {
                PhotosPicker(selection: $batchItems, maxSelectionCount: 30, matching: .images) {
                    VStack(spacing: 1) {
                        Image(systemName: "wand.and.stars").font(.title3)
                        Text("套用相册").font(.system(size: 9))
                    }
                }
            }

            Button { showTether = true } label: {
                VStack(spacing: 1) {
                    Image(systemName: "cable.connector").font(.title3)
                    Text("外接相机").font(.system(size: 9))
                }
            }
            .accessibilityLabel("连接外接相机")

            Button { showLibrary = true } label: {
                VStack(spacing: 1) {
                    Image(systemName: "books.vertical").font(.title3)
                    Text("风格库").font(.system(size: 9))
                }
            }

            if model.hasStyle {
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
                    .onChanged { _ in if model.hasStyle { holdOriginal = true } }
                    .onEnded { _ in holdOriginal = false })

            CompositionOverlay(
                reference: model.referenceImage,
                outline: model.outlineImage,
                mode: model.overlayMode,
                opacity: model.overlayOpacity,
                faceRect: model.profile?.faceRect,
                subjectRect: model.profile?.subjectRect,
                previewAspect: CompositionOverlay.previewAspect(cropRatio: model.matchAspect ? model.plan?.grading.cropRatio : nil),
                captureAngle: camera.captureRotationAngle,
                roll: level.roll,
                pitch: level.pitch,
                isLevel: level.isLevel,
                hint: model.referenceImage == nil || holdOriginal || model.overlayMode == .off ? nil : camera.compositionHint,
                aligned: camera.compositionAligned,
                referenceIsLandscape: model.profile?.isLandscape ?? false)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .allowsHitTesting(false)

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
        VStack(spacing: 6) {
            Picker("版本", selection: $model.variant) {
                ForEach(StyleVariant.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            HStack {
                Image(systemName: "camera.filters").foregroundStyle(.secondary)
                Slider(value: $model.strength, in: 0...1).tint(.yellow)
                Text(Fmt.percent(model.strength)).font(.caption.monospacedDigit()).frame(width: 40)
            }
            if model.overlayMode == .ghost {
                HStack {
                    Image(systemName: "square.on.square").foregroundStyle(.secondary)
                    Slider(value: $model.overlayOpacity, in: 0.1...0.7).tint(.white)
                    Text(Fmt.percent(model.overlayOpacity)).font(.caption.monospacedDigit()).frame(width: 40)
                }
            }
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

    private func shutter() {
        if camera.videoMode { camera.toggleRecording() } else { camera.capturePhoto() }
    }

    // MARK: - 照片 / 视频

    private var modeBar: some View {
        HStack(spacing: 12) {
            ForEach([false, true], id: \.self) { video in
                Button {
                    if !camera.isRecording { camera.setVideoMode(video) }
                } label: {
                    Text(video ? "视频" : "照片")
                        .font(.caption.bold())
                        .foregroundStyle(camera.videoMode == video ? Color.yellow : Color.white.opacity(0.7))
                }
            }
            Button { showCabinet = true } label: {
                HStack(spacing: 6) {
                    if let p = model.currentPreset {
                        CanisterArt(preset: p).frame(width: 12, height: 18)
                    } else {
                        Image(systemName: "film.stack")
                    }
                    Text(model.currentPreset?.stock.code ?? "胶卷柜")
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .disabled(camera.isRecording)
            if model.showsFlash && !camera.videoMode && camera.flashAvailable {
                Button {
                    let all = FlashSetting.allCases
                    model.flash = all[((all.firstIndex(of: model.flash) ?? 0) + 1) % all.count]
                } label: {
                    Label(model.flash.rawValue, systemImage: model.flash.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(model.flash == .off ? Color.white : Color.yellow)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("闪光灯 \(model.flash.rawValue)")
            }
            Button {
                let all = BeautyMode.allCases
                model.beauty.mode = all[((all.firstIndex(of: model.beauty.mode) ?? 0) + 1) % all.count]
            } label: {
                Label(model.beauty.mode == .off ? "美颜关" : model.beauty.mode.rawValue,
                      systemImage: model.beauty.mode == .off ? "face.dashed" : "face.smiling")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).fixedSize()
            }
            .buttonStyle(.glass)
            if camera.isRecording {
                Text(String(format: "● %02d:%02d", camera.recordingSeconds / 60, camera.recordingSeconds % 60))
                    .font(.caption.monospacedDigit()).foregroundStyle(.red)
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

            Button { shutter() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                    if camera.videoMode {
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(.red).frame(width: 62, height: 62)
                        }
                    } else {
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
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
