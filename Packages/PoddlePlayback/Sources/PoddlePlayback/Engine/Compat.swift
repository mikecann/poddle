import AVFoundation

// iOS 27 / macOS 27 replaced the non-throwing connect and play calls with throwing ones. The package
// also builds for macOS 26 (so tests run on today's Macs), where only the old calls exist.

extension AVAudioEngine {
    func link(_ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat?) throws {
        #if os(macOS)
        if #available(macOS 27, *) {
            try connectNode(source, to: destination, format: format)
        } else {
            connect(source, to: destination, format: format)
        }
        #else
        try connectNode(source, to: destination, format: format)
        #endif
    }
}

extension AVAudioPlayerNode {
    func start() throws {
        #if os(macOS)
        if #available(macOS 27, *) {
            try playAudio()
        } else {
            play()
        }
        #else
        try playAudio()
        #endif
    }
}

extension AVAudioNode {
    func setParameter(_ address: AUParameterAddress, to value: AUValue) {
        #if os(macOS)
        if #available(macOS 27, *) {
            withAUAudioUnit { $0.parameterTree?.parameter(withAddress: address)?.value = value }
        } else {
            auAudioUnit.parameterTree?.parameter(withAddress: address)?.value = value
        }
        #else
        withAUAudioUnit { $0.parameterTree?.parameter(withAddress: address)?.value = value }
        #endif
    }
}
