import XCTest
@testable import Helium

final class TransactionSyncPolicyTests: XCTestCase {
    func testSavedIdsLoadStatesRemainFixedWhileCountAdvances() throws {
        let suite = "TransactionSyncPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "syncedIds"
        let date = Date(timeIntervalSince1970: 100)
        let cases: [(TransactionSyncedIdsState, Any?, Int)] = [
            (.loaded, try JSONEncoder().encode([UInt64(1): date]), TransactionSyncPolicy.schemaVersion),
            (.loaded, try JSONEncoder().encode([UInt64: Date]()), TransactionSyncPolicy.schemaVersion),
            (.empty, nil, TransactionSyncPolicy.schemaVersion),
            (.migrated, try JSONEncoder().encode([UInt64(1): date]), 0),
            (.migrated, nil, 0),
            (.decodeFailed, Data("invalid".utf8), TransactionSyncPolicy.schemaVersion),
            (.decodeFailed, "not data", TransactionSyncPolicy.schemaVersion),
            (.decodeFailed, Data("null".utf8), TransactionSyncPolicy.schemaVersion)
        ]
        for (index, (expectedState, stored, version)) in cases.enumerated() {
            defaults.removeObject(forKey: key)
            if let stored { defaults.set(stored, forKey: key) }
            defaults.set(version, forKey: TransactionSyncPolicy.schemaVersionKey)
            let loaded = TransactionSyncPolicy.loadSyncedIds(defaults: defaults, syncedIdsKey: key)
            XCTAssertEqual(loaded.state, expectedState)
            XCTAssertEqual(loaded.ids, index == 0 ? [1: date] : [:])
            var ids = loaded.ids
            for id in [UInt64(2), 3] {
                let countBeforeSending = ids.count
                TransactionSyncPolicy.sync(transactions: [id: date], organizationId: "organization", syncedIds: &ids) { _, _ in
                    let properties = TransactionSyncPolicy.metadata(
                        trigger: .history, sdkEnvironment: "PRODUCTION", storeEnvironment: nil,
                        ownershipType: "PURCHASED", revocationDate: nil, isUpgraded: false, expirationDate: nil,
                        syncedIdCount: countBeforeSending, syncedIdsState: loaded.state
                    )
                    XCTAssertEqual(properties["syncedIdCount"] as? Int, loaded.ids.count + Int(id) - 2)
                    XCTAssertEqual(properties["syncedIdsState"] as? String, expectedState.rawValue)
                }
                defaults.set(try JSONEncoder().encode(ids), forKey: key)
            }
            XCTAssertEqual(loaded.state, expectedState)
            XCTAssertEqual(ids.count, loaded.ids.count + 2)
            XCTAssertEqual(TransactionSyncPolicy.loadSyncedIds(defaults: defaults, syncedIdsKey: key).state, .loaded)
        }
    }

    func testForegroundAfterRunningScanSnapshotCoalescesOneRescanWithoutPendingWork() {
        var throttle = TransactionSyncThrottle()
        var state = TransactionHistorySyncState()
        XCTAssertTrue(state.request())
        throttle.startedScan()
        XCTAssertTrue(throttle.shouldSync(now: 10))
        XCTAssertFalse(state.request())
        throttle.startedScan()
        for now in [11.0, 12] {
            XCTAssertFalse(throttle.shouldSync(now: now))
        }
        throttle.completedScan(now: 20)
        XCTAssertTrue(state.finishPass())
        throttle.startedScan()
        throttle.completedScan(now: 21)
        XCTAssertFalse(state.finishPass())
        XCTAssertFalse(throttle.takeDeferredForeground(now: 70))
    }

    func testThrottledForegroundDuringRunningScanSurvivesThatPassCompleting() {
        var throttle = TransactionSyncThrottle()
        var state = TransactionHistorySyncState()
        throttle.completedScan(now: 100)
        XCTAssertTrue(state.request())
        throttle.startedScan()
        XCTAssertFalse(throttle.shouldSync(now: 111))
        throttle.completedScan(now: 120)
        XCTAssertFalse(state.finishPass())
        XCTAssertEqual(throttle.deferredForegroundAt, 160)
        XCTAssertTrue(throttle.takeDeferredForeground(now: 160))
        XCTAssertTrue(state.request())
        throttle.startedScan()
        XCTAssertFalse(state.finishPass())
    }

