Pod::Spec.new do |s|
  s.name             = 'Helium'
  s.version = `grep -o 'version = "[^"]*"' Sources/Helium/HeliumCore/BuildConstants.swift`.strip.split('"')[1]
  s.summary          = 'Helium SDK for iOS'
  s.homepage         = 'https://github.com/cloudcaptainai/helium-swift'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Anish Doshi' => 'anish@tryhelium.com' }
  s.source           = {
    :git => 'https://github.com/cloudcaptainai/helium-swift.git',
    :tag => "#{s.version}",
    :branch => 'main'
  }

  s.ios.deployment_target = '14.0'
  s.swift_version = '5.0'
  
  s.default_subspec = 'Core'
  
  # Core subspec - base Helium functionality without RevenueCat
  s.subspec 'Core' do |core|
    core.source_files = 'Sources/Helium/**/*'
  end
  
  # RevenueCat subspec - adds RevenueCat integration
  s.subspec 'RevenueCat' do |rc|
    rc.source_files = 'Sources/HeliumRevenueCat/**/*'
    rc.dependency 'Helium/Core'
    rc.dependency 'RevenueCat', '~> 5.0.0'
  end
end
