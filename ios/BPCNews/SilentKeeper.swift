import Foundation
import AVFoundation

/// 后台保活（可选，默认关闭）：播放**静音音频**换取后台运行时间。
///
/// 说明：iOS 只允许「音频 / 定位 / VoIP」等特定类别的 App 在后台长期运行。
/// 这里利用 `audio` 后台模式播放 0 音量音频，使前台定时器在后台继续工作，
/// 从而做到分钟级自动抓取与本地通知。
/// 代价：耗电；系统设置里若被打断需重新进前台。
enum SilentKeeper {

    private static var player: AVAudioPlayer?

    static func start() {
        guard Settings.keepAlive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(data: silentWAV(), fileTypeHint: "wav")
                player?.numberOfLoops = -1
                player?.volume = 0
                player?.prepareToPlay()
            }
            player?.play()
        } catch {
            print("[keepalive] start failed: \(error.localizedDescription)")
        }
    }

    static func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                      options: [.notifyOthersOnDeactivation])
    }

    /// 生成 1 秒 8kHz 单声道 16bit 静音 WAV
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let seconds: UInt32 = 1
        let dataSize = sampleRate * UInt32(channels) * UInt32(bits / 8) * seconds

        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * UInt32(channels) * UInt32(bits / 8)); u16(channels * bits / 8); u16(bits)
        str("data"); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
