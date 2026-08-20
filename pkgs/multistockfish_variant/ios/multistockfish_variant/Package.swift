// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Mirrors the CocoaPods podspec's `pod_target_xcconfig`, which applies the same
// flags to OTHER_CPLUSPLUSFLAGS and OTHER_LDFLAGS.
let baseFlags = [
    "-fno-strict-aliasing",
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
    "-O3",
    "-DUSE_NEON",
    "-flto=full",
]

let package = Package(
    name: "multistockfish_variant",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "multistockfish-variant", targets: ["multistockfish_variant"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "multistockfish_variant",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            exclude: [
                "Fairy-Stockfish-2b5d9512/src/Makefile",
                "Fairy-Stockfish-2b5d9512/src/Makefile_js",
                "Fairy-Stockfish-2b5d9512/src/variants.ini",
                "Fairy-Stockfish-2b5d9512/src/incbin/UNLICENCE",
                "Fairy-Stockfish-2b5d9512/src/main.cpp",
                "Fairy-Stockfish-2b5d9512/src/pyffish.cpp",
                "Fairy-Stockfish-2b5d9512/src/ffishjs.cpp",
                "Fairy-Stockfish-2b5d9512/AUTHORS",
                "Fairy-Stockfish-2b5d9512/Copying.txt",
                "Fairy-Stockfish-2b5d9512/README.md",
                "Fairy-Stockfish-2b5d9512/Top CPU Contributors.txt",
                "Fairy-Stockfish-2b5d9512/MANIFEST.in",
                "Fairy-Stockfish-2b5d9512/test.py",
                "Fairy-Stockfish-2b5d9512/setup.py",
                "Fairy-Stockfish-2b5d9512/appveyor.yml",
                "Fairy-Stockfish-2b5d9512/tests",
                // Dot-files (.gitignore and friends) are deliberately NOT listed here: SwiftPM
                // already skips hidden files when collecting target contents, and `dart pub
                // publish` strips them from the published archive - so excluding them only makes
                // Xcode warn "Invalid Exclude ...: File not found" for every consumer that
                // resolves this package from pub.dev.
            ],
            cSettings: [
                .headerSearchPath("include/multistockfish_variant"),
                .headerSearchPath("Fairy-Stockfish-2b5d9512/src"),
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ],
            cxxSettings: [
                .headerSearchPath("include/multistockfish_variant"),
                .headerSearchPath("Fairy-Stockfish-2b5d9512/src"),
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
