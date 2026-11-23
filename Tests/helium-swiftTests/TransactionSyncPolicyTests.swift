import XCTest
import StoreKit
@testable import Helium

final class TransactionSyncPolicyTests: XCTestCase {
    func testRelaunchRecoversTransactionBufferedDuringAnalyticsStartup() throws {
        try withSyncedIdsStore { fileURL, defaults, writeKey in
            let eventsURL = fileURL.deletingLastPathComponent().appendingPathComponent("events")
            let analytics = Analytics(configuration: SegmentConfiguration(writeKey: writeKey)
                .apiHost("127.0.0.1:9").cdnHost("127.0.0.1:9")
                .trackApplicationLifecycleEvents(false).autoAddSegmentDestination(false)
                .storageMode(.diskAtURL(eventsURL)))
            if let startup = analytics.find(pluginType: StartupQueue.self) {
                analytics.remove(plugin: startup)
            }
            let startup = StartupQueue()
            analytics.timeline.plugins[.before]?.plugins.insert(startup, at: 0)
            var ids: [UInt64: Date] = [:]
            let transactions: [UInt64: Date] = [42: Date()]
            TransactionSyncPolicy.sync(transactions: transactions, organizationId: "organization", syncedIds: &ids) { ids, _ in
                TransactionSyncClient.enqueueTransactions(ids.map { ($0, ["canonicalTransactionId": $0]) }, analytics: analytics)
            }
            XCTAssertTrue(TransactionSyncPolicy.saveSyncedIds(ids, fileURL: fileURL))
            startup.syncQueue.sync { startup.queuedEvents.removeAll() }

            let relaunchedStore = DirectoryStore(configuration: .init(
                writeKey: writeKey, storageLocation: eventsURL, baseFilename: "segment-events",
                maxFileSize: Storage.MAXFILESIZE, indexKey: Storage.Constants.events.rawValue))
            var recoveredIds: [UInt64] = []
            for url in relaunchedStore.fetch(count: nil, maxBytes: nil)?.dataFiles ?? [] {
                let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                XCTAssertEqual(batch["writeKey"] as? String, writeKey)
                for event in batch["batch"] as? [[String: Any]] ?? [] {
                    XCTAssertEqual(event["event"] as? String, "helium_transactionSynced")
                    XCTAssertNotNil(event["messageId"] as? String)
                    XCTAssertNotNil(event["context"] as? [String: Any])
                    let properties = event["properties"] as? [String: Any]
                    if let id = properties?["canonicalTransactionId"] as? NSNumber { recoveredIds.append(id.uint64Value) }
                }
            }
            var relaunchedIds = TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults).ids
            TransactionSyncPolicy.sync(transactions: transactions, organizationId: "organization", syncedIds: &relaunchedIds) { ids, _ in
                recoveredIds.append(contentsOf: ids)
                return ids
            }
            XCTAssertEqual(recoveredIds, [42], "Relaunch must recover the queued event or resend the transaction")
        }
    }

    func testFailedDurableHandoffIsResentAfterRelaunch() throws {
        try withSyncedIdsStore { fileURL, defaults, writeKey in
            let eventsURL = fileURL.deletingLastPathComponent().appendingPathComponent("events")
            try Data().write(to: eventsURL)
            let analytics = Analytics(configuration: SegmentConfiguration(writeKey: writeKey)
                .trackApplicationLifecycleEvents(false).autoAddSegmentDestination(false)
                .storageMode(.diskAtURL(eventsURL)))
            let transactions: [UInt64: Date] = [42: Date(timeIntervalSince1970: 100)]
            var ids: [UInt64: Date] = [:]
            TransactionSyncPolicy.sync(transactions: transactions, organizationId: "organization", syncedIds: &ids) { ids, _ in
                TransactionSyncClient.enqueueTransactions(ids.map { ($0, ["canonicalTransactionId": $0]) }, analytics: analytics)
            }
            XCTAssertTrue(ids.isEmpty)
            XCTAssertTrue(TransactionSyncPolicy.saveSyncedIds(ids, fileURL: fileURL))

            try FileManager.default.removeItem(at: eventsURL)
            var relaunchedIds = TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults).ids
            var resentIds: [UInt64] = []
            TransactionSyncPolicy.sync(transactions: transactions, organizationId: "organization", syncedIds: &relaunchedIds) { ids, _ in
                resentIds = TransactionSyncClient.enqueueTransactions(ids.map { ($0, ["canonicalTransactionId": $0]) }, analytics: analytics)
                return resentIds
            }
            XCTAssertEqual(resentIds, [42])
            XCTAssertEqual(relaunchedIds, transactions)
            XCTAssertEqual(analytics.storage.dataStore.fetch()?.dataFiles?.count, 1)
        }
    }

    func testTransactionPassWritesOneDurableBatch() throws {
        try withSyncedIdsStore { fileURL, _, writeKey in
            let eventsURL = fileURL.deletingLastPathComponent().appendingPathComponent("events")
            let analytics = Analytics(configuration: SegmentConfiguration(writeKey: writeKey)
                .trackApplicationLifecycleEvents(false).autoAddSegmentDestination(false)
                .storageMode(.diskAtURL(eventsURL)))
            XCTAssertTrue(TransactionSyncClient.enqueueTransactions([], analytics: analytics).isEmpty)
            XCTAssertNil(analytics.storage.dataStore.fetch())
            let ids = (1...50).map(UInt64.init)
            let acceptedIds = TransactionSyncClient.enqueueTransactions(
                ids.map { ($0, ["canonicalTransactionId": $0]) }, analytics: analytics)
            XCTAssertEqual(acceptedIds, ids)
            let files = try XCTUnwrap(analytics.storage.dataStore.fetch()?.dataFiles)
            XCTAssertEqual(files.count, 1)
            let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(files.first))) as? [String: Any])
            XCTAssertEqual((batch["batch"] as? [[String: Any]])?.count, ids.count)
        }
    }

    func testDurableBatchesSplitAtSizeLimitAndRejectOversizedEvents() throws {
        try withSyncedIdsStore { fileURL, _, writeKey in
            let eventsURL = fileURL.deletingLastPathComponent().appendingPathComponent("events")
            let event = TrackEvent(event: "helium_transactionSynced", properties: try SegmentJSON(["value": String(repeating: "x", count: 200)]))
            let encodedSize = try JSONEncoder().encode(event).count
            let overhead = try JSONSerialization.data(withJSONObject: [
                "batch": [], "sentAt": Date().iso8601(), "writeKey": writeKey
            ]).count
            let limit = overhead + 2 * encodedSize + 1
            let store = DirectoryStore(configuration: .init(
                writeKey: writeKey, storageLocation: eventsURL, baseFilename: "segment-events",
                maxFileSize: limit, indexKey: Storage.Constants.events.rawValue))
            let oversized = TrackEvent(event: "helium_transactionSynced", properties: try SegmentJSON(["value": String(repeating: "x", count: limit)]))
            let events = [event, event, oversized, event, event, event, event, event]
            XCTAssertEqual(store.appendDurably(data: events), [0, 1, 3, 4, 5, 6, 7])
            let files = try XCTUnwrap(store.fetch(count: nil, maxBytes: nil)?.dataFiles)
            XCTAssertEqual(files.count, 4)
            var recoveredCount = 0
            for file in files {
                let data = try Data(contentsOf: file)
                XCTAssertLessThanOrEqual(data.count, limit)
                let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                recoveredCount += try XCTUnwrap(batch["batch"] as? [[String: Any]]).count
            }
            XCTAssertEqual(recoveredCount, 7)
        }
    }

    func testOnlyDurablyAcceptedIdsAreMarkedSynced() {
        let purchaseDate = Date(timeIntervalSince1970: 100)
        var syncedIds: [UInt64: Date] = [:]
        TransactionSyncPolicy.sync(
            transactions: [1: purchaseDate, 2: purchaseDate], organizationId: "organization", syncedIds: &syncedIds
        ) { _, _ in [1, 3] }
        XCTAssertEqual(syncedIds, [1: purchaseDate])
    }

    func testProductTypeMetadataUsesExistingPayloadSpellings() {
        let cases: [(Product.ProductType?, String)] = [
            (.autoRenewable, "autoRenewable"), (.nonRenewable, "nonRenewable"),
            (.consumable, "consumable"), (.nonConsumable, "nonConsumable"),
            (Product.ProductType(rawValue: "future"), "unknown"), (nil, "unknown")
        ]
        for (type, expected) in cases {
            let properties = TransactionSyncPolicy.metadata(
                trigger: .history, sdkEnvironment: "PRODUCTION", storeEnvironment: nil,
                ownershipType: "PURCHASED", revocationDate: nil, isUpgraded: false, expirationDate: nil,
                syncedIdCount: 0, syncedIdsState: .empty, productType: type
            )
            XCTAssertEqual(properties["productType"] as? String, expected)
        }
    }

    func testSavedIdsLoadStatesRemainFixedWhileCountAdvances() throws {
        try withSyncedIdsStore { fileURL, defaults, _ in
            let date = Date(timeIntervalSince1970: 100)
            let cases: [(TransactionSyncedIdsState, Data?)] = [
                (.loaded, try JSONEncoder().encode(TransactionSyncedIdsFile(schemaVersion: TransactionSyncPolicy.schemaVersion, ids: [1: date]))),
                (.loaded, try JSONEncoder().encode(TransactionSyncedIdsFile(schemaVersion: TransactionSyncPolicy.schemaVersion, ids: [:]))),
                (.empty, nil),
                (.migrated, try JSONEncoder().encode(TransactionSyncedIdsFile(schemaVersion: 0, ids: [1: date]))),
                (.decodeFailed, Data("invalid".utf8)),
                (.decodeFailed, Data("null".utf8)),
                (.decodeFailed, Data("{}".utf8))
            ]
            for (index, (expectedState, data)) in cases.enumerated() {
                if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
                if let data { try data.write(to: fileURL, options: .atomic) }
                let loaded = TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults)
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
                        return [id]
                    }
                    XCTAssertTrue(TransactionSyncPolicy.saveSyncedIds(ids, fileURL: fileURL))
                }
                XCTAssertEqual(loaded.state, expectedState)
                XCTAssertEqual(ids.count, loaded.ids.count + 2)
                XCTAssertEqual(TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults).state, .loaded)
            }
        }
    }

    private func withSyncedIdsStore(_ test: (URL, UserDefaults, String) throws -> Void) throws {
        let suite = "TransactionSyncPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try test(directory.appendingPathComponent("synced_ids.json"), defaults, suite)
    }

    func testMissingFileWithLegacyListIsMigratedAndDefaultsAreDeletedWithoutImport() throws {
        try withSyncedIdsStore { fileURL, defaults, _ in
            defaults.set(try JSONEncoder().encode([UInt64(1): Date()]), forKey: "heliumSyncedTransactionIds")
            defaults.set(TransactionSyncPolicy.schemaVersion, forKey: "heliumTransactionSyncSchemaVersion")
            defaults.set("keep", forKey: "hostPreference")
            let loaded = TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults)
            XCTAssertEqual(loaded.state, .migrated)
            XCTAssertTrue(loaded.ids.isEmpty)
            XCTAssertNil(defaults.object(forKey: "heliumSyncedTransactionIds"))
            XCTAssertNil(defaults.object(forKey: "heliumTransactionSyncSchemaVersion"))
            XCTAssertEqual(defaults.string(forKey: "hostPreference"), "keep")
            XCTAssertEqual(TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults).state, .empty)
        }
    }

    func testMissingFileWithoutLegacyListIsEmptyOnFreshInstall() throws {
        try withSyncedIdsStore { fileURL, defaults, _ in
            let loaded = TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults)
            XCTAssertEqual(loaded.state, .empty)
            XCTAssertTrue(loaded.ids.isEmpty)
            XCTAssertNil(defaults.object(forKey: "heliumSyncedTransactionIds"))
            XCTAssertNil(defaults.object(forKey: "heliumTransactionSyncSchemaVersion"))
        }
    }

    func testSavedFileSurvivesClearingDefaultsAndCreatesDirectory() throws {
        try withSyncedIdsStore { fileURL, defaults, suite in
            let nestedFile = fileURL.deletingLastPathComponent().appendingPathComponent("Helium/synced_ids.json")
            let ids: [UInt64: Date] = [1: Date(timeIntervalSince1970: 100)]
            XCTAssertTrue(TransactionSyncPolicy.saveSyncedIds(ids, fileURL: nestedFile))
            defaults.removePersistentDomain(forName: suite)
            let loaded = TransactionSyncPolicy.loadSyncedIds(fileURL: nestedFile, defaults: defaults)
            XCTAssertEqual(loaded.state, .loaded)
            XCTAssertEqual(loaded.ids, ids)
            let stored = try JSONDecoder().decode(TransactionSyncedIdsFile.self, from: Data(contentsOf: nestedFile))
            XCTAssertEqual(stored.schemaVersion, TransactionSyncPolicy.schemaVersion)
            XCTAssertEqual(stored.ids, ids)
        }
    }

    func testUnavailableUnreadableAndUnwritableFilesAreContained() throws {
        try withSyncedIdsStore { fileURL, defaults, _ in
            XCTAssertEqual(TransactionSyncPolicy.loadSyncedIds(fileURL: nil, defaults: defaults).state, .decodeFailed)
            XCTAssertFalse(TransactionSyncPolicy.saveSyncedIds([:], fileURL: nil))
            let directory = fileURL.deletingLastPathComponent()
            XCTAssertEqual(TransactionSyncPolicy.loadSyncedIds(fileURL: directory, defaults: defaults).state, .decodeFailed)
            XCTAssertFalse(TransactionSyncPolicy.saveSyncedIds([:], fileURL: directory))
            let corrupt = Data("invalid".utf8)
            try corrupt.write(to: fileURL, options: .atomic)
            XCTAssertEqual(TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults).state, .decodeFailed)
            XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
            XCTAssertFalse(TransactionSyncPolicy.saveSyncedIds([:], fileURL: fileURL.appendingPathComponent("blocked.json")))
            XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
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
                return []
            }
            XCTAssertTrue(syncedIds.isEmpty)
        }
    }

    func testDeferredTransactionsSendOnceOrganizationIsAvailable() {
        let purchaseDate = Date(timeIntervalSince1970: 100)
        var syncedIds: [UInt64: Date] = [:]
        var sentIds: [UInt64] = []
        let send: ([UInt64], String) -> [UInt64] = { ids, organizationId in
            XCTAssertEqual(organizationId, "example-organization")
            sentIds.append(contentsOf: ids)
            return ids
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
                return []
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
            return ids
        }
        XCTAssertEqual(syncedIds, [1: purchaseDate, 2: purchaseDate])
    }

    func testOrganizationResolutionSkipsBlankCandidates() {
        XCTAssertNil(TransactionSyncPolicy.organizationId(nil, "", " \n"))
        XCTAssertEqual(TransactionSyncPolicy.organizationId(" ", " example-organization "), "example-organization")
        XCTAssertEqual(TransactionSyncPolicy.organizationId("first", "second"), "first")
    }

    func testOlderFileSchemaClearsIdsOnlyOnce() throws {
        try withSyncedIdsStore { fileURL, defaults, _ in
            let ids: [UInt64: Date] = [1: Date(timeIntervalSince1970: 100)]
            let old = TransactionSyncedIdsFile(schemaVersion: 0, ids: ids)
            try JSONEncoder().encode(old).write(to: fileURL, options: .atomic)
            let loaded = TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults)
            XCTAssertEqual(loaded.state, .migrated)
            XCTAssertTrue(loaded.ids.isEmpty)
            let stored = try JSONDecoder().decode(TransactionSyncedIdsFile.self, from: Data(contentsOf: fileURL))
            XCTAssertEqual(stored.schemaVersion, TransactionSyncPolicy.schemaVersion)
            XCTAssertTrue(stored.ids.isEmpty)
            XCTAssertEqual(TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults).state, .loaded)
            XCTAssertTrue(TransactionSyncPolicy.saveSyncedIds(ids, fileURL: fileURL))
            XCTAssertEqual(TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults).ids, ids)
        }
    }

    func testNewerSchemaDoesNotClearIdsOrDowngradeVersion() throws {
        try withSyncedIdsStore { fileURL, defaults, _ in
            let ids: [UInt64: Date] = [1: Date(timeIntervalSince1970: 100)]
            let newer = TransactionSyncedIdsFile(schemaVersion: TransactionSyncPolicy.schemaVersion + 1, ids: ids)
            let data = try JSONEncoder().encode(newer)
            try data.write(to: fileURL, options: .atomic)
            let loaded = TransactionSyncPolicy.loadSyncedIds(fileURL: fileURL, defaults: defaults)
            XCTAssertEqual(loaded.state, .loaded)
            XCTAssertEqual(loaded.ids, ids)
            XCTAssertEqual(try Data(contentsOf: fileURL), data)
        }
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
