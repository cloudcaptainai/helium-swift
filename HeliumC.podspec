Pod::Spec.new do |s|
  s.name             = 'HeliumC'
  s.version          = '1.6.2'
  s.summary          = 'HeliumC SDK for iOS'
  s.homepage         = 'https://github.com/salami/analytics-swift-cocoapod'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = "Kyle G for Helium"
  s.source           = { :git => 'https://github.com/salami/analytics-swift-cocoapod.git', :branch => 'cocoapod-swift-analytics' }

  s.ios.deployment_target = '14.0'
  s.swift_version = '5.0'
  
  s.source_files = ['Sources/Helium/**/*']

  s.dependency 'Kingfisher', '~> 7.0'
  s.dependency 'AnyCodable-FlightSchool', '~> 0.6.0'
  s.dependency 'AnalyticsSwiftCocoapod', '~> 1.7.3'
  s.dependency 'SwiftyJSON', '~> 5.0.2'
  s.dependency 'DeviceKit', '~> 4.0.0'
end
