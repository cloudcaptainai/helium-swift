import XCTest
@testable import Helium

final class PurchaseDelegateConcurrencyTests: XCTestCase {

    private var originalDelegate: HeliumPaywallDelegate?

    override func setUp() {
        super.setUp()
        originalDelegate = Helium.config.purchaseDelegate
        Helium.config.purchaseDelegate = StoreKitDelegate()
    }

    override func tearDown() {
        if let originalDelegate {
            Helium.config.purchaseDelegate = originalDelegate
        }
        originalDelegate = nil
        super.tearDown()
    }

    func testConcurrentReadsAndWritesOfPurchaseDelegate() {
        DispatchQueue.concurrentPerform(iterations: 5_000) { index in
            if index.isMultiple(of: 2) {
                Helium.config.purchaseDelegate = StoreKitDelegate()
            } else {
                XCTAssertEqual(Helium.config.purchaseDelegate.delegateType, "h_storekit")
            }
        }
        XCTAssertTrue(Helium.config.purchaseDelegate is StoreKitDelegate)
    }
}
