#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint stockfish_hce.podspec` to validate before publishing.
#
require 'yaml'

pubspec = YAML.load(File.read(File.join(__dir__, '../../../pubspec.yaml')))

Pod::Spec.new do |s|
  s.name             = 'stockfish_hce'
  s.version          = pubspec['version']
  s.summary          = 'Stockfish using Hand Crafted Evaluation'
  s.description      = <<-DESC
Stockfish using Hand Crafted Evaluation
                       DESC
  s.homepage         = pubspec['homepage']
  s.license          = { :file => '../LICENSE', :type => 'GPL' }
  s.author           = { 'lichess.org' => 'contact@lichess.org' }

  s.source = { :git => pubspec['repository'], :tag => s.version.to_s }
  s.source_files = 'Classes/**/*', 'Stockfish11/src/**/*'
  s.exclude_files = [
    'Stockfish11/src/Makefile',
    'Stockfish11/src/main.cpp',
  ]
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++11',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'OTHER_CPLUSPLUSFLAGS' => '-std=c++11 -mdynamic-no-pic -DIS_64BIT -DUSE_POPCNT',
    'OTHER_LDFLAGS' => '-std=c++11 -mdynamic-no-pic -DIS_64BIT -DUSE_POPCNT',
    'OTHER_CPLUSPLUSFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -O3 -flto',
    'OTHER_LDFLAGS[config=Profile]' => '$(inherited) -fno-exceptions -DNDEBUG -O3 -flto',
    'OTHER_CPLUSPLUSFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -O3 -flto',
    'OTHER_LDFLAGS[config=Release]' => '$(inherited) -fno-exceptions -DNDEBUG -O3 -flto',
  }

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
