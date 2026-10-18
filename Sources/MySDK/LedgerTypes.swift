import Foundation

public enum AccountRole: String, Sendable, CaseIterable {
    case customer
    case merchant
}

public struct AccountSnapshot: Sendable, Equatable {
    public let id: UUID
    public let role: AccountRole
    public let name: String
    public let balance: Decimal
    public let pendingBalance: Decimal
}

public enum TransactionStatus: String, Sendable {
    case pending
    case settled
}

public struct TransactionRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let amount: Decimal
    public let fee: Decimal
    public let netAmount: Decimal
    public let status: TransactionStatus
    public let createdAt: Date
    public let settledAt: Date?
    public let settlementID: UUID?
}

public struct SettlementRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let executedAt: Date
    public let transactionCount: Int
    public let grossAmount: Decimal
    public let totalFees: Decimal
    public let netAmount: Decimal
}

public enum LedgerError: LocalizedError, Equatable, Sendable {
    case invalidAmount
    case insufficientFunds(available: Decimal, requested: Decimal)
    case accountNotFound(AccountRole)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAmount:
            "Enter an amount greater than 0 with at most 2 decimal places."
        case let .insufficientFunds(available, requested):
            "Insufficient funds: you tried to pay \(Money.format(requested)) but only \(Money.format(available)) is available."
        case let .accountNotFound(role):
            "The \(role.rawValue) account could not be found."
        case let .persistence(message):
            "The ledger could not be saved: \(message)"
        }
    }
}

public struct LedgerConfiguration: Sendable {
    public var feeRate: Decimal
    public var settlementInterval: TimeInterval
    public var initialCustomerBalance: Decimal
    public var inMemory: Bool
    public var storeName: String
    public var simulatedLatency: Duration
    public var now: @Sendable () -> Date

    public init(
        feeRate: Decimal = Decimal(string: "0.015")!,
        settlementInterval: TimeInterval = 5 * 60,
        initialCustomerBalance: Decimal = 5000,
        inMemory: Bool = false,
        storeName: String = "MySDKLedger",
        simulatedLatency: Duration = .milliseconds(400),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.feeRate = feeRate
        self.settlementInterval = settlementInterval
        self.initialCustomerBalance = initialCustomerBalance
        self.inMemory = inMemory
        self.storeName = storeName
        self.simulatedLatency = simulatedLatency
        self.now = now
    }

    public static let `default` = LedgerConfiguration()
}

public enum Money {
    public static let currencyCode = "DZD"

    public static func format(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: currencyCode))
    }

    static func minorUnits(_ amount: Decimal) -> Int64? {
        var scaled = amount * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil }
        let number = NSDecimalNumber(decimal: rounded)
        guard number.compare(NSDecimalNumber(value: Int64.max)) == .orderedAscending else { return nil }
        return number.int64Value
    }

    static func decimal(_ minor: Int64) -> Decimal {
        Decimal(minor) / 100
    }

    static func fee(onMinor amountMinor: Int64, rate: Decimal) -> Int64 {
        var raw = Decimal(amountMinor) * rate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}
