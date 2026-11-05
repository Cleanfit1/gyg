import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationBridge.shared
        return true
    }
}

@main
struct XiaopihaiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store) }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $store.selectedTab) {
            NavigationStack {
                List {
                    Button { store.showChat = true } label: {
                        HStack(spacing: 12) {
                            AvatarView(size: 48)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("小屁孩").font(.headline)
                                Text(store.archive.messages.last?.content ?? "点开开始聊天")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 6)
                    }
                }.navigationTitle("微信")
                .navigationDestination(isPresented: $store.showChat) { ChatView() }
            }.tabItem { Label("微信", systemImage: "message.fill") }.tag(0)
            NavigationStack {
                List { NavigationLink("小屁孩") { ChatView() } }.navigationTitle("通讯录")
            }.tabItem { Label("通讯录", systemImage: "person.2") }.tag(1)
            NavigationStack {
                List { Text("朋友圈媒体迁移尚未完成").foregroundStyle(.secondary) }.navigationTitle("发现")
            }.tabItem { Label("发现", systemImage: "safari") }.tag(2)
            NavigationStack { SettingsView() }.tabItem { Label("我", systemImage: "person") }.tag(3)
        }.tint(Color(red: 0.03, green: 0.65, blue: 0.31))
        .onAppear { store.activate() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.activate() } }
    }
}

struct AvatarView: View {
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "avatar", withExtension: "jpg"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "person.crop.square.fill").resizable() }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var speech = DeviceSpeech()
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var voiceMode = false
    @State private var held = false
    @State private var cancelled = false
    @State private var recognizing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(store.archive.messages) { message in
                            HStack(alignment: .top, spacing: 8) {
                                if message.role == "me" { Spacer(minLength: 45) }
                                if message.role == "her" { AvatarView() }
                                VStack(alignment: .leading, spacing: 4) {
                                    if message.kind == "voice" { Label("语音识别内容", systemImage: "waveform").font(.caption).foregroundStyle(.secondary) }
                                    Text(message.content).textSelection(.enabled)
                                }
                                .padding(12)
                                .background(message.role == "me" ? Color(red: 0.58, green: 0.92, blue: 0.42) : Color(uiColor: .secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                if message.role == "me" { Image(systemName: "person.crop.square.fill").font(.title) }
                                if message.role == "her" { Spacer(minLength: 45) }
                            }.id(message.id)
                        }
                    }.padding()
                }.onChange(of: store.archive.messages.count) { _, _ in
                    if let id = store.archive.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            Text(error ?? speech.error ?? store.storageError ?? store.status)
                .font(.caption).foregroundStyle(.secondary).padding(8)
            if held {
                Text("\(Int(speech.elapsed)) 秒 · \(cancelled ? "松开取消" : "上滑取消，松开发送")")
                    .font(.subheadline).padding()
                ProgressView(value: Double(speech.level)).padding(.horizontal)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { voiceMode.toggle() } label: { Image(systemName: voiceMode ? "keyboard" : "mic").font(.title2) }
                    .disabled(held || recognizing)
                if voiceMode {
                    Text(recognizing ? "正在本机识别…" : speech.preparing ? "等待麦克风…" : held ? "松开发送" : "按住说话")
                        .frame(maxWidth: .infinity).padding(12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard !recognizing else { return }
                            cancelled = value.translation.height < -70
                            if !held {
                                held = true
                                error = nil
                                Task {
                                    guard held else { return }
                                    await speech.begin()
                                }
                            }
                        }.onEnded { _ in finishRecording() })
                } else {
                    TextField("消息", text: $text, axis: .vertical).lineLimit(1...5)
                        .padding(10).background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Button("发送") { store.send(text); text = "" }
                        .buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("小屁孩").navigationBarTitleDisplayMode(.inline)
        .toolbar { NavigationLink { MemoryView() } label: { Image(systemName: "ellipsis") } }
        .onDisappear { _ = speech.end(cancel: true); held = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { _ = speech.end(cancel: true); held = false }
        }
    }

    private func finishRecording() {
        guard held else { return }
        held = false
        guard let url = speech.end(cancel: cancelled) else { return }
        recognizing = true
        Task {
            defer { recognizing = false; try? FileManager.default.removeItem(at: url) }
            do {
                let transcript = try await speech.transcribe(url)
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    error = "没有识别到文字，请重试"
                    return
                }
                store.send(transcript, kind: "voice")
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MemoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var content = ""
    @State private var category = "事实"
    @State private var importance = 3
    @State private var editingID: UUID?
    let categories = ["事实", "关系", "习惯", "计划", "事件", "设定"]
    var body: some View {
        List {
            Section(editingID == nil ? "补充记忆" : "修改记忆") {
                Picker("分类", selection: $category) { ForEach(categories, id: \.self) { Text($0) } }
                TextField("记忆内容", text: $content, axis: .vertical)
                Stepper("重要程度：\(importance)", value: $importance, in: 1...5)
                Button(editingID == nil ? "保存" : "保存修改") {
                    if let id = editingID, let index = store.archive.memories.firstIndex(where: { $0.id == id }) {
                        store.archive.memories[index].content = content
                        store.archive.memories[index].category = category
                        store.archive.memories[index].importance = importance
                        store.archive.memories[index].updatedAt = Date()
                        store.save()
                    } else { store.addMemory(category: category, content: content, importance: importance) }
                    content = ""; editingID = nil
                }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(categories, id: \.self) { group in
                Section(group) {
                    ForEach(store.archive.memories.filter { $0.category == group }.sorted { $0.importance > $1.importance }) { memory in
                        Button {
                            editingID = memory.id; content = memory.content
                            category = memory.category; importance = memory.importance
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(memory.content).foregroundStyle(.primary)
                                Text("重要程度 \(memory.importance) · \(memory.source)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.navigationTitle("记忆管理")
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var showModelImporter = false
    var body: some View {
        Form {
            Section("用户") { Text("个人资料在手机本地配置") }
            Section("本机数据") {
                NavigationLink("记忆管理") { MemoryView() }
                Button("导出聊天与记忆") {
                    do { exportURL = try store.exportArchive() } catch { self.error = error.localizedDescription }
                }
                if let url = exportURL { ShareLink("分享备份文件", item: url) }
            }
            Section("通知") {
                Button("允许主动消息通知") { Task { await store.enableNotifications() } }
                if store.archive.settings.notifications {
                    Button("暂停主动消息") { store.pauseNotifications() }
                    Text("待发送：\(store.archive.scheduledMessages.count)条")
                }
                Text("离线通知需要提前生成并安排；关闭 App 后不会持续运行模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("模型状态") {
                Text("本地模型待真机评估与接入")
                if let model = store.archive.model {
                    Text(model.displayName)
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                } else {
                    Button(store.importingModel ? "正在导入…" : "从文件导入GGUF模型") { showModelImporter = true }
                        .disabled(store.importingModel)
                }
                Text("初期建议1～2GB模型。单文件上限3GB，应用数据预算7GB，导入后至少保留3GB系统空间。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("此原生基础版本不调用原 WorkBuddy 服务，也不上传聊天和录音。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("当前状态") {
                Text(store.storageError ?? store.status).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("我")
        .fileImporter(isPresented: $showModelImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): Task { await store.importModel(from: url) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
