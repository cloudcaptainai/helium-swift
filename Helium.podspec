Pod::Spec.new do |s|
    s.name             = 'Helium'
    s.version          = '1.5.3'  # Match your current version
    s.summary          = 'Helium SDK for iOS'
    s.homepage         = 'https://github.com/cloudcaptainai/helium-swift'
    s.license          = { :type => 'MIT', :file => 'LICENSE' }
    s.author           = { 'Anish Doshi' => 'anish@tryhelium.com' }
    s.source           = { :git => 'https://github.com/cloudcaptainai/helium-swift.git', :branch => 'apd/1.5.4-qa' }
  
    s.ios.deployment_target = '14.0'
    s.swift_version = '5.0'
  
    s.source_files = 'Sources/**/*'
    
    # Convert SPM dependencies to CocoaPods
    s.dependency 'Kingfisher', '~> 7.0'
    s.dependency 'AnyCodable', '~> 0.6.0'
    s.dependency 'Analytics', '~> 1.5.11'  # Segment analytics-swift
    s.dependency 'SwiftyJSON', '~> 5.0.2'
    s.dependency 'DeviceKit', '~> 4.0.0'
  end