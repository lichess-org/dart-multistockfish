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
// NOTE: unlike the other two packages, this deliberately omits the podspec's
// `-flto=full`. This package (uniquely) embeds its default NNUE net via
// `INCBIN(EmbeddedNNUE, ...)` in evaluate.cpp - inline assembly using a
// `.incbin` directive. Verified empirically (both simulator and device
// target triples, Xcode 26.3/clang 17): compiling that file with any LTO
// mode (`-flto`, `-flto=thin`, `-flto=full`) makes Xcode's build fail with
// "Could not find incbin file", regardless of search path - LTO's bitcode
// compilation path doesn't run the same integrated-assembler step
// `.incbin` needs. All other release flags below were individually and
// jointly verified to compile clean without LTO.
let releaseFlags = [
    "-fno-exceptions",
    "-DNDEBUG",
    "-O3",
    "-DUSE_NEON=8",
]

let package = Package(
    name: "multistockfish_sf16",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "multistockfish-sf16", targets: ["multistockfish_sf16"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "multistockfish_sf16",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            exclude: [
                "Stockfish16/src/Makefile",
                "Stockfish16/src/main.cpp",
                "Stockfish16/AUTHORS",
                "Stockfish16/CITATION.cff",
                "Stockfish16/Copying.txt",
                "Stockfish16/README.md",
                "Stockfish16/Top CPU Contributors.txt",
                "Stockfish16/tests",
                "Stockfish16/.gitignore",
                // Not a compilable source; embedded via `.incbin` (see note below).
                "nnue/nn-5af11540bbfe.nnue",
            ],
            cSettings: [
                .headerSearchPath("include/multistockfish_sf16"),
                .headerSearchPath("Stockfish16/src"),
                .headerSearchPath("nnue"),
                .unsafeFlags(baseFlags),
                .unsafeFlags(releaseFlags, .when(configuration: .release)),
            ],
            cxxSettings: [
                .headerSearchPath("include/multistockfish_sf16"),
                .headerSearchPath("Stockfish16/src"),
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
// nn-5af11540bbfe.nnue (the embedded default net) is committed under
// Sources/multistockfish_sf16/nnue/. `evaluate.cpp`'s
// `INCBIN(EmbeddedNNUE, ...)` expands to a `.incbin "nn-....nnue"` inline
// assembly directive, which - like a normal #include - can be resolved via
// clang's `-I` search paths (verified empirically), not just relative to the
// compiler's working directory at build time. Relying on the working
// directory turned out to be unreliable: it differs between `swift build`
// (package root), a CocoaPods pod target (that target's SRCROOT, e.g. the
// consuming app's Pods/ root), and Xcode building this package as a nested
// local dependency (the *consuming app's* own ios/ directory, which this
// package obviously can't control or ship a file into). The `nnue`
// headerSearchPath below sidesteps all of that: SPM always resolves
// headerSearchPath relative to this target's own directory, regardless of
// which build system invoked it or from where.
