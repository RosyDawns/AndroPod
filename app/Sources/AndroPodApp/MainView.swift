import AndroPodCore
import SwiftUI

/// Device list — visual language lifted from MuMu 模拟器: a single-column list
/// of cards, each with a large 16:9 thumbnail (wallpaper placeholder with a
/// "未开机" power badge), the device name in bold, spec pills (核/GB), a
/// resolution line, and round play/more buttons on the right. The plus menu
/// offers 平板/手机 shapes; the more menu offers 设置/复制/删除.
struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.instances) { instance in
                        DeviceCard(instance: instance)
                            .environmentObject(model)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .sheet(isPresented: settingsBinding) {
                if let instance = settingsInstance {
                    SettingsSheet(instance: instance)
                        .environmentObject(model)
                }
            }
            .alert(
                deleteInstance.map { "删除「\($0.name)」？" } ?? "删除实例？",
                isPresented: deleteBinding,
                presenting: deleteInstance
            ) { instance in
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { model.delete(instance) }
            } message: { instance in
                Text("实例的磁盘与全部数据将被删除，此操作不可恢复。")
            }
            .alert(
                "启用 GPU 加速？",
                isPresented: gpuBinding,
                presenting: gpuInstance
            ) { instance in
                Button("取消", role: .cancel) { model.gpuSetupFor = nil }
                Button("启用并开机") { model.enableGPUAndStart(instance) }
            } message: { instance in
                Text(
                    "「\(instance.name)」走宿主 GPU 渲染（与 MuMu 同一条路径："
                    + "客机 GLES → Mesa/virgl → 宿主 Metal）。需要开启两项"
                    + "客机开关，只影响这台模拟器内部，不改动 macOS：\n\n"
                    + "• SELinux 宽容模式 —— virgl 需要 udmabuf 显存映射，"
                    + "强制模式下所有应用会渲染黑屏\n"
                    + "• 网络 ADB 免授权 —— 宿主需要连上客机做输入与截图\n\n"
                    + "重启后生效。"
                )
            }

            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    /// MuMu header: window title sits in the real title bar; this toolbar row
    /// keeps a centered brand text and account/plus actions on the right.
    private var header: some View {
        HStack(spacing: 10) {
            Text("我的安卓")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.working {
                ProgressView().controlSize(.small)
            }
            Button {
                model.status = "账号功能开发中"
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("账号")

            Menu {
                ForEach(DevicePreset.allCases) { preset in
                    Button {
                        model.createInstance(preset: preset)
                    } label: {
                        Label(preset.label, systemImage: preset.icon)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.working)
            .help("新建设备")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // Sheet/alert bindings derive from the model so cards stay free of
    // @State (unavailable on this toolchain — see AppModel note).

    private var settingsInstance: GuestInstance? {
        model.instances.first { $0.name == model.settingsFor }
    }

    private var deleteInstance: GuestInstance? {
        model.instances.first { $0.name == model.deleteConfirmFor }
    }

    private var settingsBinding: Binding<Bool> {
        Binding(
            get: { model.settingsFor != nil },
            set: { if !$0 { model.settingsFor = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { model.deleteConfirmFor != nil },
            set: { if !$0 { model.deleteConfirmFor = nil } }
        )
    }

    private var gpuInstance: GuestInstance? {
        model.instances.first { $0.name == model.gpuSetupFor }
    }

    private var gpuBinding: Binding<Bool> {
        Binding(
            get: { model.gpuSetupFor != nil },
            set: { if !$0 { model.gpuSetupFor = nil } }
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("知道了") { model.clearError() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

// MARK: - device card

struct DeviceCard: View {
    @EnvironmentObject private var model: AppModel
    let instance: GuestInstance

    private var running: Bool { model.isRunning(instance) }
    private var liveFrame: NSImage? { running ? model.frame(for: instance) : nil }

    var body: some View {
        HStack(spacing: 16) {
            thumbnail
            VStack(alignment: .leading, spacing: 7) {
                Text(instance.name)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    specPill("\(instance.cpus) 核")
                    specPill("\(instance.memoryMB / 1024) GB")
                    gpuPill
                }
                Text(instance.resolutionString(live: model.guestSize))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openDevice() }
    }

    /// The backend decides whether this device can resume from a snapshot, so
    /// it earns a pill instead of hiding inside settings. "兼容模式" is the
    /// 2D backend: slower rasterisation, but the only one that supports
    /// savevm, hence the only one that opens straight onto the launcher.
    @ViewBuilder
    private var gpuPill: some View {
        if instance.gpuBackend == "virgl" {
            if instance.selinuxPermissive && instance.insecureAdb {
                pillText("GPU 加速", color: .green)
            } else {
                pillText("GPU 待启用", color: .orange)
            }
        } else {
            pillText("兼容模式", color: .secondary)
        }
    }

    private func pillText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.14))
            )
    }

    /// MuMu's thumbnail: a live frame when running, otherwise a dark wallpaper
    /// stand-in with a translucent bottom strip holding a power glyph and
    /// "未开机" (or "连接中" while frames have not started arriving).
    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            if let image = liveFrame {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.16, blue: 0.38),
                            Color(red: 0.24, green: 0.42, blue: 0.72),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "mapp circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                        .offset(x: -60, y: -20)
                    Image(systemName: "app.dashed")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white.opacity(0.28))
                        .offset(x: -20, y: -22)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.yellow.opacity(0.85), Color.orange.opacity(0.8)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 26, height: 26)
                        .offset(x: 30, y: 4)
                    Circle()
                        .fill(Color.yellow.opacity(0.55))
                        .frame(width: 16, height: 16)
                        .offset(x: 52, y: 22)
                }
            }

            // Status strip: only over the placeholder (a live frame speaks
            // for itself), mirroring MuMu's 未开机 badge.
            if liveFrame == nil {
                ZStack {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.55)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    HStack(spacing: 6) {
                        // A running virgl guest never delivers a frame to us —
                        // its pixels live in the engine window. "连接中" would
                        // read as stuck; say what is actually true.
                        if running && instance.gpuBackend == "virgl" {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13, weight: .medium))
                            Text("GPU 运行中")
                                .font(.system(size: 13, weight: .medium))
                        } else {
                            Image(systemName: running ? "hourglass" : "power")
                                .font(.system(size: 13, weight: .medium))
                            Text(running ? "连接中" : "未开机")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)
                }
                .frame(height: 42)
            }
        }
        .frame(width: 280, height: 158)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if running {
                    model.stop(instance)
                } else {
                    model.start(instance)
                }
            } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.black.opacity(0.82)))
            }
            .buttonStyle(.plain)
            .disabled(model.working)
            .help(running ? "关机" : "开机")

            Menu {
                Button {
                    model.settingsFor = instance.name
                } label: {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
                Button {
                    model.duplicate(instance)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .disabled(running)
                Button(role: .destructive) {
                    model.deleteConfirmFor = instance.name
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Divider()
                Button("显示窗口") { openDevice() }
                    .disabled(!running)
                Button("初始化（退出回收模式 / 跳过向导）") { model.provision(instance) }
                    .disabled(!running)
                Button("保存快照") { model.snapshot(instance) }
                    .disabled(!running)
                Button("恢复快照") { model.restore(instance) }
                    .disabled(!running)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.working)
        }
    }

    /// The picture lives in the player's own window now, so "open" means
    /// bringing that window forward — not re-hosting the framebuffer here.
    /// The in-app window survives only for instances started outside the GUI
    /// (a CLI boot has no player process to raise).
    private func openDevice() {
        if running, EngineWindow.activate(pidFile: instance.pidFile) { return }
        DeviceWindowController.shared.show(instance, model: model)
    }
}

