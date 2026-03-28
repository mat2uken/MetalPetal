
abstract_target 'MetalPetalExamples' do
  use_frameworks!

  pod 'MetalPetal/Swift', :path => 'Frameworks/MetalPetal'

  target 'MetalPetalExamples (iOS)' do
    platform :ios, '14.0'
  end
  
  target 'MetalPetalExamples (macOS)' do
    platform :macos, '11.0'

    pod 'MetalPetal/AppleSilicon', :path => 'Frameworks/MetalPetal'
  end
end

post_install do |installer|
  Dir.glob(File.join(installer.sandbox.root.to_s, 'Target Support Files', '**', '*.xcconfig')).each do |path|
    contents = File.read(path)
    updated = contents.gsub('DT_TOOLCHAIN_DIR', 'TOOLCHAIN_DIR')
    File.write(path, updated) if updated != contents
  end
end