    func testDeferredForegroundDuringLongRunningScanCoalescesOneRescan() {
        var throttle = TransactionSyncThrottle()
        var state = TransactionHistorySyncState()
        throttle.completedScan(now: 100)
        XCTAssertTrue(state.request())
        throttle.startedScan()
        XCTAssertFalse(throttle.shouldSync(now: 111))
        XCTAssertTrue(throttle.takeDeferredForeground(now: 160))
        XCTAssertFalse(state.request())
        throttle.startedScan()
        throttle.completedScan(now: 170)
        XCTAssertTrue(state.finishPass())
        throttle.startedScan()
        XCTAssertFalse(state.finishPass())
        XCTAssertFalse(throttle.takeDeferredForeground(now: 200))
    }

    func testThrottledForegroundDefersOneScanUntilWindowEnds() {
        var throttle = TransactionSyncThrottle()
        XCTAssertFalse(throttle.takeDeferredForeground(now: 100))
        throttle.completedScan(now: 100)
        XCTAssertFalse(throttle.shouldSync(now: 110))
        XCTAssertEqual(throttle.deferredForegroundAt, 160)
        XCTAssertFalse(throttle.takeDeferredForeground(now: 159.999))
        XCTAssertTrue(throttle.takeDeferredForeground(now: 160))
        XCTAssertFalse(throttle.takeDeferredForeground(now: 160))
    }

    func testRepeatedThrottledForegroundsCoalesceAtOriginalDeadline() {
        var throttle = TransactionSyncThrottle()
        var state = TransactionHistorySyncState()
        throttle.completedScan(now: 100)
        for now in [101.0, 120, 159.999] {
            XCTAssertFalse(throttle.shouldSync(now: now))
            XCTAssertEqual(throttle.deferredForegroundAt, 160)
        }
        XCTAssertTrue(throttle.takeDeferredForeground(now: 160))
        XCTAssertTrue(state.request())
        throttle.startedScan()
        XCTAssertFalse(throttle.takeDeferredForeground(now: 160))
        XCTAssertFalse(state.finishPass())
    }

    func testInterveningScanInvalidatesDeferredForegroundWithoutExtraPass() {
        var throttle = TransactionSyncThrottle()
        var state = TransactionHistorySyncState()
        throttle.completedScan(now: 100)
        XCTAssertFalse(throttle.shouldSync(now: 110))
        XCTAssertTrue(state.request())
        throttle.startedScan()
        XCTAssertNil(throttle.deferredForegroundAt)
        XCTAssertFalse(throttle.takeDeferredForeground(now: 160))
        XCTAssertFalse(state.finishPass())
        XCTAssertFalse(throttle.takeDeferredForeground(now: 200))
    }

    func testHistoryDrainPreservesOriginalPendingTriggers() {
        var pending = TransactionSyncPending<String>()
        pending.add("listener", id: 1, trigger: .listener)
        pending.add("purchase", id: 2, trigger: .afterPurchase)
        pending.add("history", id: 3)
        pending.add("listener rescanned", id: 1)
        pending.add("purchase rescanned", id: 2)
        XCTAssertEqual(pending.triggers, [1: .listener, 2: .afterPurchase, 3: .history])
        pending.remove(ids: [1, 2, 3])
        XCTAssertTrue(pending.triggers.isEmpty)
        XCTAssertTrue(pending.transactions.isEmpty)
    }

    func testFamilySharedMetadataRetainsExplicitOwnership() {
        let properties = TransactionSyncPolicy.metadata(
            trigger: .history, sdkEnvironment: "SANDBOX", storeEnvironment: "SANDBOX",
            ownershipType: "FAMILY_SHARED", revocationDate: nil, isUpgraded: false, expirationDate: nil,
            syncedIdCount: 0, syncedIdsState: .empty
        )
        XCTAssertEqual(properties["ownershipType"] as? String, "FAMILY_SHARED")
        XCTAssertEqual(properties["syncSchemaVersion"] as? Int, 2)
    }

