import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import PhotosUI

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
                            AvatarView(profile: store.archive.character, size: 48)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.archive.character.name).font(.headline)
                                Text(store.archive.messages.last.map { $0.kind == "voice" ? "[语音]" : $0.content } ?? "")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 6)
                    }
                }.navigationTitle("微信")
                .navigationDestination(isPresented: $store.showChat) { ChatView() }
            }.tabItem { Label("微信", systemImage: "message.fill") }.tag(0)
            NavigationStack {
                List { NavigationLink { ProfileView(isOwner: false) } label: { HStack { AvatarView(profile: store.archive.character); Text(store.archive.character.name) } } }.navigationTitle("通讯录")
            }.tabItem { Label("通讯录", systemImage: "person.2") }.tag(1)
            NavigationStack {
                List { NavigationLink { MomentsView() } label: { Label("朋友圈", systemImage: "circle.hexagongrid.fill") } }.navigationTitle("发现")
            }.tabItem { Label("发现", systemImage: "safari") }.tag(2)
            NavigationStack { MeView() }.tabItem { Label("我", systemImage: "person") }.tag(3)
        }.tint(Color(red: 0.03, green: 0.65, blue: 0.31))
        .onAppear { store.activate() }
        .onOpenURL { store.pairController($0) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.activate() } }
    }
}

