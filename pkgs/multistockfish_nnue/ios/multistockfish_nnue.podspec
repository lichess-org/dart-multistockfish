#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint multistockfish_nnue.podspec` to validate before publishing.
#
require 'yaml'

pubspec = YAML.load(File.read(File.join(__dir__, '../pubspec.yaml')))

Pod::Spec.new do |s|
  s.name             = 'multistockfish_nnue'
  s.version          = pubspec['version']
  s.summary          = pubspec['description']
  s.homepage         = pubspec['homepage']
  s.license          = { :file => '../LICENSE', :type => 'GPL' }
  s.author           = { 'lichess.org' => 'contact@lichess.org' }
  s.source = { :git => pubspec['repository'], :tag => s.version.to_s }
  s.source_files = 'Classes/**/*', 'Stockfish17/src/**/*'
  s.exclude_files = [
    'Stockfish17/src/Makefile',
    'Stockfish17/src/main.cpp',
    'Stockfish17/src/incbin/UNLICENCE',
  ]
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Additional compiler configuration required for Stockfish
  s.library = 'c++'
  s.xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'OTHER_CPLUSPLUSFLAGS' => '-std=c++17 -mdynamic-no-pic -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT',
    'OTHER_LDFLAGS' => '-std=c++17 -mdynamic-no-pic -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT',
    'OTHER_CPLUSPLUSFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8 -flto=full',
    'OTHER_LDFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8 -flto=full',
    'OTHER_CPLUSPLUSFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8 -flto=full',
    'OTHER_LDFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -funroll-loops -O3 -DUSE_NEON=8 -flto=full',
  }
end
