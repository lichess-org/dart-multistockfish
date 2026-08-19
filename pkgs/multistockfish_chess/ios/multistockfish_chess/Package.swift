// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Mirrors the CocoaPods podspec's `pod_target_xcconfig`, which applies the same
// flags to OTHER_CPLUSPLUSFLAGS and OTHER_LDFLAGS.
let baseFlags = [
    "-mdynamic-no-pic",
    "-DNNUE_EMBEDDING_OFF",
    "-DUSE_PTHREADS",
    "-DIS_64BIT",
    "-DUSE_POPCNT",
]
// Additional flags the podspec applies only to the Profile and Release
// xcconfigs (SPM only distinguishes debug/release; Xcode treats a
// Flutter "Profile" configuration as non-debug, so `.release` covers both).
let releaseFlags = [
    "-fno-exceptions",
    "-DNDEBUG",
    "-funroll-loops",
    "-O3",
    "-DUSE_NEON=8",
    "-flto=full",
]

let package = Package(
    name: "multistockfish_chess",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "multistockfish-chess", type: .dynamic, targets: ["multistockfish_chess"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "multistockfish_chess",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            exclude: [
                "Stockfish/src/Makefile",
                "Stockfish/src/main.cpp",
                "Stockfish/src/incbin/UNLICENCE",
                "Stockfish/AUTHORS",
                "Stockfish/CITATION.cff",
                "Stockfish/CONTRIBUTING.md",
                "Stockfish/Copying.txt",
                "Stockfish/README.md",
                "Stockfish/Top CPU Contributors.txt",
                "Stockfish/scripts",
                "Stockfish/tests",
                "Stockfish/.clang-format",
                "Stockfish/.git-blame-ignore-revs",
                "Stockfish/.gitignore",
            ],
            cSettings: [
                .headerSearchPath("include/multistockfish_chess"),
                .headerSearchPath("Stockfish/src"),
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ],
            cxxSettings: [
                .headerSearchPath("include/multistockfish_chess"),
                .headerSearchPath("Stockfish/src"),
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ],
            linkerSettings: [
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)

// Notes on settings intentionally NOT ported from the podspec's
// pod_target_xcconfig, since Package.swift has no equivalent knob:
// - DEFINES_MODULE = YES: SPM targets are always modules; no-op here.
// - EXCLUDED_ARCHS[sdk=iphonesimulator*] = i386: i386 simulator slices
//   aren't produced by modern Xcode toolchains for an iOS 13+ minimum
//   deployment target, so this exclusion is a no-op on current Xcode too.
