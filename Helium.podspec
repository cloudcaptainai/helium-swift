Pod::Spec.new do |s|
  s.name             = 'Helium'
  s.version          = '1.6.1'
  s.summary          = 'Helium SDK for iOS'
  s.homepage         = 'https://github.com/cloudcaptainai/helium-swift'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Anish Doshi' => 'anish@tryhelium.com' }
  s.source           = { :git => 'https://github.com/cloudcaptainai/helium-swift.git', :branch => 'cocoapod/release', :tag => '1.6.1-cocoapod' }

  s.ios.deployment_target = '14.0'
  s.swift_version = '5.0'
  
  # Set the static_framework flag to true
  s.static_framework = true
  
  s.source_files = ['Sources/Helium/**/*']

  s.dependency 'Kingfisher', '~> 7.0'
  s.dependency 'AnyCodable-FlightSchool', '~> 0.6.0'
  s.dependency 'Analytics', '~> 4.1.0'
  s.dependency 'SwiftyJSON', '~> 5.0.2'
  s.dependency 'DeviceKit', '~> 4.0.0'
end