struct AvatarView: View {
    var profile: UserProfile? = nil
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let data = profile?.avatar, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = Bundle.main.url(forResource: "avatar", withExtension: "jpg"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "person.crop.square.fill").resizable() }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var speech = DeviceSpeech()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var voiceMode = false
    @State private var held = false
    @State private var cancelled = false
    @State private var recognizing = false
    @State private var error: String?
    @State private var showEmoji = false
    @State private var wallpaper: UIImage?

    private let green = Color(red: 0.08, green: 0.73, blue: 0.34)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 24, weight: .regular))
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("返回")
                Spacer()
                Text(store.archive.character.name).font(.system(size: 18, weight: .medium))
                Spacer()
                NavigationLink { ChatDetailsView() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 24, weight: .semibold))
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("聊天信息")
            }.foregroundStyle(Color(white: 0.88)).padding(.horizontal, 6)
                .padding(.bottom, 5).background(Color(white: 0.10))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(Array(store.archive.messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || message.createdAt.timeIntervalSince(store.archive.messages[index - 1].createdAt) > 300 {
                                Text(message.createdAt.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.system(size: 12)).foregroundStyle(Color(white: 0.73))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                                    .padding(.vertical, 6)
                            }
                            HStack(alignment: .top, spacing: 10) {
                                if message.role == "me" { Spacer(minLength: 38) }
                                if message.role == "her" {
                                    NavigationLink { ProfileView(isOwner: false) } label: { AvatarView(profile: store.archive.character, size: 40) }
                                }
                                Group {
                                    if message.kind == "voice" {
                                        VoiceBubble(message: message, speech: speech)
                                    } else {
                                        Text(message.content).font(.system(size: 17)).lineSpacing(3)
                                            .textSelection(.enabled).padding(.horizontal, 12).padding(.vertical, 10)
                                    }
                                }
                                .foregroundStyle(message.role == "me" ? Color.black : Color(white: 0.90))
                                .background(message.role == "me" ? green : Color(white: 0.17), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(alignment: message.role == "me" ? .topTrailing : .topLeading) {
                                    BubbleTail(pointsRight: message.role == "me")
                                        .fill(message.role == "me" ? green : Color(white: 0.17))
                                        .frame(width: 6, height: 12)
                                        .offset(x: message.role == "me" ? 5 : -5, y: 14)
                                }
                                if message.role == "me" { AvatarView(profile: store.archive.owner, size: 40) }
                                if message.role == "her" { Spacer(minLength: 38) }
                            }.id(message.id)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 16)
                }.scrollDismissesKeyboard(.interactively)
                .onAppear {
                    if let id = store.archive.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }.onChange(of: store.archive.messages.count) { _, _ in
                    if let id = store.archive.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            .background {
                GeometryReader { geometry in
                    if let wallpaper {
                        Image(uiImage: wallpaper).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            .overlay(Color.black.opacity(0.45))
                    } else { Color(white: 0.08) }
                }
            }
            if let issue = error ?? speech.error ?? store.storageError {
                Text(issue).font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if held {
                Text("\(Int(speech.elapsed)) 秒 · \(cancelled ? "松开取消" : "上滑取消，松开发送")")
                    .font(.subheadline).padding()
                ProgressView(value: Double(speech.level)).padding(.horizontal)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { voiceMode.toggle(); showEmoji = false } label: {
                    Image(systemName: voiceMode ? "keyboard" : "waveform.circle")
                        .font(.system(size: 28, weight: .light)).frame(width: 30, height: 42)
                }.accessibilityLabel(voiceMode ? "切换键盘" : "切换语音")
                    .disabled(held || recognizing)
                if voiceMode {
                    Text(speech.preparing ? "等待麦克风…" : held ? "松开发送" : "按住说话")
                        .frame(maxWidth: .infinity).padding(12)
                        .background(Color(white: 0.17))
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
                        .font(.system(size: 17)).padding(10).background(Color(white: 0.17))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Button { showEmoji.toggle(); voiceMode = false } label: {
                    Image(systemName: showEmoji ? "keyboard" : "face.smiling")
                        .font(.system(size: 28, weight: .light)).frame(width: 30, height: 42)
                }.accessibilityLabel("表情")
                if !voiceMode && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("发送") { store.send(text); text = "" }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 36).background(green, in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Menu {
                        NavigationLink("聊天背景") { ChatWallpaperView() }
                        NavigationLink("对方资料") { ProfileView(isOwner: false) }
                        NavigationLink("查找聊天内容") { ChatSearchView() }
                    } label: {
                        Image(systemName: "plus.circle").font(.system(size: 28, weight: .light))
                            .frame(width: 30, height: 42)
                    }.accessibilityLabel("更多功能")
                }
            }.foregroundStyle(Color(white: 0.80)).padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(white: 0.12))
            if showEmoji {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 18) {
                    ForEach(["😀", "😂", "🥹", "🥰", "😘", "😏", "😭", "🥺", "😤", "🙄", "😴", "🤔", "🤭", "😳", "❤️", "💔", "👍", "🫂", "🐶", "🌹", "✨"], id: \.self) { emoji in
                        Button { text += emoji } label: { Text(emoji).font(.system(size: 28)).frame(height: 34) }
                    }
                }.padding(16).background(Color(white: 0.15))
            }
        }
        .background(Color(white: 0.10)).preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { wallpaper = ChatWallpaper.load() }
        .onDisappear { _ = speech.end(cancel: true); held = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { _ = speech.end(cancel: true); held = false }
        }
    }

    private func finishRecording() {
        guard held else { return }
        held = false
        guard let url = speech.end(cancel: cancelled) else { return }
        let seconds = speech.elapsed
        let id: UUID
        do { id = try store.sendVoiceFile(url, seconds: seconds) }
        catch { self.error = "语音未保存，请重试"; try? FileManager.default.removeItem(at: url); return }
        recognizing = true
        Task {
            defer { recognizing = false; try? FileManager.default.removeItem(at: url) }
            do {
                let transcript = try await speech.transcribe(url)
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    store.updateTranscript(id: id, text: nil, failure: "未识别到文字")
                    return
                }
                store.updateTranscript(id: id, text: transcript)
            } catch { store.updateTranscript(id: id, text: nil, failure: error.localizedDescription) }
        }
    }
}

