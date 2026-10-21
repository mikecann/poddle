#if os(iOS)
import UIKit

extension Notification.Name {
    /// The device was shaken (shake to extend or restart the sleep timer).
    static let poddleDeviceShaken = Notification.Name("PoddleDeviceShaken")
}

extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .poddleDeviceShaken, object: nil) }
        super.motionEnded(motion, with: event)
    }
}
#endif
