import CoreData

final class PersistenceController: @unchecked Sendable {
    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext

    init(inMemory: Bool, storeName: String) throws {
        container = NSPersistentContainer(name: storeName, managedObjectModel: LedgerModel.model)
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        }

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            throw LedgerError.persistence(loadError.localizedDescription)
        }

        context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }

    func perform<T: Sendable>(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = self.context
        return try await context.perform {
            do {
                let result = try block(context)
                if context.hasChanges {
                    try context.save()
                }
                return result
            } catch {
                context.rollback()
                if error is LedgerError { throw error }
                throw LedgerError.persistence(error.localizedDescription)
            }
        }
    }

    func performAndWait<T>(_ block: @Sendable (NSManagedObjectContext) throws -> T) throws -> T {
        try context.performAndWait {
            do {
                let result = try block(context)
                if context.hasChanges {
                    try context.save()
                }
                return result
            } catch {
                context.rollback()
                if error is LedgerError { throw error }
                throw LedgerError.persistence(error.localizedDescription)
            }
        }
    }
}
