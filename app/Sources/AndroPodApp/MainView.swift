import AndroPodCore
import SwiftUI

/// Device grid — mirrors MuMu's main window: a list of device cards, each with a
/// live thumbnail, name, specs, and a play button.
struct MainView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.instances) { instance in
                        DeviceCard(instance: instance)
                            .environmentObject(model)
                    }
                    addCard
                }
                .padding(18)
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("我的设备")
                .font(.system(size: 13, weight: .semibold))
            Text("\(model.instances.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if model.working {
                ProgressView().controlSize(.small)
            }
            Button {
                model.createInstance()
            } label: {
                Label("新建", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .disabled(model.working)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var addCard: some View {
        Button {
            model.createInstance()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                Text("新建设备")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 116)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            )
        }
        .buttonStyle(.plain)
        .disabled(model.working)
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

struct DeviceCard: View {
    @EnvironmentObject private var model: AppModel
    let instance: GuestInstance

    private var running: Bool { model.isRunning(instance) }
    private var resolution: String {
        let size = model.guestSize
        return "\(Int(size.width)) × \(Int(size.height)) · 160 DPI"
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(instance.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Circle()
                        .fill(running ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
                Text("\(instance.cpus) 核 · \(instance.memoryMB / 1024) GB")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(resolution)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            controls
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openDevice() }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black)
            if running, let image = model.frame(for: instance) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "display")
                        .font(.system(size: 15, weight: .ultraLight))
                    Text(running ? "连接中" : "未开机")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: 124, height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                if running {
                    model.stop(instance)
                } else {
                    model.start(instance)
                }
            } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderedProminent)
            .tint(running ? Color.secondary : Color.accentColor)
            .disabled(model.working)
            .help(running ? "关机" : "开机")

            Menu {
                Button("打开界面") { openDevice() }
                    .disabled(!running)
                Divider()
                Button("初始化（退出回收模式 / 跳过向导）") { model.provision(instance) }
                    .disabled(!running)
                Button("保存快照") { model.snapshot(instance) }
                    .disabled(!running)
                Button("恢复快照") { model.restore(instance) }
                    .disabled(!running)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
            .disabled(model.working)
        }
    }

    private func openDevice() {
        DeviceWindowController.shared.show(instance, model: model)
    }
}
