import CoreData
import Foundation

public actor Ledger {
    public static let didChangeNotification = Notification.Name("MySDK.LedgerDidChange")

    public nonisolated let configuration: LedgerConfiguration
    private let persistence: PersistenceController
    private var schedulerTask: Task<Void, Never>?

    public init(configuration: LedgerConfiguration = .default) throws {
        let persistence = try PersistenceController(
            inMemory: configuration.inMemory,
            storeName: configuration.storeName
        )
        try persistence.performAndWait { context in
            try Store.seedIfNeeded(in: context, configuration: configuration)
        }
        self.configuration = configuration
        self.persistence = persistence
    }

    deinit {
        schedulerTask?.cancel()
    }

    @discardableResult
    public func pay(amount: Decimal) async throws -> TransactionRecord {
        guard amount > 0, let amountMinor = Money.minorUnits(amount), amountMinor > 0 else {
            throw LedgerError.invalidAmount
        }
        if configuration.simulatedLatency > .zero {
            try await Task.sleep(for: configuration.simulatedLatency)
        }

        let feeMinor = Money.fee(onMinor: amountMinor, rate: configuration.feeRate)
        let now = configuration.now()
        let record = try await persistence.perform { context in
            let customer = try Store.account(.customer, in: context)
            guard customer.balanceMinor >= amountMinor else {
                throw LedgerError.insufficientFunds(
                    available: Money.decimal(customer.balanceMinor),
                    requested: amount
                )
            }
            customer.balanceMinor -= amountMinor

            let transaction = TransactionEntity(context: context)
            transaction.id = UUID()
            transaction.amountMinor = amountMinor
            transaction.feeMinor = feeMinor
            transaction.netMinor = amountMinor - feeMinor
            transaction.status = TransactionStatus.pending.rawValue
            transaction.createdAt = now
            return TransactionRecord(transaction)
        }
        notifyChange()
        return record
    }

    public func customerAccount() async throws -> AccountSnapshot {
        try await account(.customer)
    }

    public func merchantAccount() async throws -> AccountSnapshot {
        try await account(.merchant)
    }

    public func account(_ role: AccountRole) async throws -> AccountSnapshot {
        try await persistence.perform { context in
            let account = try Store.account(role, in: context)
            let pending = role == .merchant ? try Store.pendingNetMinor(in: context) : 0
            return AccountSnapshot(
                id: account.id,
                role: role,
                name: account.name,
                balance: Money.decimal(account.balanceMinor),
                pendingBalance: Money.decimal(pending)
            )
        }
    }

    public func transactions() async throws -> [TransactionRecord] {
        try await persistence.perform { context in
            let request = NSFetchRequest<TransactionEntity>(entityName: LedgerModel.transactionEntity)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            return try context.fetch(request).map(TransactionRecord.init)
        }
    }

    public func settlements() async throws -> [SettlementRecord] {
        try await persistence.perform { context in
            let request = NSFetchRequest<SettlementEntity>(entityName: LedgerModel.settlementEntity)
            request.sortDescriptors = [NSSortDescriptor(key: "executedAt", ascending: false)]
            return try context.fetch(request).map(SettlementRecord.init)
        }
    }

    public func nextSettlementDate() async throws -> Date {
        let interval = configuration.settlementInterval
        return try await persistence.perform { context in
            try Store.state(in: context).lastSettlementRunAt.addingTimeInterval(interval)
        }
    }

    @discardableResult
    public func settleIfDue() async throws -> SettlementRecord? {
        let now = configuration.now()
        let interval = configuration.settlementInterval
        let (due, settlement) = try await persistence.perform { context in
            let state = try Store.state(in: context)
            guard now >= state.lastSettlementRunAt.addingTimeInterval(interval) else {
                return (false, SettlementRecord?.none)
            }
            return (true, try Store.settle(in: context, at: now))
        }
        if due { notifyChange() }
        return settlement
    }

    @discardableResult
    public func settleNow() async throws -> SettlementRecord? {
        let now = configuration.now()
        let settlement = try await persistence.perform { context in
            try Store.settle(in: context, at: now)
        }
        notifyChange()
        return settlement
    }

    public func startSettlementScheduler() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.schedulerTick()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    public func stopSettlementScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    private func schedulerTick() async -> TimeInterval {
        _ = try? await settleIfDue()
        guard let next = try? await nextSettlementDate() else { return 1 }
        return max(0.25, next.timeIntervalSince(configuration.now()))
    }

    public func reset() async throws {
        let configuration = self.configuration
        try await persistence.perform { context in
            try Store.reset(in: context, configuration: configuration)
        }
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

private enum Store {
    static func seedIfNeeded(in context: NSManagedObjectContext, configuration: LedgerConfiguration) throws {
        let request = NSFetchRequest<AccountEntity>(entityName: LedgerModel.accountEntity)
        guard try context.count(for: request) == 0 else { return }
        try reset(in: context, configuration: configuration)
    }

    static func reset(in context: NSManagedObjectContext, configuration: LedgerConfiguration) throws {
        for entityName in [LedgerModel.transactionEntity, LedgerModel.settlementEntity] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            try context.fetch(request).forEach(context.delete)
        }

        guard let customerMinor = Money.minorUnits(configuration.initialCustomerBalance) else {
            throw LedgerError.invalidAmount
        }
        account(.customer, in: context, name: "Customer").balanceMinor = customerMinor
        account(.merchant, in: context, name: "Merchant").balanceMinor = 0

        let stateRequest = NSFetchRequest<LedgerStateEntity>(entityName: LedgerModel.stateEntity)
        let state = try context.fetch(stateRequest).first ?? LedgerStateEntity(context: context)
        state.lastSettlementRunAt = configuration.now()
    }

    static func account(_ role: AccountRole, in context: NSManagedObjectContext) throws -> AccountEntity {
        guard let account = try fetchAccount(role, in: context) else {
            throw LedgerError.accountNotFound(role)
        }
        return account
    }

    static func state(in context: NSManagedObjectContext) throws -> LedgerStateEntity {
        let request = NSFetchRequest<LedgerStateEntity>(entityName: LedgerModel.stateEntity)
        guard let state = try context.fetch(request).first else {
            throw LedgerError.persistence("Missing ledger state.")
        }
        return state
    }

    static func pendingNetMinor(in context: NSManagedObjectContext) throws -> Int64 {
        try pendingTransactions(in: context, before: nil).reduce(0) { $0 + $1.netMinor }
    }

    static func settle(in context: NSManagedObjectContext, at now: Date) throws -> SettlementRecord? {
        try state(in: context).lastSettlementRunAt = now

        let pending = try pendingTransactions(in: context, before: now)
        guard !pending.isEmpty else { return nil }

        let settlement = SettlementEntity(context: context)
        settlement.id = UUID()
        settlement.executedAt = now
        settlement.transactionCount = Int64(pending.count)
        settlement.grossMinor = pending.reduce(0) { $0 + $1.amountMinor }
        settlement.feesMinor = pending.reduce(0) { $0 + $1.feeMinor }
        settlement.netMinor = pending.reduce(0) { $0 + $1.netMinor }

        for transaction in pending {
            transaction.status = TransactionStatus.settled.rawValue
            transaction.settledAt = now
            transaction.settlementID = settlement.id
        }
        try account(.merchant, in: context).balanceMinor += settlement.netMinor
        return SettlementRecord(settlement)
    }

    private static func pendingTransactions(in context: NSManagedObjectContext, before date: Date?) throws -> [TransactionEntity] {
        let request = NSFetchRequest<TransactionEntity>(entityName: LedgerModel.transactionEntity)
        var predicates = [NSPredicate(format: "status == %@", TransactionStatus.pending.rawValue)]
        if let date {
            predicates.append(NSPredicate(format: "createdAt <= %@", date as NSDate))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return try context.fetch(request)
    }

    private static func fetchAccount(_ role: AccountRole, in context: NSManagedObjectContext) throws -> AccountEntity? {
        let request = NSFetchRequest<AccountEntity>(entityName: LedgerModel.accountEntity)
        request.predicate = NSPredicate(format: "role == %@", role.rawValue)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func account(_ role: AccountRole, in context: NSManagedObjectContext, name: String) -> AccountEntity {
        if let existing = try? fetchAccount(role, in: context) {
            return existing
        }
        let account = AccountEntity(context: context)
        account.id = UUID()
        account.role = role.rawValue
        account.name = name
        return account
    }
}

extension TransactionRecord {
    init(_ entity: TransactionEntity) {
        self.init(
            id: entity.id,
            amount: Money.decimal(entity.amountMinor),
            fee: Money.decimal(entity.feeMinor),
            netAmount: Money.decimal(entity.netMinor),
            status: TransactionStatus(rawValue: entity.status) ?? .pending,
            createdAt: entity.createdAt,
            settledAt: entity.settledAt,
            settlementID: entity.settlementID
        )
    }
}

extension SettlementRecord {
    init(_ entity: SettlementEntity) {
        self.init(
            id: entity.id,
            executedAt: entity.executedAt,
            transactionCount: Int(entity.transactionCount),
            grossAmount: Money.decimal(entity.grossMinor),
            totalFees: Money.decimal(entity.feesMinor),
            netAmount: Money.decimal(entity.netMinor)
        )
    }
}
