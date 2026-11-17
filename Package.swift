// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TVCore",
    defaultLocalization: "en",
    platforms: [.iOS("16.2")],
    products: [.library(name: "KSPlayer", targets: ["KSPlayer"]), .library(name: "TVCore", targets: ["TVCore"])],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-perception", exact: "2.0.10"),
        // Keep macro tooling compatible with the Swift 6.0 compiler in Xcode 16.1.
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "600.0.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.6.0")
    ],
    targets: [.target(name: "TVCore", dependencies: ["QuickJS", "TVMedia", "TVDisc", .product(name: "Perception", package: "swift-perception")], resources: [.process("Resources"), .copy("ScriptAssets")]),
        .target(name: "QuickJS", path: "Vendor/QuickJS", exclude: ["LICENSE", "UPSTREAM.md"], sources: ["quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c", "TVScript.c"], publicHeadersPath: "include", cSettings: [.define("_GNU_SOURCE"), .define("QUICKJS_NG_BUILD"), .define("NDEBUG"), .unsafeFlags(["-w"], .when(configuration: .release))]),
        // Scripts/build-apple-ffmpeg.sh makes the library Vendor/FFmpeg links to.
        .binaryTarget(name: "DiscNative", path: "Vendor/DiscNative/DiscNative.xcframework"),
        .target(name: "TVDisc", dependencies: ["DiscNative"], publicHeadersPath: "include", linkerSettings: [.linkedLibrary("iconv"), .linkedFramework("CoreFoundation")]),
        .binaryTarget(name: "FFmpeg", path: "Vendor/FFmpeg/FFmpeg.xcframework"),
        // One FFmpeg build serves KSPlayer and the legacy media utilities; never link another ABI.
        .target(name: "FFmpegKit", dependencies: ["FFmpeg"], path: "Vendor/FFmpegKit", exclude: ["UPSTREAM.md"], publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("xml2"), .linkedLibrary("iconv"), .linkedFramework("Security"), .linkedFramework("AudioToolbox"), .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"), .linkedFramework("CoreFoundation")]),
        // Suppress vendored diagnostics only. TVCore, TVMedia and App keep warnings.
        .target(name: "DisplayCriteria", path: "Vendor/KSPlayer/Sources/DisplayCriteria", cSettings: [.unsafeFlags(["-w"], .when(configuration: .release))]),
        .target(name: "KSPlayer", dependencies: ["FFmpegKit", "DisplayCriteria"], path: "Vendor/KSPlayer/Sources/KSPlayer", resources: [.process("Metal/Shaders.metal")], swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-suppress-warnings"], .when(configuration: .release))]),
        .target(name: "TVMedia", dependencies: ["FFmpeg"], publicHeadersPath: "include", cSettings: [.define("NDEBUG")], linkerSettings: [.linkedLibrary("z"), .linkedFramework("AudioToolbox"), .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"), .linkedFramework("CoreFoundation")]) ]
)
