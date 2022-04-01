platform :ios, '10.0'

target 'TrustKeystore' do
  use_frameworks!

  pod 'BigInt', '~> 5.2.0', inhibit_warnings: true
  pod 'CryptoSwift', '~> 1.4.3'
  pod 'TrezorCrypto', '~> 0.0.9', inhibit_warnings: true
  pod 'TrustCore', :git=>'https://github.com/PlatONnetwork/trust-core.git', :tag=> '0.2.2', inhibit_warnings: true
  pod 'SwiftLint'
  
  target 'KeystoreBenchmark'
  target 'TrustKeystoreTests'
end
