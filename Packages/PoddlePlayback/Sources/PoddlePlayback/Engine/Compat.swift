import AVFoundation

// iOS 27 / macOS 27 replaced the non-throwing connect and play calls with throwing ones. The package
// also runs on iOS 18 (Mike's iPhone XS Max) and macOS 26 (so tests run on today's Macs), where only
// the old calls exist. The new calls only compile with the iOS 27 SDK (Swift 6.4), so older
// toolchains, such as tinker-desk's e2e runner, build the old path only.

extension AVAudioEngine {
    func link(_ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat?) throws {
        #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) {
            try connectNode(source, to: destination, format: format)
        } else {
            connect(source, to: destination, format: format)
        }
        #else
        connect(source, to: destination, format: format)
        #endif
    }
}

extension AVAudioPlayerNode {
    func start() throws {
        #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) {
            try playAudio()
        } else {
            play()
        }
        #else
        play()
        #endif
    }
}

extension AVAudioNode {
    func setParameter(_ address: AUParameterAddress, to value: AUValue) {
        #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) {
            withAUAudioUnit { $0.parameterTree?.parameter(withAddress: address)?.value = value }
        } else {
            auAudioUnit.parameterTree?.parameter(withAddress: address)?.value = value
        }
        #else
        auAudioUnit.parameterTree?.parameter(withAddress: address)?.value = value
        #endif
    }
}