struct BubbleTail: Shape {
    var pointsRight: Bool
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: pointsRight ? 0 : rect.width, y: 0))
            path.addLine(to: CGPoint(x: pointsRight ? rect.width : 0, y: rect.midY))
            path.addLine(to: CGPoint(x: pointsRight ? 0 : rect.width, y: rect.height))
            path.closeSubpath()
        }
    }
}

enum ChatWallpaper {
    static func url() throws -> URL {
        try LocalFiles.archiveURL().deletingLastPathComponent().appendingPathComponent("chat-wallpaper.jpg")
    }
    static func load() -> UIImage? {
        guard let url = try? url() else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

struct ChatWallpaperView: View {
    @State private var photo: PhotosPickerItem?
    @State private var image = ChatWallpaper.load()
    @State private var issue: String?
    var body: some View {
        List {
            Section {
                PhotosPicker("从相册选择聊天背景", selection: $photo, matching: .images)
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 350) }
                Button("使用纯色背景") {
                    do {
                        let url = try ChatWallpaper.url()
                        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                        image = nil
                    } catch { issue = "背景保存失败，请重试" }
                }
            } footer: { Text("背景仅保存在这台手机，不会上传电脑或公共仓库。") }
            if let issue { Text(issue).foregroundStyle(.red) }
        }.navigationTitle("聊天背景").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: photo) { _, item in
            Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), let original = UIImage(data: data) else { return }
                    let scale = min(1, 1600 / max(original.size.width, original.size.height))
                    let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
                    let resized = UIGraphicsImageRenderer(size: size).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
                    guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return }
                    try jpeg.write(to: ChatWallpaper.url(), options: [.atomic, .completeFileProtectionUnlessOpen])
                    image = resized
                } catch { issue = "背景读取失败，请重试" }
            }
        }
    }
}

struct VoiceBubble: View {
    var message: ChatMessage
    @ObservedObject var speech: DeviceSpeech
    @State private var showText = false
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                do {
                    guard let filename = message.audioFilename else { showText.toggle(); return }
                    try speech.play(url: VoiceFiles.url(for: filename))
                } catch { problem = "这条语音暂时无法播放" }
            } label: {
                HStack {
                    Image(systemName: "waveform")
                    Spacer(minLength: 12)
                    Text("\(max(1, Int((message.audioDuration ?? 1).rounded())))″")
                }.foregroundStyle(.primary).frame(width: 110).padding(12)
            }
            .contextMenu {
                Button("转文字") { showText.toggle() }
            }
            if showText {
                Text(message.content.isEmpty ? "暂未识别出文字" : message.content).font(.subheadline).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let problem { Text(problem).font(.caption).padding(8) }
        }
    }
}

struct MeView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        List {
            Section {
                NavigationLink { ProfileView(isOwner: true) } label: {
                    HStack(spacing: 16) {
                        AvatarView(profile: store.archive.owner, size: 64)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.archive.owner.name).font(.title3.bold())
                            Text("微信号：" + (store.archive.owner.account.isEmpty ? "未设置" : store.archive.owner.account))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 15)
                }
            }
            Section { NavigationLink { MomentsView() } label: { Label("朋友圈", systemImage: "photo.on.rectangle") } }
            Section { NavigationLink { PersonalSettingsView() } label: { Label("设置", systemImage: "gearshape") } }
        }.navigationTitle("我").navigationBarTitleDisplayMode(.inline)
    }
}

struct ProfileView: View {
    @EnvironmentObject var store: AppStore
    let isOwner: Bool
    var profile: UserProfile { isOwner ? store.archive.owner : store.archive.character }
    var body: some View {
        List {
            Section {
                HStack(spacing: 18) {
                    AvatarView(profile: profile, size: 72)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.name).font(.title2.bold())
                        Text("微信号：" + (profile.account.isEmpty ? "未设置" : profile.account)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 12)
            }
            Section {
                LabeledContent("地区", value: profile.region.isEmpty ? "未设置" : profile.region)
                LabeledContent("个性签名", value: profile.signature.isEmpty ? "未设置" : profile.signature)
            }
            Section { NavigationLink("朋友圈") { MomentsView() } }
            if isOwner {
                Section { NavigationLink("编辑资料") { EditProfileView() } }
            } else {
                Section { NavigationLink("发消息") { ChatView() } }
            }
        }.navigationTitle("个人资料").navigationBarTitleDisplayMode(.inline)
    }
}

