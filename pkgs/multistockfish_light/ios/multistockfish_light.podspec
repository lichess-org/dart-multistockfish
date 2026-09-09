#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint multistockfish_light.podspec` to validate before publishing.
#
require 'yaml'

pubspec = YAML.load(File.read(File.join(__dir__, '../pubspec.yaml')))

Pod::Spec.new do |s|
  s.name             = 'multistockfish_light'
  s.version          = pubspec['version']
  s.summary          = pubspec['description']
  s.homepage         = pubspec['homepage']
  s.license          = { :file => '../LICENSE', :type => 'GPL' }
  s.author           = { 'lichess.org' => 'contact@lichess.org' }
  s.source = { :git => pubspec['repository'], :tag => s.version.to_s }
  s.source_files = [
    'multistockfish_light/Sources/multistockfish_light/*.{c,cc,cpp,h,hpp}',
    'multistockfish_light/Sources/multistockfish_light/include/**/*.h',
    'multistockfish_light/Sources/multistockfish_light/StockfishLight/src/**/*',
  ]
  s.public_header_files = 'multistockfish_light/Sources/multistockfish_light/include/**/*.h'
  s.exclude_files = [
    'multistockfish_light/Sources/multistockfish_light/StockfishLight/src/Makefile',
    'multistockfish_light/Sources/multistockfish_light/StockfishLight/src/main.cpp',
    'multistockfish_light/Sources/multistockfish_light/StockfishLight/src/incbin/UNLICENCE',
    # Upstream's macOS universal-binary build only. The entry_* files call into
    # per-arch `StockfishLight_<arch>::main` namespaces that a normal build does
    # not have, and nnue_embed.cpp defines a second `gEmbeddedNNUEData`.
    'multistockfish_light/Sources/multistockfish_light/StockfishLight/src/universal/**/*',
  ]
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.swift_version = '5.0'

  s.pod_target_xcconfig = {
     # Flutter.framework does not contain a i386 slice.
    'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'OTHER_CPLUSPLUSFLAGS' => '-std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT',
    'OTHER_LDFLAGS' => '-std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT',
    # NOTE: no -flto here (unlike multistockfish_chess/multistockfish_variant),
    # and no -mdynamic-no-pic. This package embeds its default NNUE net via
    # `INCBIN(EmbeddedNNUE, ...)` (nnue/network.cpp), an inline-assembly
    # `.incbin` directive. Compiling that file under Xcode with any LTO mode
    # (-flto/-flto=thin/-flto=full) fails with "Could not find incbin file",
    # on both simulator and device target triples - LTO's bitcode compilation
    # path doesn't run the integrated-assembler step `.incbin` needs. This is
    # the same constraint the retired multistockfish_sf16 package carried.
    'OTHER_CPLUSPLUSFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8',
    'OTHER_LDFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8',
    'OTHER_CPLUSPLUSFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8',
    'OTHER_LDFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8',
  }

  s.script_phase = [
    {
      :execution_position => :before_compile,
      :name => 'Download nnue',
      :script => "[ -e 'nn-61e7af4bb97d.nnue' ] || curl --location --remote-name 'https://tests.stockfishchess.org/api/nn/nn-61e7af4bb97d.nnue'"
    }
  ]
end