private func specPill(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
}

// MARK: - settings sheet

/// MuMu-style settings window: six tabs (设备/显示/性能/数据/开发者/全局)
/// across the top, content below. Fields that map to real instance.json knobs
/// are editable and saved on 保存; things AndroPod genuinely lacks are shown
/// read-only rather than faked as toggles.
enum SettingsTab: String, CaseIterable, Identifiable {
    case device, display, performance, data, developer, global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: return "设备"
        case .display: return "显示"
        case .performance: return "性能"
        case .data: return "数据"
        case .developer: return "开发者"
        case .global: return "全局"
        }
    }

    var icon: String {
        switch self {
        case .device: return "iphone"
        case .display: return "desktopcomputer"
        case .performance: return "cpu"
        case .data: return "internaldrive"
        case .developer: return "terminal"
        case .global: return "gearshape.2"
        }
    }
}

/// Editable copy of the config fields. A plain ObservableObject because the
/// toolchain lacks the @State macro family; the sheet observes it.
final class SettingsDraft: ObservableObject {
    @Published var tab: SettingsTab = .device
    @Published var name: String
    @Published var gpuBackend: String
    // display
    @Published var screenPreset: ScreenPreset
    @Published var xresText: String
    @Published var yresText: String
    @Published var dpiText: String
    // performance
    @Published var performancePreset: PerformancePreset
    @Published var cpus: Int
    @Published var memoryGB: Int
    // developer
    @Published var touch: Bool
    // boot switches (direct kernel boot cmdline; user opt-in per instance)
    @Published var insecureAdb: Bool
    @Published var selinuxPermissive: Bool

