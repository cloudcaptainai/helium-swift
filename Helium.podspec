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
  
  s.source_files = ['Sources/Helium/**/*']

  s.dependency 'Kingfisher', '~> 7.0'
  s.dependency 'AnyCodable-FlightSchool', '~> 0.6.0'
  s.dependency 'AnalyticsSwiftCocoapod', '~> 1.7.3'
  s.dependency 'SwiftyJSON', '~> 5.0.2'
  s.dependency 'DeviceKit', '~> 4.0.0'
end
