import XCTest
@testable import Helium

final class TransactionSyncPolicyTests: XCTestCase {
    func testPendingTransactionsDeduplicateAndRemoveOnlySentIds() {
        var pending = TransactionSyncPending<String>()
        pending.add("first", id: 1)
        pending.add("updated", id: 1)
        pending.add("second", id: 2)
        XCTAssertEqual(pending.transactions, [1: "updated", 2: "second"])
        pending.remove(ids: [1])
        XCTAssertEqual(pending.transactions, [2: "second"])
        pending.remove(ids: [])
        XCTAssertEqual(pending.transactions, [2: "second"])
    }

    func testMissingOrganizationDoesNotSendOrMarkTransactions() {
        for organizationId in [nil, "", " \n\t"] as [String?] {
            var syncedIds: [UInt64: Date] = [:]
            TransactionSyncPolicy.sync(
                transactions: [1: Date()], organizationId: organizationId, syncedIds: &syncedIds
            ) { _, _ in
                XCTFail("Must not send without an organization")
            }
            XCTAssertTrue(syncedIds.isEmpty)
        }
    }

    func testDeferredTransactionsSendOnceOrganizationIsAvailable() {
        let purchaseDate = Date(timeIntervalSince1970: 100)
        var syncedIds: [UInt64: Date] = [:]
        var sentIds: [UInt64] = []
        let send: ([UInt64], String) -> Void = { ids, organizationId in
            XCTAssertEqual(organizationId, "example-organization")
            sentIds.append(contentsOf: ids)
        }
        TransactionSyncPolicy.sync(
            transactions: [1: purchaseDate], organizationId: nil, syncedIds: &syncedIds, send: send
        )
        TransactionSyncPolicy.sync(
            transactions: [1: purchaseDate], organizationId: "example-organization", syncedIds: &syncedIds, send: send
        )
        TransactionSyncPolicy.sync(
            transactions: [1: purchaseDate], organizationId: "example-organization", syncedIds: &syncedIds, send: send
        )
        XCTAssertEqual(sentIds, [1])
        XCTAssertEqual(syncedIds, [1: purchaseDate])
    }

    func testEmptyAndAlreadySyncedBatchesDoNotSend() {
        let purchaseDate = Date(timeIntervalSince1970: 100)
        var syncedIds: [UInt64: Date] = [1: purchaseDate]
        for transactions in [[:], [1: purchaseDate]] as [[UInt64: Date]] {
            TransactionSyncPolicy.sync(
                transactions: transactions, organizationId: "example-organization", syncedIds: &syncedIds
            ) { _, _ in
                XCTFail("Must not send an empty batch")
            }
        }
        XCTAssertEqual(syncedIds, [1: purchaseDate])
    }

    func testOnlyUnsyncedIdsAreSentAndExistingDatesArePreserved() {
        let purchaseDate = Date(timeIntervalSince1970: 100)
        var syncedIds: [UInt64: Date] = [1: purchaseDate]
        TransactionSyncPolicy.sync(
            transactions: [1: Date(), 2: purchaseDate], organizationId: "example-organization", syncedIds: &syncedIds
        ) { ids, _ in
            XCTAssertEqual(ids, [2])
        }
        XCTAssertEqual(syncedIds, [1: purchaseDate, 2: purchaseDate])
    }

    func testOrganizationResolutionSkipsBlankCandidates() {
        XCTAssertNil(TransactionSyncPolicy.organizationId(nil, "", " \n"))
        XCTAssertEqual(TransactionSyncPolicy.organizationId(" ", " example-organization "), "example-organization")
        XCTAssertEqual(TransactionSyncPolicy.organizationId("first", "second"), "first")
    }

    func testMissingOrOlderSchemaClearsIdsOnlyOnce() throws {
        let suite = "TransactionSyncPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let idsKey = "syncedIds"
        let data = try JSONEncoder().encode([UInt64(1): Date(timeIntervalSince1970: 100)])

        for version in [nil, 0] as [Int?] {
            defaults.removeObject(forKey: TransactionSyncPolicy.schemaVersionKey)
            if let version { defaults.set(version, forKey: TransactionSyncPolicy.schemaVersionKey) }
            defaults.set(data, forKey: idsKey)
            TransactionSyncPolicy.migrate(defaults: defaults, syncedIdsKey: idsKey)
            XCTAssertNil(defaults.data(forKey: idsKey))
            XCTAssertEqual(defaults.integer(forKey: TransactionSyncPolicy.schemaVersionKey), TransactionSyncPolicy.schemaVersion)

            defaults.set(data, forKey: idsKey)
            TransactionSyncPolicy.migrate(defaults: defaults, syncedIdsKey: idsKey)
            XCTAssertEqual(defaults.data(forKey: idsKey), data)
        }
    }

    func testNewerSchemaDoesNotClearIdsOrDowngradeVersion() throws {
        let suite = "TransactionSyncPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TransactionSyncPolicy.schemaVersion + 1, forKey: TransactionSyncPolicy.schemaVersionKey)
        let data = Data([1, 2, 3])
        defaults.set(data, forKey: "syncedIds")
        TransactionSyncPolicy.migrate(defaults: defaults, syncedIdsKey: "syncedIds")
        XCTAssertEqual(defaults.data(forKey: "syncedIds"), data)
        XCTAssertEqual(defaults.integer(forKey: TransactionSyncPolicy.schemaVersionKey), TransactionSyncPolicy.schemaVersion + 1)
    }

    func testForegroundThrottleAllowsFirstCallAndSixtySecondBoundary() {
        var throttle = TransactionSyncThrottle()
        XCTAssertTrue(throttle.shouldSync(now: 100))
        XCTAssertFalse(throttle.shouldSync(now: 100))
        XCTAssertFalse(throttle.shouldSync(now: 159.999))
        XCTAssertTrue(throttle.shouldSync(now: 160))
        XCTAssertFalse(throttle.shouldSync(now: 219.999))
        XCTAssertTrue(throttle.shouldSync(now: 220))
    }
}
