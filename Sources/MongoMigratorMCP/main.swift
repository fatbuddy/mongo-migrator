import Foundation
import Security

typealias Object = [String: Any]

enum MCPError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return "Unknown error"
    }
}

struct ConnectionProfile: Codable {
    let id: UUID
    let name: String
    let environment: String
    let connectionString: String
    let username: String
    let authenticationDatabase: String
    let usesPassword: Bool
}

enum SharedStore {
    static let keychainService = "com.team.MongoMigrator"

    static func profiles() throws -> [ConnectionProfile] {
        let defaults = UserDefaults(suiteName: "com.team.MongoMigrator") ?? .standard
        guard let data = defaults.data(forKey: "profiles") else { return [] }
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    static func profile(_ reference: String) throws -> ConnectionProfile {
        let profiles = try profiles()
        if let id = UUID(uuidString: reference), let profile = profiles.first(where: { $0.id == id }) { return profile }
        let matches = profiles.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        guard matches.count == 1, let profile = matches.first else {
            throw MCPError.message(matches.isEmpty ? "Unknown saved profile: \(reference)" : "Profile name is ambiguous; use its UUID.")
        }
        return profile
    }

    static func password(for id: UUID) throws -> String {
        let query: Object = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw MCPError.message("Unable to read the profile credential from macOS Keychain (\(status)).") }
        return String(decoding: data, as: UTF8.self)
    }

    static func audit(tool: String, status: String) {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = root.appendingPathComponent("Mongo Migrator", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("mcp-audit.jsonl")
            let record: Object = ["timestamp": ISO8601DateFormatter().string(from: Date()), "tool": tool, "status": status]
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            FileHandle.standardError.write(Data("MongoMigratorMCP audit error: \(error.localizedDescription)\n".utf8))
        }
    }
}

final class MongoShell {
    private let marker = "__MONGO_MIGRATOR_MCP__"

    func listDatabases(profile: ConnectionProfile) throws -> [Any] {
        try run(profile: profile, database: "admin", input: [:], body: """
        return connection.getSiblingDB('admin').runCommand({listDatabases: 1, nameOnly: true}).databases.map(item => item.name).sort();
        """) as? [Any] ?? []
    }

    func listCollections(profile: ConnectionProfile, database: String) throws -> [Any] {
        try run(profile: profile, database: database, input: [:], body: "return database.getCollectionNames().sort();") as? [Any] ?? []
    }

    func documents(profile: ConnectionProfile, database: String, collection: String, filter: Object, limit: Int) throws -> [Any] {
        let value = try run(profile: profile, database: database, input: ["collection": collection, "filter": filter, "limit": limit], body: """
        return database.getCollection(input.collection).find(input.filter || {}).limit(input.limit).toArray();
        """)
        return value as? [Any] ?? []
    }

    func schema(profile: ConnectionProfile, database: String, collection: String) throws -> Object {
        let value = try run(profile: profile, database: database, input: ["collection": collection], body: """
        const info = database.getCollectionInfos({name: input.collection})[0] || {options: {}};
        return {
          validator: info.options.validator || {},
          indexes: database.getCollection(input.collection).getIndexes().filter(index => index.name !== '_id_')
        };
        """)
        return value as? Object ?? [:]
    }

    func apply(profile: ConnectionProfile, database: String, operations: [Object]) throws -> Object {
        let value = try run(profile: profile, database: database, input: ["operations": operations], body: """
        const results = {inserted: 0, updated: 0, deleted: 0, validators: 0, indexes: 0};
        for (const op of input.operations) {
          const collection = database.getCollection(op.collection);
          if (op.action === 'insert') {
            collection.insertOne(op.document); results.inserted++;
          } else if (op.action === 'update') {
            const change = {};
            if (Object.keys(op.set || {}).length) change.$set = op.set;
            if ((op.unset || []).length) change.$unset = Object.fromEntries(op.unset.map(path => [path, '']));
            if (Object.keys(change).length) { collection.updateOne(op.filter, change); results.updated++; }
          } else if (op.action === 'delete') {
            collection.deleteOne(op.filter); results.deleted++;
          } else if (op.action === 'validator') {
            database.runCommand({collMod: op.collection, validator: op.validator}); results.validators++;
          } else if (op.action === 'index') {
            const options = {...op.index}; const key = options.key;
            delete options.key; delete options.v; delete options.ns;
            collection.createIndex(key, options); results.indexes++;
          }
        }
        return results;
        """)
        return value as? Object ?? [:]
    }