    func testSyncedMetadataIncludesProvenanceAndStoreDates() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for trigger in TransactionSyncTrigger.allCases {
            let properties = TransactionSyncPolicy.metadata(
                trigger: trigger, sdkEnvironment: "PRODUCTION", storeEnvironment: "SANDBOX",
                ownershipType: "PURCHASED", revocationDate: date, isUpgraded: true, expirationDate: date,
                syncedIdCount: 4, syncedIdsState: .loaded
            )
            XCTAssertEqual(properties["syncSchemaVersion"] as? Int, 2)
            XCTAssertEqual(properties["syncTrigger"] as? String, trigger.rawValue)
            XCTAssertEqual(properties["sdkEnvironment"] as? String, "PRODUCTION")
            XCTAssertEqual(properties["syncedIdCount"] as? Int, 4)
            XCTAssertEqual(properties["syncedIdsState"] as? String, "loaded")
            XCTAssertEqual(properties["storeEnvironment"] as? String, "SANDBOX")
            XCTAssertEqual(properties["ownershipType"] as? String, "PURCHASED")
            XCTAssertEqual(properties["revocationDate"] as? String, formatAsTimestamp(date: date))
            XCTAssertEqual(properties["expirationDate"] as? String, formatAsTimestamp(date: date))
            XCTAssertEqual(properties["isUpgraded"] as? Bool, true)
            XCTAssertNil(properties["environment"])
        }
    }

    func testSyncedMetadataOmitsUnavailableStoreAndDates() {
        let properties = TransactionSyncPolicy.metadata(
            trigger: .history, sdkEnvironment: "SANDBOX", storeEnvironment: nil,
            ownershipType: "PURCHASED", revocationDate: nil, isUpgraded: false, expirationDate: nil,
            syncedIdCount: 0, syncedIdsState: .decodeFailed
        )
        XCTAssertNil(properties["storeEnvironment"])
        XCTAssertNil(properties["revocationDate"])
        XCTAssertNil(properties["expirationDate"])
        XCTAssertEqual(properties["isUpgraded"] as? Bool, false)
    }

    func testOrganizationRetryUsesThreeShortBackoffDelays() {
        XCTAssertEqual(TransactionSyncPolicy.organizationRetryDelays, [10_000_000_000, 30_000_000_000, 60_000_000_000])
    }

    func testOverlappingHistoryRequestsCoalesceIntoOneAdditionalPass() {
        var state = TransactionHistorySyncState()
        XCTAssertTrue(state.request())
        XCTAssertFalse(state.request())
        XCTAssertFalse(state.request())
        XCTAssertTrue(state.finishPass())
        XCTAssertFalse(state.finishPass())
        XCTAssertTrue(state.request())
        XCTAssertFalse(state.finishPass())
    }

    func testRequestDuringRescanSchedulesAnotherPass() {
        var state = TransactionHistorySyncState()
        XCTAssertTrue(state.request())
        XCTAssertFalse(state.request())
        XCTAssertTrue(state.finishPass())
        XCTAssertFalse(state.request())
        XCTAssertTrue(state.finishPass())
        XCTAssertFalse(state.finishPass())
    }

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

    func testCompletedScanSkipsStartupForegroundAndConfigRefetch() {
        var throttle = TransactionSyncThrottle()
        XCTAssertTrue(throttle.shouldSyncOnConfig(hasPending: false))
        throttle.completedScan(now: 100)
        XCTAssertFalse(throttle.shouldSync(now: 100))
        XCTAssertFalse(throttle.shouldSyncOnConfig(hasPending: false))
        XCTAssertFalse(throttle.shouldSyncOnConfig(hasPending: false))
        XCTAssertTrue(throttle.shouldSync(now: 160))
    }

    func testPendingWorkBypassesCompletedScanThrottle() {
        var throttle = TransactionSyncThrottle()
        throttle.completedScan(now: 100)
        XCTAssertTrue(throttle.shouldSyncOnConfig(hasPending: true))
        XCTAssertTrue(throttle.shouldSync(now: 101, hasPending: true))
    }

    func testIncompleteScanStillAllowsConfigRecovery() {
        var throttle = TransactionSyncThrottle()
        XCTAssertTrue(throttle.shouldSync(now: 100))
        XCTAssertTrue(throttle.shouldSyncOnConfig(hasPending: false))
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
