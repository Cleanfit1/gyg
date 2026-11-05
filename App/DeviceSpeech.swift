import Foundation
import AVFoundation
import Speech

@MainActor
final class DeviceSpeech: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    @Published var error: String?
    @Published var preparing = false
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var gesture: UUID?
    private var currentURL: URL?

    func begin() async {
        guard gesture == nil else { return }
        let token = UUID()
        gesture = token
        preparing = true
        let allowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        // 用户在权限弹窗期间松手时，不能遗留后台录音。
        guard gesture == token else { preparing = false; return }
        guard allowed else { error = "请在系统设置中允许麦克风"; gesture = nil; preparing = false; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: 60) else { throw NSError(domain: "录音启动失败", code: 1) }
            self.recorder = recorder
            currentURL = url
            recording = true
            preparing = false
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime
                    recorder.updateMeters()
                    self.level = pow(10, recorder.averagePower(forChannel: 0) / 20)
                }
            }
        } catch {
            self.error = "录音失败：\(error.localizedDescription)"
            preparing = false
            gesture = nil
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    func end(cancel: Bool) -> URL? {
        gesture = nil
        preparing = false
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        guard let url = currentURL else { return nil }
        currentURL = nil
        if cancel || elapsed < 0.8 {
            try? FileManager.default.removeItem(at: url)
            if !cancel { error = "说话时间太短" }
            return nil
        }
        return url
    }

    func transcribe(_ url: URL) async throws -> String {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw SpeechError.permission }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw SpeechError.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.contextualStrings = []
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    func play(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        player = try AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        guard player?.play() == true else { throw SpeechError.playback }
    }

    enum SpeechError: LocalizedError {
        case permission, unavailable, playback
        var errorDescription: String? {
            switch self {
            case .permission: return "语音识别未获允许"
            case .unavailable: return "此设备当前未提供可用的离线中文识别；不会自动上传录音"
            case .playback: return "无法播放音频"
            }
        }
    }
}
