// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Mirrors the CocoaPods podspec's `pod_target_xcconfig`, which applies the same
// flags to OTHER_CPLUSPLUSFLAGS and OTHER_LDFLAGS.
let baseFlags = [
    "-DUSE_PTHREADS",
    "-DIS_64BIT",
    "-DUSE_POPCNT",
]
// Additional flags the podspec applies only to the Profile and Release
// xcconfigs (SPM only distinguishes debug/release; Xcode treats a
// Flutter "Profile" configuration as non-debug, so `.release` covers both).
//
// NOTE: unlike multistockfish_chess, this deliberately omits `-flto=full`.
// This package embeds its default NNUE net via `INCBIN(EmbeddedNNUE, ...)` in
// nnue/network.cpp - inline assembly using a `.incbin` directive. Compiling
// that file with any LTO mode (`-flto`, `-flto=thin`, `-flto=full`) makes
// Xcode's build fail with "Could not find incbin file", regardless of search
// path - LTO's bitcode compilation path doesn't run the same
// integrated-assembler step `.incbin` needs. This is the same constraint the
// retired multistockfish_sf16 package carried.
let releaseFlags = [
    "-fno-exceptions",
    "-DNDEBUG",
    "-funroll-loops",
    "-O3",
    "-DUSE_NEON=8",
]

let package = Package(
    name: "multistockfish_light",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "multistockfish-light", targets: ["multistockfish_light"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "multistockfish_light",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            exclude: [
                "StockfishLight/src/Makefile",
                "StockfishLight/src/main.cpp",
                "StockfishLight/src/incbin/UNLICENCE",
                // Upstream's macOS universal-binary build only. The entry_* files
                // call into per-arch `StockfishLight_<arch>::main` namespaces that
                // a normal build does not have, and nnue_embed.cpp defines a
                // second `gEmbeddedNNUEData`.
                "StockfishLight/src/universal",
                "StockfishLight/AUTHORS",
                "StockfishLight/CITATION.cff",
                "StockfishLight/CONTRIBUTING.md",
                "StockfishLight/Copying.txt",
                "StockfishLight/README.md",
                "StockfishLight/Top CPU Contributors.txt",
                "StockfishLight/scripts",
                "StockfishLight/tests",
                // Dot-files (.gitignore, .clang-format, .git-blame-ignore-revs) are deliberately
                // NOT listed here: SwiftPM already skips hidden files when collecting target
                // contents, and `dart pub publish` strips them from the published archive - so
                // excluding them only makes Xcode warn "Invalid Exclude ...: File not found" for
                // every consumer that resolves this package from pub.dev.
                //
                // Not a compilable source; embedded via `.incbin` (see note below).
                "nnue/nn-61e7af4bb97d.nnue",
            ],
            cSettings: [
                .headerSearchPath("include/multistockfish_light"),
                .headerSearchPath("StockfishLight/src"),
                .headerSearchPath("nnue"),
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ],
            cxxSettings: [
                .headerSearchPath("include/multistockfish_light"),
                .headerSearchPath("StockfishLight/src"),
                .headerSearchPath("nnue"),
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
//
// nn-61e7af4bb97d.nnue (the embedded default net, ~1.1MB) is committed under
// Sources/multistockfish_light/nnue/. `nnue/network.cpp`'s
// `INCBIN(EmbeddedNNUE, ...)` expands to a `.incbin "nn-....nnue"` inline
// assembly directive, which - like a normal #include - can be resolved via
// clang's `-I` search paths, not just relative to the compiler's working
// directory at build time. Relying on the working directory turned out to be
// unreliable: it differs between `swift build` (package root), a CocoaPods pod
// target (that target's SRCROOT, e.g. the consuming app's Pods/ root), and
// Xcode building this package as a nested local dependency (the *consuming
// app's* own ios/ directory, which this package obviously can't control or
// ship a file into). The `nnue` headerSearchPath above sidesteps all of that:
// SPM always resolves headerSearchPath relative to this target's own
// directory, regardless of which build system invoked it or from where.
