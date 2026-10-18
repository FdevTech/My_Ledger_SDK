import CoreData

@objc(AccountEntity)
final class AccountEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var role: String
    @NSManaged var name: String
    @NSManaged var balanceMinor: Int64
}

@objc(TransactionEntity)
final class TransactionEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var amountMinor: Int64
    @NSManaged var feeMinor: Int64
    @NSManaged var netMinor: Int64
    @NSManaged var status: String
    @NSManaged var createdAt: Date
    @NSManaged var settledAt: Date?
    @NSManaged var settlementID: UUID?
}

@objc(SettlementEntity)
final class SettlementEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var executedAt: Date
    @NSManaged var transactionCount: Int64
    @NSManaged var grossMinor: Int64
    @NSManaged var feesMinor: Int64
    @NSManaged var netMinor: Int64
}

@objc(LedgerStateEntity)
final class LedgerStateEntity: NSManagedObject {
    @NSManaged var lastSettlementRunAt: Date
}

enum LedgerModel {
    static let accountEntity = "Account"
    static let transactionEntity = "LedgerTransaction"
    static let settlementEntity = "Settlement"
    static let stateEntity = "LedgerState"

    nonisolated(unsafe) static let model: NSManagedObjectModel = {
        let model = NSManagedObjectModel()
        model.entities = [
            entity(accountEntity, AccountEntity.self, [
                attribute("id", .UUIDAttributeType),
                attribute("role", .stringAttributeType),
                attribute("name", .stringAttributeType),
                attribute("balanceMinor", .integer64AttributeType),
            ]),
            entity(transactionEntity, TransactionEntity.self, [
                attribute("id", .UUIDAttributeType),
                attribute("amountMinor", .integer64AttributeType),
                attribute("feeMinor", .integer64AttributeType),
                attribute("netMinor", .integer64AttributeType),
                attribute("status", .stringAttributeType),
                attribute("createdAt", .dateAttributeType),
                attribute("settledAt", .dateAttributeType, optional: true),
                attribute("settlementID", .UUIDAttributeType, optional: true),
            ]),
            entity(settlementEntity, SettlementEntity.self, [
                attribute("id", .UUIDAttributeType),
                attribute("executedAt", .dateAttributeType),
                attribute("transactionCount", .integer64AttributeType),
                attribute("grossMinor", .integer64AttributeType),
                attribute("feesMinor", .integer64AttributeType),
                attribute("netMinor", .integer64AttributeType),
            ]),
            entity(stateEntity, LedgerStateEntity.self, [
                attribute("lastSettlementRunAt", .dateAttributeType),
            ]),
        ]
        return model
    }()

    private static func entity(
        _ name: String,
        _ type: NSManagedObject.Type,
        _ properties: [NSAttributeDescription]
    ) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(type)
        entity.properties = properties
        return entity
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }
}
