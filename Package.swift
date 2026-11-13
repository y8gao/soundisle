// swift-tools-version:5.8
import Foundation
import PackageDescription

// TagLib is built into Vendor/taglib by Scripts/build-taglib.sh (git-ignored).
// The linker needs an absolute -L path, so derive it from this manifest's location.
let taglibRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/taglib")
    .path

let package = Package(
    name: "SoundIsle",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SoundIsleCore", targets: ["SoundIsleCore"]),
        .executable(name: "SoundIsle", targets: ["SoundIsle"]),
    ],
    targets: [
        .target(
            name: "CTagLib",
            path: "Sources/CTagLib",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Vendor/taglib/include")
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(taglibRoot)/lib", "-ltag", "-lz", "-lc++"])
            ]
        ),
        .target(name: "SoundIsleCore", dependencies: ["CTagLib"]),
        .executableTarget(name: "SoundIsle", dependencies: ["SoundIsleCore"]),
        .testTarget(name: "SoundIsleCoreTests", dependencies: ["SoundIsleCore"]),
        .testTarget(name: "SoundIsleAppTests", dependencies: ["SoundIsle", "SoundIsleCore"]),
    ],
    cxxLanguageStandard: .cxx17
)
