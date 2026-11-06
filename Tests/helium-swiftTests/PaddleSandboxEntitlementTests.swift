import XCTest
@testable import Helium

/// `/check-entitlement` reports which Paddle account answered. A sandbox purchase
/// costs nothing, so only non-production builds may treat it as paid.
final class PaddleSandboxEntitlementTests: XCTestCase {

    private func countedSubscriptionIds(
        paddleEnvironment: String?,
        buildEnvironment: AppReceiptsHelper.Environment
    ) throws -> [String] {
        var json: [String: Any] = [
            "hasActiveEntitlement": true,
            "subscriptions": [
                ["subscriptionId": "sub_1", "productId": "prod_1", "status": "active"],
            ],
        ]
        if let paddleEnvironment {
            json["paddleEnvironment"] = paddleEnvironment
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = try JSONDecoder().decode(PaymentEntitlementResponse.self, from: data)
        return response.countedSubscriptions(buildEnvironment: buildEnvironment).map(\.subscriptionId)
    }

    func testSandboxEntitlementIsUnpaidInProductionBuild() throws {
        XCTAssertEqual(try countedSubscriptionIds(paddleEnvironment: "sandbox", buildEnvironment: .production), [])
    }

    func testSandboxEntitlementCountsInDebugAndSandboxBuilds() throws {
        for build in [AppReceiptsHelper.Environment.debug, .sandbox] {
            XCTAssertEqual(
                try countedSubscriptionIds(paddleEnvironment: "sandbox", buildEnvironment: build),
                ["sub_1"],
                "build \(build)"
            )
        }
    }

    func testLiveEntitlementCountsInEveryBuild() throws {
        for paddleEnvironment in ["live", nil] as [String?] {
            for build in [AppReceiptsHelper.Environment.debug, .sandbox, .production] {
                XCTAssertEqual(
                    try countedSubscriptionIds(paddleEnvironment: paddleEnvironment, buildEnvironment: build),
                    ["sub_1"],
                    "paddleEnvironment \(paddleEnvironment ?? "nil"), build \(build)"
                )
            }
        }
    }
}
