import Foundation
import Testing
@testable import MySDK

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

private func makeLedger(clock: TestClock = TestClock()) throws -> Ledger {
    try Ledger(configuration: LedgerConfiguration(
        inMemory: true,
        simulatedLatency: .zero,
        now: { clock.now }
    ))
}

@Suite struct LedgerTests {
    @Test func seedsInitialBalances() async throws {
        let ledger = try makeLedger()
        #expect(try await ledger.customerAccount().balance == 5000)
        #expect(try await ledger.merchantAccount().balance == 0)
        #expect(try await ledger.merchantAccount().pendingBalance == 0)
    }

    @Test(arguments: [
        (Decimal(1000), Decimal(15)),
        (Decimal(100), Decimal(string: "1.5")!),
        (Decimal(string: "33.33")!, Decimal(string: "0.5")!),
        (Decimal(string: "0.01")!, Decimal(0)),
    ])
    func feeIsOnePointFivePercent(amount: Decimal, expectedFee: Decimal) async throws {
        let ledger = try makeLedger()
        let transaction = try await ledger.pay(amount: amount)
        #expect(transaction.fee == expectedFee)
        #expect(transaction.netAmount == amount - expectedFee)
    }

    @Test func paymentDebitsCustomerAndStaysPending() async throws {
        let ledger = try makeLedger()
        let transaction = try await ledger.pay(amount: 1000)

        #expect(transaction.status == .pending)
        #expect(try await ledger.customerAccount().balance == 4000)
        let merchant = try await ledger.merchantAccount()
        #expect(merchant.balance == 0)
        #expect(merchant.pendingBalance == 985)
    }

    @Test func rejectsPaymentAboveBalance() async throws {
        let ledger = try makeLedger()
        try await ledger.pay(amount: 1000)

        await #expect(throws: LedgerError.insufficientFunds(available: 4000, requested: 5000)) {
            try await ledger.pay(amount: 5000)
        }
        #expect(try await ledger.customerAccount().balance == 4000)
        #expect(try await ledger.transactions().count == 1)
    }

    @Test func allowsSpendingExactBalance() async throws {
        let ledger = try makeLedger()
        try await ledger.pay(amount: 5000)
        #expect(try await ledger.customerAccount().balance == 0)
    }

    @Test(arguments: [Decimal(0), Decimal(-10), Decimal(string: "1.005")!])
    func rejectsInvalidAmounts(amount: Decimal) async throws {
        let ledger = try makeLedger()
        await #expect(throws: LedgerError.invalidAmount) {
            try await ledger.pay(amount: amount)
        }
        #expect(try await ledger.customerAccount().balance == 5000)
    }

    @Test func settlementAggregatesPendingTransactions() async throws {
        let clock = TestClock()
        let ledger = try makeLedger(clock: clock)
        try await ledger.pay(amount: 1000)
        try await ledger.pay(amount: 200)
        try await ledger.pay(amount: 300)

        clock.advance(by: 299)
        #expect(try await ledger.settleIfDue() == nil)
        #expect(try await ledger.merchantAccount().balance == 0)

        clock.advance(by: 1)
        let settlement = try #require(try await ledger.settleIfDue())
        #expect(settlement.transactionCount == 3)
        #expect(settlement.grossAmount == 1500)
        #expect(settlement.totalFees == Decimal(string: "22.5")!)
        #expect(settlement.netAmount == Decimal(string: "1477.5")!)

        let merchant = try await ledger.merchantAccount()
        #expect(merchant.balance == Decimal(string: "1477.5")!)
        #expect(merchant.pendingBalance == 0)
        #expect(try await ledger.transactions().allSatisfy { $0.status == .settled && $0.settlementID == settlement.id })
    }

    @Test func settlementWindowRestartsAfterEachRun() async throws {
        let clock = TestClock()
        let ledger = try makeLedger(clock: clock)
        let start = clock.now
        #expect(try await ledger.nextSettlementDate() == start.addingTimeInterval(300))

        clock.advance(by: 300)
        try await ledger.settleIfDue()
        #expect(try await ledger.nextSettlementDate() == start.addingTimeInterval(600))

        try await ledger.pay(amount: 100)
        clock.advance(by: 300)
        #expect(try await ledger.settleIfDue()?.transactionCount == 1)
        #expect(try await ledger.settlements().count == 1)
    }

    @Test func nothingSettlesWhenNothingIsPending() async throws {
        let ledger = try makeLedger()
        #expect(try await ledger.settleNow() == nil)
        #expect(try await ledger.settlements().isEmpty)
        #expect(try await ledger.merchantAccount().balance == 0)
    }

    @Test func resetRestoresSeedState() async throws {
        let ledger = try makeLedger()
        try await ledger.pay(amount: 1000)
        try await ledger.settleNow()
        try await ledger.pay(amount: 50)

        try await ledger.reset()
        #expect(try await ledger.customerAccount().balance == 5000)
        #expect(try await ledger.merchantAccount().balance == 0)
        #expect(try await ledger.transactions().isEmpty)
        #expect(try await ledger.settlements().isEmpty)
    }

    @Test func dataPersistsAcrossInstances() async throws {
        let storeName = "LedgerTests-\(UUID().uuidString)"
        let configuration = LedgerConfiguration(storeName: storeName, simulatedLatency: .zero)
        defer {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            for suffix in ["sqlite", "sqlite-shm", "sqlite-wal"] {
                try? FileManager.default.removeItem(at: directory.appending(path: "\(storeName).\(suffix)"))
            }
        }

        try await Ledger(configuration: configuration).pay(amount: 250)
        let reopened = try Ledger(configuration: configuration)
        #expect(try await reopened.customerAccount().balance == 4750)
        #expect(try await reopened.transactions().count == 1)
    }
}
