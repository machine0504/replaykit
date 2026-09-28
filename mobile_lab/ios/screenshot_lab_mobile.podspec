Pod::Spec.new do |s|
  s.name             = 'screenshot_lab_mobile'
  s.version          = '0.1.0'
  s.summary          = 'Lab screenshot plugin (system capture on iOS via ReplayKit broadcast).'
  s.homepage         = 'https://example.com'
  s.license          = { :type => 'MIT' }
  s.author           = { 'lab' => 'lab@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'ReplayKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
