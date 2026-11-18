import FFmpegKit
import Foundation

/// The pinned native converter owns previous-RPU references for one reader.
final class DolbyVisionRPUConverter {
    enum Failure: Error { case allocation, conversion(Int32), invalidOutput }
    private var native: OpaquePointer?

    init() throws {
        native = tv_dolby_converter_create()
        guard native != nil else { throw Failure.allocation }
    }

    func convert(_ input: Data) throws -> Data {
        var output: UnsafeMutablePointer<UInt8>?
        var size = 0
        let status = input.withUnsafeBytes { bytes in
            tv_dolby_convert_p7_to_p81(native, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &output, &size)
        }
        defer { av_free(output) }
        guard status >= 0 else { throw Failure.conversion(status) }
        guard let output, size > 3 else { throw Failure.invalidOutput }
        return Data(bytes: output, count: size)
    }

    func flush() { tv_dolby_converter_flush(native) }
    deinit { tv_dolby_converter_free(&native) }
}