    enum ScreenPreset: String, CaseIterable, Identifiable {
        case tablet, phone, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tablet: return "平板"
            case .phone: return "手机"
            case .custom: return "自定义"
            }
        }
    }

    enum PerformancePreset: String, CaseIterable, Identifiable {
        case balanced, high, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .balanced: return "均衡"
            case .high: return "高性能"
            case .custom: return "自定义"
            }
        }
    }

    init(instance: GuestInstance) {
        name = instance.name
        gpuBackend = instance.gpuBackend
        let x = instance.xres ?? Int(1280)
        let y = instance.yres ?? Int(800)
        let d = instance.dpi ?? 160
        xresText = String(x)
        yresText = String(y)
        dpiText = String(d)
        if x == 1600, y == 945 {
            screenPreset = .tablet
        } else if x == 1080, y == 1920 {
            screenPreset = .phone
        } else {
            screenPreset = .custom
        }
        cpus = instance.cpus
        memoryGB = max(1, instance.memoryMB / 1024)
        if instance.cpus == 4, instance.memoryMB == 6144 {
            performancePreset = .balanced
        } else if instance.cpus == 8, instance.memoryMB == 8192 {
            performancePreset = .high
        } else {
            performancePreset = .custom
        }
        touch = true
        insecureAdb = instance.insecureAdb
        selinuxPermissive = instance.selinuxPermissive
    }

    func applyScreenPreset() {
        switch screenPreset {
        case .tablet:
            xresText = "1600"; yresText = "945"; dpiText = "236"
        case .phone:
            xresText = "1080"; yresText = "1920"; dpiText = "480"
        case .custom:
            break
        }
    }

    func applyPerformancePreset() {
        switch performancePreset {
        case .balanced:
            cpus = 4; memoryGB = 6
        case .high:
            cpus = 8; memoryGB = 8
        case .custom:
            break
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var draft: SettingsDraft
    let instance: GuestInstance
    @Environment(\.dismiss) private var dismiss

    init(instance: GuestInstance) {
        self.instance = instance
        _draft = ObservedObject(wrappedValue: SettingsDraft(instance: instance))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(instance.name) - 设置")
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 14)
            tabRow
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 34)
                    .padding(.vertical, 22)
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 620)
        .onAppear { model.computeDiskUsage(instance) }
    }

    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    draft.tab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19))
                        Text(tab.title)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(draft.tab == tab ? Color.accentColor : Color.secondary)
                    .frame(width: 76, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(draft.tab == tab ? Color.accentColor.opacity(0.10) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch draft.tab {
        case .device: devicePage
        case .display: displayPage
        case .performance: performancePage
        case .data: dataPage
        case .developer: developerPage
        case .global: globalPage
        }
    }

    // MARK: pages

    private var devicePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsRow("设备名称:") {
                TextField("设备名称", text: .constant(instance.name))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                    .help("暂不支持改名（涉及磁盘路径迁移）")
            }
            settingsRow("图形后端:") {
                Picker("", selection: $draft.gpuBackend) {
                    Text("2D（SwiftShader 软渲染）").tag("2d")
                    Text("virgl（宿主 GPU 加速）").tag("virgl")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            settingsRow("ADB:") {
                valueText(instance.adbSerial)
            }
            settingsRow("引导开关:") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("网络 ADB 免授权（insecure adb）", isOn: $draft.insecureAdb)
                    Toggle("SELinux 宽容模式（GPU 加速必需）", isOn: $draft.selinuxPermissive)
                    hint("由引擎内核命令行注入（MuMu 同款机制），下次冷启动生效。等价于 GRUB 菜单里的官方 Settings 项，但不改镜像文件。")
                }
            }
            settingsRow("VNC:") {
                valueText(instance.vncPort.map { "127.0.0.1:\($0)" } ?? "未启用（抓帧通路）")
            }
        }
    }

    private var displayPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsRow("屏幕尺寸:") {
                // MuMu's inline radio row: 平板 / 手机 / 自定义.
                HStack(spacing: 22) {
                    radioOption("平板", icon: "ipad.landscape", selected: draft.screenPreset == .tablet) {
                        draft.screenPreset = .tablet
                        draft.applyScreenPreset()
                    }
                    radioOption("手机", icon: "iphone", selected: draft.screenPreset == .phone) {
                        draft.screenPreset = .phone
                        draft.applyScreenPreset()
                    }
                    radioOption("自定义", icon: "pencil.and.list.clipboard", selected: draft.screenPreset == .custom) {
                        draft.screenPreset = .custom
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 12) {
                    HStack {
                        Text("宽:").frame(width: 40, alignment: .trailing)
                        TextField("1600", text: $draft.xresText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    }
                    HStack {
                        Text("高:").frame(width: 40, alignment: .trailing)
                        TextField("945", text: $draft.yresText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    }
                    HStack {
                        Text("DPI:").frame(width: 40, alignment: .trailing)
                        TextField("236", text: $draft.dpiText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                Spacer(minLength: 0)
            }
            hint("分辨率在 2D 实例上会传给 virtio-gpu；virgl 实例当前固定自身模式（实验 E10）。")
        }
    }

    private var performancePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsRow("性能配置:") {
                Picker("", selection: $draft.performancePreset) {
                    ForEach(SettingsDraft.PerformancePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .frame(width: 180)
                .onChange(of: draft.performancePreset) { _ in draft.applyPerformancePreset() }
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 12) {
                    Stepper("处理器:  \(draft.cpus) 核", value: $draft.cpus, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                        .frame(width: 240, alignment: .leading)
                    Stepper("运行内存:  \(draft.memoryGB) GB", value: $draft.memoryGB, in: 1...16)
                        .frame(width: 240, alignment: .leading)
                }
                .padding(16)
                .frame(width: 500)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                Spacer(minLength: 0)
            }
            hint("多开时建议每实例 4 核 6 GB 以内，留出宿主余量。")
        }
    }

    private var dataPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsRow("磁盘占用:") {
                VStack(alignment: .leading, spacing: 8) {
                    if let bytes = model.diskUsageBytes[instance.name] {
                        valueText(String(format: "当前占用空间 %.2f GB", Double(bytes) / 1_073_741_824))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("清理") { model.status = "磁盘清理将在后续版本提供（需 fstrim 通路）" }
                        .disabled(true)
                    hint("磁盘清理可回收安卓设备的空闲空间。请在安卓设备运行时开始清理。")
                }
            }
            settingsRow("设备存储:") {
                VStack(alignment: .leading, spacing: 8) {
                    valueText(instance.workdir.path)
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([instance.workdir])
                    }
                }
            }
        }
    }

    private var developerPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsRow("触摸注入:") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("附加 virtio 触摸屏（游戏和部分系统弹窗需要）", isOn: $draft.touch)
                    hint("游戏与系统弹窗往往忽略鼠标按键，需要触摸事件流。")
                }
            }
            settingsRow("显示通路:") {
                valueText(
                    instance.vncPort != nil
                        ? "VNC / ZRLE（增量推流）"
                        : "QMP screendump 抓帧"
                )
            }
            settingsRow("启动命令:") {
                VStack(alignment: .leading, spacing: 8) {
                    valueText("qemu.cmd（最近一次启动的完整 QEMU 参数）")
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([instance.commandLine])
                    }
                }
            }
        }
    }

    private var globalPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsRow("设备存储目录:") {
                VStack(alignment: .leading, spacing: 8) {
                    valueText(instance.workdir.deletingLastPathComponent().path)
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [instance.workdir.deletingLastPathComponent()]
                        )
                    }
                    hint("新建和复制模拟器时的数据存储路径。")
                }
            }
            settingsRow("老板键:") {
                valueText("不适用（AndroPod 无窗口池，无此需求）")
            }
            settingsRow("退出行为:") {
                valueText("关闭窗口即退出实例管理，虚拟机状态保存在快照中")
            }
        }
    }

    // MARK: pieces

    private var footer: some View {
        HStack {
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func save() {
        var saved = false
        if draft.gpuBackend != instance.gpuBackend {
            saved = model.updateInstanceConfig(instance, gpuBackend: draft.gpuBackend) || saved
        }
        if draft.touch != instance.touch {
            saved = model.updateInstanceConfig(instance, touch: draft.touch) || saved
        }
        if draft.insecureAdb != instance.insecureAdb
            || draft.selinuxPermissive != instance.selinuxPermissive {
            saved = model.updateInstanceConfig(
                instance,
                insecureAdb: draft.insecureAdb,
                selinuxPermissive: draft.selinuxPermissive
            ) || saved
        }
        let x = Int(draft.xresText), y = Int(draft.yresText), dpi = Int(draft.dpiText)
        let currentX = instance.xres ?? 1280
        let currentY = instance.yres ?? 800
        let currentDpi = instance.dpi ?? 160
        if x != currentX || y != currentY || dpi != currentDpi {
            if let x, let y, x > 0, y > 0 {
                saved = model.updateInstanceConfig(
                    instance, xres: x, yres: y, dpi: dpi ?? 160
                ) || saved
            } else {
                model.lastError = "分辨率需为正整数"
                return
            }
        }
        if draft.cpus != instance.cpus || draft.memoryGB * 1024 != instance.memoryMB {
            saved = model.updateInstanceConfig(
                instance, cpus: draft.cpus, memoryMB: draft.memoryGB * 1024
            ) || saved
        }
        if saved {
            model.refresh()
        } else {
            model.status = "配置未变化"
        }
        dismiss()
    }

    private func settingsRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 96, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .textSelection(.enabled)
    }

    /// MuMu-style inline radio: circle glyph + label, blue when selected.
    private func radioOption(
        _ title: String, icon: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.4)
                        .frame(width: 15, height: 15)
                    if selected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
