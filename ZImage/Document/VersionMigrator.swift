import Foundation

nonisolated protocol VersionMigrator: Sendable {
    var fromSchema: Int { get }
    var toSchema: Int { get }
    func migrate(_ document: ZImgRawDocument) throws -> ZImgRawDocument
}

/// The app chain's current schema stays 1. Tests pass a different target and a fake migrator
/// without assigning `currentSchema`.
nonisolated enum VersionMigratorChain {
    static let currentSchema = 1

    static func migrate(
        _ document: ZImgRawDocument,
        to schema: Int = currentSchema,
        migrators: [any VersionMigrator] = []
    ) throws -> ZImgRawDocument {
        if document.schemaVersion > schema {
            throw ZImgError.schemaTooNew(document.schemaVersion)
        }
        var current = document
        while current.schemaVersion < schema {
            guard let migrator = migrators.first(where: { $0.fromSchema == current.schemaVersion }) else {
                throw ZImgError.migrationMissing(current.schemaVersion)
            }
            let migrated = try migrator.migrate(current)
            current = migrated
            if current.schemaVersion < migrator.toSchema {
                current.schemaVersion = migrator.toSchema
            }
            if current.schemaVersion <= document.schemaVersion {
                throw ZImgError.migrationMissing(current.schemaVersion)
            }
        }
        return current
    }
}

nonisolated enum ZImgError: Error, Equatable, LocalizedError {
    case badMagic
    case truncated
    case schemaTooNew(Int)
    case migrationMissing(Int)
    case hashMismatch
    case needsLocate
    case cannotSave(String)

    var errorDescription: String? {
        switch self {
        case .badMagic:
            return "This is not a ZImage document."
        case .truncated:
            return "The ZImage document is incomplete."
        case .schemaTooNew(let schema):
            return "This document uses schema \(schema), which is newer than this version of ZImage. The file was not changed."
        case .migrationMissing(let schema):
            return "No migrator is available for schema \(schema)."
        case .hashMismatch:
            return "The photo on disk does not match this document. The edits were not applied."
        case .needsLocate:
            return "The original photo could not be found. Locate it to open the edits."
        case .cannotSave(let message):
            return message
        }
    }
}
