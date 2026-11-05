import Testing
@testable import PoddleKit

/// Apple's automated check of each submission runs on devices with a development kernel, and every
/// way of signing in fails there (PODDLE-A, C and D), so those reports are left out of Sentry.
struct DeviceKernelTests {
    /// The kernels Sentry recorded in those bursts: a virtual iPhone, an iPhone 13 Pro, an iPhone SE
    /// and an iPhone 15 Pro Max.
    @Test(arguments: [
        "Darwin Kernel Version 27.1.0: Thu Sep 10 22:21:19 PDT 2026; root:xnu_development-13432.2.10~176/DEVELOPMENT_ARM64_VMINTERNAL4",
        "Darwin Kernel Version 27.0.0: Thu Aug 13 21:52:29 PDT 2026; root:xnu_development-13432.2.10~2/DEVELOPMENT_ARM64_T8110",
        "Darwin Kernel Version 27.0.0: Thu Aug 13 22:13:19 PDT 2026; root:xnu_development-13432.2.10~2/DEVELOPMENT_ARM64_T8030",
        "Darwin Kernel Version 27.2.0: Tue Oct 13 21:28:02 PDT 2026; root:xnu_development-13432.42.3~28/DEVELOPMENT_ARM64_T8122",
    ])
    func applesTestDevicesAreDevelopmentKernels(version: String) {
        #expect(DeviceKernel.isDevelopment(version))
    }

    /// Real phones, betas included, run a release kernel, and they must keep reporting.
    @Test(arguments: [
        "Darwin Kernel Version 27.2.0: Tue Oct 13 21:28:02 PDT 2026; root:xnu-13432.42.3~28/RELEASE_ARM64_T8130",
        "",
    ])
    func everythingElseStillReports(version: String) {
        #expect(!DeviceKernel.isDevelopment(version))
    }

    @Test func readsThisDevicesKernel() {
        #expect(DeviceKernel.version.hasPrefix("Darwin Kernel Version"))
    }
}
