#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint multistockfish_sf16.podspec` to validate before publishing.
#
require 'yaml'

pubspec = YAML.load(File.read(File.join(__dir__, '../pubspec.yaml')))

Pod::Spec.new do |s|
  s.name             = 'multistockfish_sf16'
  s.version          = pubspec['version']
  s.summary          = pubspec['description']
  s.homepage         = pubspec['homepage']
  s.license          = { :file => '../LICENSE', :type => 'GPL' }
  s.author           = { 'lichess.org' => 'contact@lichess.org' }
  s.source = { :git => pubspec['repository'], :tag => s.version.to_s }
  s.source_files = [
    'multistockfish_sf16/Sources/multistockfish_sf16/*.{c,cc,cpp,h,hpp}',
    'multistockfish_sf16/Sources/multistockfish_sf16/include/**/*.h',
    'multistockfish_sf16/Sources/multistockfish_sf16/Stockfish16/src/**/*',
  ]
  s.public_header_files = 'multistockfish_sf16/Sources/multistockfish_sf16/include/**/*.h'
  s.exclude_files = [
    'multistockfish_sf16/Sources/multistockfish_sf16/Stockfish16/src/Makefile',
    'multistockfish_sf16/Sources/multistockfish_sf16/Stockfish16/src/main.cpp',
    'multistockfish_sf16/Sources/multistockfish_sf16/Stockfish16/src/incbin/UNLICENCE',
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
    # NOTE: no -flto here (unlike multistockfish_chess/multistockfish_variant).
    # This package uniquely embeds its default NNUE net via
    # `INCBIN(EmbeddedNNUE, ...)` (evaluate.cpp), an inline-assembly `.incbin`
    # directive. Verified empirically that compiling that file under Xcode
    # with any LTO mode (-flto/-flto=thin/-flto=full) fails with "Could not
    # find incbin file", on both simulator and device target triples -
    # LTO's bitcode compilation path doesn't run the integrated-assembler
    # step `.incbin` needs.
    'OTHER_CPLUSPLUSFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -O3 -DUSE_NEON=8',
    'OTHER_LDFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -O3 -DUSE_NEON=8',
    'OTHER_CPLUSPLUSFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -O3 -DUSE_NEON=8',
    'OTHER_LDFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -O3 -DUSE_NEON=8',
  }

  s.script_phase = [
    {
      :execution_position => :before_compile,
      :name => 'Download nnue',
      :script => "[ -e 'nn-5af11540bbfe.nnue' ] || curl --location --remote-name 'https://tests.stockfishchess.org/api/nn/nn-5af11540bbfe.nnue'"
    }
  ]
end