struct EditProfileView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = UserProfile(name: "用户")
    @State private var photo: PhotosPickerItem?
    @State private var issue: String?
    var body: some View {
        Form {
            PhotosPicker(selection: $photo, matching: .images) {
                HStack { Text("头像"); Spacer(); AvatarView(profile: draft, size: 56) }
            }
            TextField("名字", text: $draft.name)
            TextField("微信号", text: $draft.account)
            TextField("地区", text: $draft.region)
            TextField("个性签名", text: $draft.signature, axis: .vertical)
            if let issue { Text(issue).foregroundStyle(.red) }
        }.navigationTitle("编辑资料")
        .onAppear { draft = store.archive.owner }
        .toolbar {
            Button("保存") { store.updateOwner(draft); dismiss() }
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name.count > 60)
        }
        .onChange(of: photo) { _, item in
            Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
                    let ratio = max(512 / image.size.width, 512 / image.size.height)
                    let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                    let resized = renderer.image { _ in
                        image.draw(in: CGRect(x: (512 - size.width) / 2, y: (512 - size.height) / 2, width: size.width, height: size.height))
                    }
                    draft.avatar = resized.jpegData(compressionQuality: 0.8)
                } catch { issue = "头像读取失败，请重试" }
            }
        }
    }
}

struct ChatDetailsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        List {
            NavigationLink { ProfileView(isOwner: false) } label: {
                VStack(spacing: 8) { AvatarView(profile: store.archive.character, size: 56); Text(store.archive.character.name) }
                    .padding()
            }
            NavigationLink("查找聊天内容") { ChatSearchView() }
            NavigationLink("设置聊天背景") { ChatWallpaperView() }
        }.navigationTitle("聊天信息").navigationBarTitleDisplayMode(.inline)
    }
}

struct ChatSearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    var body: some View {
        List {
            ForEach(store.archive.messages.filter { !query.isEmpty && $0.content.localizedCaseInsensitiveContains(query) }) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.role == "me" ? store.archive.owner.name : store.archive.character.name).font(.caption).foregroundStyle(.secondary)
                    Text(message.content)
                    Text(message.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.searchable(text: $query, prompt: "搜索聊天记录").navigationTitle("查找聊天内容")
    }
}

struct MomentsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 14) {
                Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 180)
                    .overlay(alignment: .bottomTrailing) {
                        HStack { Text(store.archive.owner.name).bold(); AvatarView(profile: store.archive.owner, size: 64) }.padding()
                    }
                Text(store.archive.owner.signature).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
            }
        }.navigationTitle("朋友圈").navigationBarTitleDisplayMode(.inline)
    }
}

struct PersonalSettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var exportURL: URL?
    @State private var issue: String?
    @State private var showModelImporter = false
    var body: some View {
        List {
            NavigationLink("个人资料") { ProfileView(isOwner: true) }
            Button("新消息通知") { Task { await store.enableNotifications() } }
            Button("聊天记录备份") {
                do { exportURL = try store.exportArchive() } catch { issue = "备份失败，请重试" }
            }
            Button("导入离线模型（GGUF）") { showModelImporter = true }
                .fileImporter(isPresented: $showModelImporter, allowedContentTypes: [.data]) { result in
                    guard case .success(let url) = result else { return }
                    Task { await store.importModel(from: url) }
                }
            if let url = exportURL { ShareLink("导出备份", item: url) }
            if let issue { Text(issue).foregroundStyle(.red) }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }
}