    private func run(profile: ConnectionProfile, database: String, input: Object, body: String) throws -> Any {
        guard let executable = ["/opt/homebrew/bin/mongosh", "/usr/local/bin/mongosh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MCPError.message("mongosh is required. Install it with: brew install mongosh")
        }
        let password = profile.usesPassword ? try SharedStore.password(for: profile.id) : ""
        let uri = try connectionURI(profile: profile, password: password)
        let script = """
        const fs = require('fs'); const marker = '\(marker)';
        try {
          const input = EJSON.parse(fs.readFileSync(0, 'utf8') || '{}');
          const connection = connect(process.env.MONGO_MIGRATOR_URI);
          const database = connection.getSiblingDB(process.env.MONGO_MIGRATOR_DATABASE);
          const execute = () => { \(body) };
          print(marker + EJSON.stringify({ok: true, value: execute()}, {relaxed: false}));
        } catch (error) {
          print(marker + EJSON.stringify({ok: false, error: error.message || String(error)}, {relaxed: true}));
        }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--quiet", "--norc", "--eval", script]
        var environment = ProcessInfo.processInfo.environment
        environment["MONGO_MIGRATOR_URI"] = uri
        environment["MONGO_MIGRATOR_DATABASE"] = database
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: input))
        try stdin.fileHandleForWriting.close()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)
        let errorOutput = String(decoding: errorData, as: UTF8.self)
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else {
            throw MCPError.message(errorOutput.isEmpty ? output : errorOutput)
        }
        let payload = Data(line.dropFirst(marker.count).utf8)
        guard let response = try JSONSerialization.jsonObject(with: payload) as? Object else { throw MCPError.message("Invalid mongosh response.") }
        guard response["ok"] as? Bool == true else { throw MCPError.message(response["error"] as? String ?? "MongoDB operation failed.") }
        return response["value"] ?? NSNull()
    }

    private func connectionURI(profile: ConnectionProfile, password: String) throws -> String {
        let uri = profile.connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard uri.hasPrefix("mongodb://") || uri.hasPrefix("mongodb+srv://") else { throw MCPError.message("Invalid MongoDB connection string in profile \(profile.name).") }
        guard !profile.username.isEmpty else { return uri }
        let schemeEnd = uri.range(of: "://")!.upperBound
        let prefix = String(uri[..<schemeEnd])
        var remainder = String(uri[schemeEnd...])
        if let at = remainder.firstIndex(of: "@") { remainder = String(remainder[remainder.index(after: at)...]) }
        let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@/"))
        let user = profile.username.addingPercentEncoding(withAllowedCharacters: allowed) ?? profile.username
        let secret = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        var result = "\(prefix)\(user):\(secret)@\(remainder)"
        if !profile.authenticationDatabase.isEmpty, !result.contains("authSource=") {
            result += result.contains("?") ? "&" : "?"
            result += "authSource=\(profile.authenticationDatabase.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "admin")"
        }
        return result
    }
}

struct Difference {
    let collection: String
    let identity: String
    let filter: Object
    let source: Any?
    let destination: Any?
    let kind: String
    let fields: [Object]

    var json: Object {
        [
            "collection": collection,
            "identity": identity,
            "filter": filter,
            "kind": kind,
            "changedFields": fields
        ]
    }
}

enum Comparator {
    static func compare(collection: String, source: [Any], destination: [Any], keyFields: [String], ignoredFields: [String]) -> [Difference] {
        var left: [String: Any] = [:], right: [String: Any] = [:]
        for document in source { if let key = identity(document, fields: keyFields), left[key] == nil { left[key] = document } }
        for document in destination { if let key = identity(document, fields: keyFields), right[key] == nil { right[key] = document } }
        return Set(left.keys).union(right.keys).sorted().compactMap { key in
            let sourceDocument = left[key], destinationDocument = right[key]
            let filter = Dictionary(uniqueKeysWithValues: keyFields.compactMap { path in value(at: path, in: sourceDocument ?? destinationDocument).map { (path, $0) } })
            if let sourceDocument, let destinationDocument {
                let fields = fieldDifferences(source: sourceDocument, destination: destinationDocument, ignored: ignoredFields)
                return fields.isEmpty ? nil : Difference(collection: collection, identity: key, filter: filter, source: sourceDocument, destination: destinationDocument, kind: "changed", fields: fields)
            }
            if let sourceDocument {
                return Difference(collection: collection, identity: key, filter: filter, source: sourceDocument, destination: nil, kind: "only_in_source", fields: fieldDifferences(source: sourceDocument, destination: nil, ignored: ignoredFields))
            }
            if let destinationDocument {
                return Difference(collection: collection, identity: key, filter: filter, source: nil, destination: destinationDocument, kind: "only_in_destination", fields: fieldDifferences(source: nil, destination: destinationDocument, ignored: ignoredFields))
            }
            return nil
        }
    }

    static func schemaOperations(collection: String, source: Object, destination: Object, validators: Bool, indexes: Bool) -> [Object] {
        var operations: [Object] = []
        if validators, !equal(source["validator"], destination["validator"]), let validator = source["validator"] {
            operations.append(["collection": collection, "action": "validator", "validator": validator])
        }
        if indexes, let sourceIndexes = source["indexes"] as? [Any] {
            let destinationIndexes = destination["indexes"] as? [Any] ?? []
            for index in sourceIndexes {
                guard let object = index as? Object, let name = object["name"] as? String else { continue }
                let matching = destinationIndexes.first { ($0 as? Object)?["name"] as? String == name }
                if !equal(index, matching) { operations.append(["collection": collection, "action": "index", "index": index]) }
            }
        }
        return operations
    }

    private static func identity(_ document: Any, fields: [String]) -> String? {
        let parts = fields.compactMap { path -> String? in value(at: path, in: document).map { "\(path)=\(canonical($0))" } }
        return parts.count == fields.count ? parts.joined(separator: " • ") : nil
    }

    private static func fieldDifferences(source: Any?, destination: Any?, ignored: [String]) -> [Object] {
        let left = flatten(source), right = flatten(destination)
        return Set(left.keys).union(right.keys).sorted().compactMap { path in
            guard !ignored.contains(where: { path == $0 || path.hasPrefix($0 + ".") }), !equal(left[path], right[path]) else { return nil }
            return ["path": path, "source": left[path] ?? NSNull(), "destination": right[path] ?? NSNull()]
        }
    }

    private static func flatten(_ value: Any?, prefix: String = "") -> [String: Any] {
        guard let value else { return [:] }
        if let object = value as? Object {
            var result: [String: Any] = [:]
            for (key, child) in object {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                if child is Object { result.merge(flatten(child, prefix: path)) { _, new in new } }
                else { result[path] = child }
            }
            return result
        }
        return [prefix: value]
    }

    static func value(at path: String, in document: Any?) -> Any? {
        var current = document
        for component in path.split(separator: ".").map(String.init) {
            guard let object = current as? Object, let next = object[component] else { return nil }
            current = next
        }
        return current
    }

    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool { canonical(lhs) == canonical(rhs) }

    static func canonical(_ value: Any?) -> String {
        guard let value else { return "<missing>" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}

struct MigrationPlan {
    let id: String
    let confirmation: String
    let destination: ConnectionProfile
    let database: String
    let operations: [Object]
    let backup: Object
    let expiresAt: Date
}

final class MCPServer {
    private let shell = MongoShell()
    private var plans: [String: MigrationPlan] = [:]
    private let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    func run() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? Object else { continue }
            guard let id = request["id"] else { continue }
            let method = request["method"] as? String ?? ""
            do {
                let result: Object
                switch method {
                case "initialize": result = initialize(request["params"] as? Object ?? [:])
                case "ping": result = [:]
                case "tools/list": result = ["tools": tools]
                case "tools/call": result = try call(request["params"] as? Object ?? [:])
                default: throw MCPError.message("Unknown MCP method: \(method)")
                }
                send(["jsonrpc": "2.0", "id": id, "result": result])
            } catch {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": error.localizedDescription]])
            }
        }
    }

    private func initialize(_ params: Object) -> Object {
        let requested = params["protocolVersion"] as? String ?? supportedVersions[0]
        let version = supportedVersions.contains(requested) ? requested : supportedVersions[0]
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "mongo-migrator", "title": "Mongo Migrator", "version": "0.2.0", "description": "Compare and safely migrate MongoDB documents and schema using profiles saved by the Mongo Migrator macOS app."],
            "instructions": "Use read-only comparison tools first. Writes require prepare_migration followed by apply_migration with the exact confirmation string and host/user approval."
        ]
    }

    private func call(_ params: Object) throws -> Object {
        guard let name = params["name"] as? String else { throw MCPError.message("Missing tool name.") }
        let arguments = params["arguments"] as? Object ?? [:]
        do {
            let value: Any
            switch name {
            case "mongo_list_profiles": value = try listProfiles()
            case "mongo_list_databases": value = try listDatabases(arguments)
            case "mongo_list_collections": value = try listCollections(arguments)
            case "mongo_find_documents": value = try findDocuments(arguments)
            case "mongo_compare": value = try compare(arguments)
            case "mongo_prepare_migration": value = try prepare(arguments)
            case "mongo_apply_migration": value = try apply(arguments)
            default: throw MCPError.message("Unknown tool: \(name)")
            }
            SharedStore.audit(tool: name, status: "success")
            return toolResult(value, isError: false)
        } catch {
            SharedStore.audit(tool: name, status: "error: \(error.localizedDescription)")
            return toolResult(["error": error.localizedDescription], isError: true)
        }
    }

    private func listProfiles() throws -> Any {
        try SharedStore.profiles().map { ["id": $0.id.uuidString, "name": $0.name, "environment": $0.environment, "authentication": $0.usesPassword ? "username_password" : "none"] }
    }

    private func listDatabases(_ args: Object) throws -> Any { try shell.listDatabases(profile: SharedStore.profile(requiredString("profile", args))) }

    private func listCollections(_ args: Object) throws -> Any {
        try shell.listCollections(profile: SharedStore.profile(requiredString("profile", args)), database: requiredString("database", args))
    }

    private func findDocuments(_ args: Object) throws -> Any {
        let limit = validatedLimit(args["limit"] as? Int ?? 100)
        return try shell.documents(profile: SharedStore.profile(requiredString("profile", args)), database: requiredString("database", args), collection: requiredString("collection", args), filter: args["filter"] as? Object ?? [:], limit: limit)
    }

    private func compare(_ args: Object) throws -> Any {
        let result = try comparison(args)
        return ["documentDifferences": result.differences.map(\.json), "schemaDifferences": result.schemaOperations]
    }

    private func comparison(_ args: Object) throws -> (source: ConnectionProfile, destination: ConnectionProfile, sourceDatabase: String, destinationDatabase: String, differences: [Difference], schemaOperations: [Object], schemaBackup: [Object]) {
        let source = try SharedStore.profile(requiredString("sourceProfile", args))
        let destination = try SharedStore.profile(requiredString("destinationProfile", args))
        let sourceDatabase = try requiredString("sourceDatabase", args), destinationDatabase = try requiredString("destinationDatabase", args)
        guard let collections = args["collections"] as? [String], !collections.isEmpty else { throw MCPError.message("collections must contain at least one collection name.") }
        let keyFields = args["keyFields"] as? [String] ?? ["_id"]
        guard !keyFields.isEmpty else { throw MCPError.message("keyFields must contain at least one field path.") }
        let ignored = args["ignoredFields"] as? [String] ?? []
        let filter = args["filter"] as? Object ?? [:]
        let limit = validatedLimit(args["limit"] as? Int ?? 100)
        let includeDocuments = args["includeDocuments"] as? Bool ?? true
        let includeValidators = args["includeValidators"] as? Bool ?? false
        let includeIndexes = args["includeIndexes"] as? Bool ?? false
        var differences: [Difference] = [], schemaOperations: [Object] = [], schemaBackup: [Object] = []
        for collection in collections {
            if includeDocuments {
                let left = try shell.documents(profile: source, database: sourceDatabase, collection: collection, filter: filter, limit: limit)
                let right = try shell.documents(profile: destination, database: destinationDatabase, collection: collection, filter: filter, limit: limit)
                differences += Comparator.compare(collection: collection, source: left, destination: right, keyFields: keyFields, ignoredFields: ignored)
            }
            if includeValidators || includeIndexes {
                let left = try shell.schema(profile: source, database: sourceDatabase, collection: collection)
                let right = try shell.schema(profile: destination, database: destinationDatabase, collection: collection)
                let operations = Comparator.schemaOperations(collection: collection, source: left, destination: right, validators: includeValidators, indexes: includeIndexes)
                if !operations.isEmpty {
                    schemaOperations += operations
                    schemaBackup.append(["collection": collection, "schema": right])
                }
            }
        }
        return (source, destination, sourceDatabase, destinationDatabase, differences, schemaOperations, schemaBackup)
    }

    private func prepare(_ args: Object) throws -> Any {
        let comparison = try comparison(args)
        let requestedActions = args["documentActions"] as? [Object] ?? []
        var actionMap: [String: Object] = [:]
        for action in requestedActions {
            guard let collection = action["collection"] as? String, let identity = action["identity"] as? String else { continue }
            actionMap["\(collection)\u{0}\(identity)"] = action
        }
        var operations: [Object] = [], backups: [Object] = []
        for difference in comparison.differences {
            let requested = actionMap["\(difference.collection)\u{0}\(difference.identity)"]
            let defaultAction = difference.source == nil ? "keep_destination" : "apply_source"
            let action = requested?["action"] as? String ?? defaultAction
            switch action {
            case "keep_destination": continue
            case "delete_destination":
                operations.append(["collection": difference.collection, "action": "delete", "filter": difference.filter])
            case "apply_source":
                guard let source = difference.source else { throw MCPError.message("Cannot apply source for \(difference.identity): the source document does not exist.") }
                if difference.destination == nil {
                    operations.append(["collection": difference.collection, "action": "insert", "document": source])
                } else {
                    let selected = Set(requested?["selectedPaths"] as? [String] ?? difference.fields.compactMap { $0["path"] as? String })
                    var set: Object = [:], unset: [String] = []
                    for field in difference.fields {
                        guard let path = field["path"] as? String, selected.contains(path) else { continue }
                        if let value = Comparator.value(at: path, in: source) { set[path] = value } else { unset.append(path) }
                    }
                    operations.append(["collection": difference.collection, "action": "update", "filter": difference.filter, "set": set, "unset": unset])
                }
            default: throw MCPError.message("Unsupported migration action: \(action)")
            }
            backups.append(["collection": difference.collection, "filter": difference.filter, "destinationDocument": difference.destination ?? NSNull()])
        }
        operations += comparison.schemaOperations
        let id = String(UUID().uuidString.prefix(12)).lowercased()
        let hasDeletes = operations.contains { $0["action"] as? String == "delete" }
        let confirmation = hasDeletes ? "DELETE AND APPLY \(id)" : "APPLY \(id)"
        let backup: Object = ["createdAt": ISO8601DateFormatter().string(from: Date()), "destinationProfile": comparison.destination.name, "destinationDatabase": comparison.destinationDatabase, "documents": backups, "schemas": comparison.schemaBackup]
        plans[id] = MigrationPlan(id: id, confirmation: confirmation, destination: comparison.destination, database: comparison.destinationDatabase, operations: operations, backup: backup, expiresAt: Date().addingTimeInterval(1800))
        let counts = Dictionary(grouping: operations, by: { $0["action"] as? String ?? "unknown" }).mapValues(\.count)
        return ["planId": id, "expiresInSeconds": 1800, "confirmation": confirmation, "operationCounts": counts, "documentChanges": comparison.differences.map(\.json), "schemaChanges": comparison.schemaOperations]
    }

    private func apply(_ args: Object) throws -> Any {
        let id = try requiredString("planId", args), confirmation = try requiredString("confirmation", args)
        guard let plan = plans[id] else { throw MCPError.message("Unknown or already-applied migration plan.") }
        guard plan.expiresAt > Date() else { plans.removeValue(forKey: id); throw MCPError.message("Migration plan expired; prepare a new plan.") }
        guard confirmation == plan.confirmation else { throw MCPError.message("Confirmation does not match. Obtain explicit user approval and pass the exact confirmation returned by mongo_prepare_migration.") }
        let backupPath = try writeBackup(plan.backup, planID: plan.id)
        let result = try shell.apply(profile: plan.destination, database: plan.database, operations: plan.operations)
        plans.removeValue(forKey: id)
        return ["status": "completed", "result": result, "backupPath": backupPath]
    }

    private func writeBackup(_ backup: Object, planID: String) throws -> String {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("Mongo Migrator/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mcp-\(planID)-\(Int(Date().timeIntervalSince1970)).json")
        try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: [.atomic, .completeFileProtection])
        return url.path
    }

    private func requiredString(_ name: String, _ args: Object) throws -> String {
        guard let value = args[name] as? String, !value.isEmpty else { throw MCPError.message("Missing required argument: \(name)") }
        return value
    }

    private func validatedLimit(_ value: Int) -> Int { min(max(value, 1), 1000) }

    private func toolResult(_ value: Any, isError: Bool) -> Object {
        let structured: Object = value as? Object ?? ["result": value]
        let text = Comparator.canonical(structured)
        return ["content": [["type": "text", "text": text]], "structuredContent": structured, "isError": isError]
    }

    private func send(_ message: Object) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private var tools: [Object] {
        let readOnly: Object = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        let write: Object = ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false]
        let profileProperty: Object = ["type": "string", "description": "Saved profile name or UUID from mongo_list_profiles."]
        let compareProperties: Object = [
            "sourceProfile": profileProperty, "destinationProfile": profileProperty,
            "sourceDatabase": ["type": "string"], "destinationDatabase": ["type": "string"],
            "collections": ["type": "array", "items": ["type": "string"], "minItems": 1],
            "keyFields": ["type": "array", "items": ["type": "string"], "default": ["_id"]],
            "ignoredFields": ["type": "array", "items": ["type": "string"]],
            "filter": ["type": "object", "description": "MongoDB Extended JSON query filter."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 1000, "default": 100],
            "includeDocuments": ["type": "boolean", "default": true],
            "includeValidators": ["type": "boolean", "default": false],
            "includeIndexes": ["type": "boolean", "default": false]
        ]
        let compareRequired = ["sourceProfile", "destinationProfile", "sourceDatabase", "destinationDatabase", "collections"]
        return [
            tool("mongo_list_profiles", "List saved Mongo Migrator connection profiles without exposing connection strings or passwords.", [:], [], readOnly),
            tool("mongo_list_databases", "List databases available through a saved profile.", ["profile": profileProperty], ["profile"], readOnly),
            tool("mongo_list_collections", "List collections in a database.", ["profile": profileProperty, "database": ["type": "string"]], ["profile", "database"], readOnly),
            tool("mongo_find_documents", "Read documents using an optional MongoDB Extended JSON filter.", ["profile": profileProperty, "database": ["type": "string"], "collection": ["type": "string"], "filter": ["type": "object"], "limit": ["type": "integer", "minimum": 1, "maximum": 1000, "default": 100]], ["profile", "database", "collection"], readOnly),
            tool("mongo_compare", "Compare documents, validators, and indexes between saved source and destination profiles. This tool never writes data.", compareProperties, compareRequired, readOnly),
            tool("mongo_prepare_migration", "Prepare a short-lived migration plan and dry-run preview. No data is written. documentActions may choose apply_source, keep_destination, or delete_destination and selectedPaths for each document.", compareProperties.merging(["documentActions": ["type": "array", "items": ["type": "object", "properties": ["collection": ["type": "string"], "identity": ["type": "string"], "action": ["type": "string", "enum": ["apply_source", "keep_destination", "delete_destination"]], "selectedPaths": ["type": "array", "items": ["type": "string"]]], "required": ["collection", "identity", "action"]]]]) { _, new in new }, compareRequired, readOnly),
            tool("mongo_apply_migration", "Apply a prepared migration plan after explicit user approval. This writes to MongoDB, may delete documents, creates a rollback backup first, and consumes the plan.", ["planId": ["type": "string"], "confirmation": ["type": "string", "description": "Exact confirmation returned by mongo_prepare_migration after the user approves the preview."]], ["planId", "confirmation"], write)
        ]
    }

    private func tool(_ name: String, _ description: String, _ properties: Object, _ required: [String], _ annotations: Object) -> Object {
        ["name": name, "title": name.replacingOccurrences(of: "mongo_", with: "Mongo ").replacingOccurrences(of: "_", with: " ").capitalized, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false], "annotations": annotations]
    }
}

MCPServer().run()
