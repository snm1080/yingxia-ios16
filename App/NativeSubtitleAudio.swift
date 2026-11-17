import Foundation
import TVCore
import TVMedia

/// Samples the active KS address with its own FFmpeg reader. AVAsset cannot read every format KS can play.
enum NativeSubtitleAudio {
    struct Sample: Sendable { let wav: Data; let position: Double; let duration: Double }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
    static func sample(url: URL, headers: [String: String], stream: Int32, position: Double, duration: Double) async throws -> Sample {
        let request = Request()
        let address = url.isFileURL ? url.path : url.absoluteString
        let lines = headers.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
            guard !key.isEmpty, !key.contains(":"), !key.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !value.contains("\r"), !value.contains("\n") else { return nil }
            return "\(key): \(value)\r\n"
        }.joined()
        let task = Task.detached(priority: .utility) {
            var sample = TVMAudioSample()
            defer { tvm_audio_free(&sample) }
            let status = address.withCString { address in lines.withCString { headers in
                tvm_audio_sample(address, headers, stream, position, duration,
                    Unmanaged.passUnretained(request).toOpaque(), { context in
                        guard let context else { return 1 }
                        return Unmanaged<Request>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
                    }, &sample)
            } }
            if request.isCancelled { throw CancellationError() }
            guard status == 0, let bytes = sample.bytes, sample.size > 0 else {
                throw TVError.unsupported(failureMessage(status))
            }
            return Sample(wav: wav(Data(bytes: bytes, count: Int(sample.size))), position: max(0, sample.position), duration: sample.duration)
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }, onCancel: { request.cancel(); task.cancel() })
    }
    private static func failureMessage(_ status: Int32) -> String {
        let reason: String
        switch status {
        case -28, -7:
            reason = "音频采集达到读取或资源上限，请切换线路后重试"
        case -1414092869, -60, -110:
            // User cancellation is handled before this formatter. AVERROR_EXIT
            // with an active request comes from the bounded FFmpeg deadline.
            reason = "音频采集超时，请稍后重试或切换线路"
        case -825242872, -858797304, -13:
            reason = "音频来源认证失败或拒绝访问，请刷新播放地址或重新登录来源"
        case -875574520, -2:
            reason = "音频地址已失效或文件不存在，请刷新播放地址"
        case -1094995529:
            reason = "当前片段没有有效音频或可定位时标，请切换音轨或线路"
        case -1381258232:
            reason = "当前所选音轨在音频输入中不存在，请重新选择音轨"
        case -1128613112:
            reason = "当前音轨格式无法解码，请选择其他音轨或线路"
        case -22:
            reason = "音频采集参数无效或当前输入不支持此采样，请重试或切换线路"
        case -5, -54, -104, -808465656, -1482175736, -1482175992:
            reason = "音频读取中断或来源返回错误，请稍后重试或切换线路"
        default:
            reason = "当前音频采集失败，请重试或切换音轨或线路"
        }
        return "\(reason)（错误 \(status)）"
    }
    private static func wav(_ pcm: Data) -> Data {
        var result = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        number(UInt32(36 + pcm.count)); result.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16000)); number(UInt32(32000)); number(UInt16(2)); number(UInt16(16))
        result.append(Data("data".utf8)); number(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
