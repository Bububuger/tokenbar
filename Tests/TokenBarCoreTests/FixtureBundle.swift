import Foundation

let fixtureBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: FixtureBundleToken.self)
#endif
}()

final class FixtureBundleToken {}
