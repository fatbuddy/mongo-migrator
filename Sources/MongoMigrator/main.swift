import SwiftUI
import Security
import AppKit

// MARK: - Models

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "New connection"
    var environment = "Development"
    var connectionString = "mongodb://localhost:27017"
    var username = ""
    var authenticationDatabase = "admin"
    var usesPassword = false

    var isProduction: Bool { environment.caseInsensitiveCompare("production") == .orderedSame }
}

enum JSONValue: Codable, Hashable, CustomStringConvertible {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .object(let value):
            if let data = try? JSONEncoder.pretty.encode(value), let text = String(data: data, encoding: .utf8) { return text }
            return "{}"
        case .array(let value):
            if let data = try? JSONEncoder.pretty.encode(value), let text = String(data: data, encoding: .utf8) { return text }
            return "[]"
        case .string(let value): return value
        case .number(let value): return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): return String(value)
        case .null: return "null"
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    func value(at path: String) -> JSONValue? {
        guard !path.isEmpty else { return self }
        var current = self
        for component in path.split(separator: ".").map(String.init) {
            guard case .object(let object) = current, let next = object[component] else { return nil }
            current = next
        }
        return current
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

enum MatchMode: String, CaseIterable, Identifiable, Codable {
    case objectID = "_id"
    case uniqueField = "Unique field"
    case compoundKey = "Compound key"
    var id: String { rawValue }
}

struct MongoUniqueIndex: Identifiable, Codable, Hashable {
    let name: String
    let fields: [String]
    let partialFilter: JSONValue?

    var id: String {
        fields.joined(separator: "\u{1F}") + "|" + (partialFilter?.description ?? "")
    }

    var displayName: String {
        let definition = fields.joined(separator: ", ")
        return partialFilter == nil ? "\(name) (\(definition))" : "\(name) (\(definition)) • partial"
    }
}

enum DifferenceKind: String, Codable {
    case added = "Only in source"
    case changed = "Changed"
    case removed = "Only in destination"
    case unchanged = "Unchanged"
}

enum MigrationAction: String, CaseIterable, Identifiable, Codable {
    case applySource = "Apply source"
    case keepDestination = "Keep destination"
    case deleteDestination = "Delete destination"
    var id: String { rawValue }
}

struct FieldDifference: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let source: JSONValue?
    let destination: JSONValue?
}

struct DocumentDifference: Identifiable {
    let id = UUID()
    let collection: String
    let identity: String
    let filter: JSONValue
    let source: JSONValue?
    let destination: JSONValue?
    let kind: DifferenceKind
    let fields: [FieldDifference]
    var action: MigrationAction
    var selectedPaths: Set<String>
}

struct HistoryEntry: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let source: String
    let destination: String
    let database: String
    let collections: [String]
    let dryRun: Bool
    let inserts: Int
    let updates: Int
    let deletions: Int
    let status: String
    var backupPath: String? = nil
    var destinationProfileID: UUID? = nil
    var sourceDatabaseName: String? = nil
    var destinationDatabaseName: String? = nil
    var detailsPath: String? = nil
    var revertedAt: Date? = nil
    var revertStatus: String? = nil
}

struct BackupDocument: Codable {
    let collection: String
    let filter: JSONValue
    let destinationDocument: JSONValue?
    let sourceDocument: JSONValue?
    let migrationAction: String?
    let selectedPaths: [String]?
}

struct MigrationBackup: Codable {
    let createdAt: Date
    let destinationProfile: String
    let destinationDatabase: String
    let documents: [BackupDocument]
    let destinationProfileID: UUID?
    let schemaOperations: [JSONValue]?
}

enum BackupStore {
    static func create(destination: ConnectionProfile, database: String, differences: [DocumentDifference], schemaOperations: [JSONValue] = []) throws -> String {
        let documents = differences.compactMap { difference -> BackupDocument? in
            guard difference.action != .keepDestination else { return nil }
            let migrationAction: String
            switch difference.action {
            case .keepDestination: return nil
            case .deleteDestination: migrationAction = "delete"
            case .applySource: migrationAction = difference.destination == nil ? "insert" : "update"
            }
            return BackupDocument(
                collection: difference.collection,
                filter: difference.filter,
                destinationDocument: difference.destination,
                sourceDocument: difference.source,
                migrationAction: migrationAction,
                selectedPaths: difference.selectedPaths.sorted()
            )
        }
        let backup = MigrationBackup(
            createdAt: Date(),
            destinationProfile: destination.name,
            destinationDatabase: database,
            documents: documents,
            destinationProfileID: destination.id,
            schemaOperations: schemaOperations
        )
        let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = applicationSupport.appendingPathComponent("Mongo Migrator/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let safeDate = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(8)
        let url = directory.appendingPathComponent("migration-\(safeDate)-\(suffix).json")
        try JSONEncoder.pretty.encode(backup).write(to: url, options: [.atomic, .completeFileProtection])
        return url.path
    }

    static func load(path: String) throws -> MigrationBackup {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(MigrationBackup.self, from: data)
    }
}

// MARK: - Secure persistence

enum KeychainStore {
    private static let service = "com.team.MongoMigrator"

    static func save(_ password: String, for profileID: UUID) throws {
        let account = profileID.uuidString
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppError.message("Keychain error: \(status)") }
    }

    static func read(for profileID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw AppError.message("Keychain error: \(status)") }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(for profileID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return "Unknown error"
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var profiles: [ConnectionProfile] = [] { didSet { saveProfiles() } }
    @Published var history: [HistoryEntry] = [] { didSet { saveHistory() } }
    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: "profiles"), let saved = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            profiles = saved
        }
        if let data = defaults.data(forKey: "history"), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = saved
        }
    }

    func addProfile() -> ConnectionProfile {
        let profile = ConnectionProfile()
        profiles.append(profile)
        return profile
    }

    func removeProfile(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        KeychainStore.delete(for: profile.id)
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "history") }
    }
}

// MARK: - Mongo shell bridge

struct ShellResponse: Decodable {
    let ok: Bool
    let value: JSONValue?
    let error: String?
}

actor MongoShellClient {
    private let marker = "__MONGO_MIGRATOR_RESULT__"

    func isAvailable() -> Bool {
        ["/opt/homebrew/bin/mongosh", "/usr/local/bin/mongosh"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func test(profile: ConnectionProfile) async throws -> [String] {
        let script = wrapped("""
            const admin = connection.getSiblingDB('admin');
            const names = admin.runCommand({listDatabases: 1, nameOnly: true}).databases.map(x => x.name).sort();
            return names;
        """)
        let value = try await run(profile: profile, database: nil, script: script)
        guard case .array(let items) = value else { return [] }
        return items.compactMap { if case .string(let name) = $0 { return name }; return nil }
    }

    func collections(profile: ConnectionProfile, database: String) async throws -> [String] {
        let script = wrapped("return database.getCollectionNames().sort();")
        let value = try await run(profile: profile, database: database, script: script)
        guard case .array(let items) = value else { return [] }
        return items.compactMap { if case .string(let name) = $0 { return name }; return nil }
    }

    func documents(profile: ConnectionProfile, database: String, collection: String, filter: String, partialFilter: JSONValue?, limit: Int) async throws -> [JSONValue] {
        let script = wrapped("""
            const baseQuery = input.filter ? EJSON.parse(input.filter) : {};
            const partialQuery = input.partialFilter || {};
            const query = Object.keys(partialQuery).length ? {$and: [baseQuery, partialQuery]} : baseQuery;
            return database.getCollection(input.collection).find(query).limit(input.limit).toArray();
        """)
        let input: JSONValue = .object([
            "filter": .string(filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : filter),
            "partialFilter": partialFilter ?? .object([:]),
            "collection": .string(collection),
            "limit": .number(Double(limit))
        ])
        let value = try await run(profile: profile, database: database, script: script, input: input)
        guard case .array(let items) = value else { return [] }
        return items
    }

    func uniqueIndexes(profile: ConnectionProfile, database: String, collection: String) async throws -> [MongoUniqueIndex] {
        let script = wrapped("""
            return database.getCollection(input.collection).getIndexes()
              .filter(index => index.name === '_id_' || index.unique === true);
        """)
        let value = try await run(
            profile: profile,
            database: database,
            script: script,
            input: .object(["collection": .string(collection)])
        )
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let object) = item,
                  case .string(let name) = object["name"],
                  case .object(let key) = object["key"] else { return nil }
            return MongoUniqueIndex(
                name: name,
                fields: key.keys.sorted(),
                partialFilter: object["partialFilterExpression"]
            )
        }
        .sorted { lhs, rhs in
            if lhs.name == "_id_" { return true }
            if rhs.name == "_id_" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func schema(profile: ConnectionProfile, database: String, collection: String) async throws -> JSONValue {
        let script = wrapped("""
            const info = database.getCollectionInfos({name: input.collection})[0] || {options: {}};
            const indexes = database.getCollection(input.collection).getIndexes().filter(index => index.name !== '_id_');
            return {validator: info.options.validator || {}, indexes};
        """)
        return try await run(profile: profile, database: database, script: script, input: .object(["collection": .string(collection)]))
    }

    func apply(profile: ConnectionProfile, database: String, operations: JSONValue) async throws -> JSONValue {
        let script = wrapped("""
            const results = {inserted: 0, updated: 0, deleted: 0};
            for (const op of input.operations) {
              const collection = database.getCollection(op.collection);
              if (op.action === 'insert') {
                collection.insertOne(op.document); results.inserted++;
              } else if (op.action === 'update') {
                const change = {};
                if (Object.keys(op.set || {}).length) change.$set = op.set;
                if ((op.unset || []).length) change.$unset = Object.fromEntries(op.unset.map(x => [x, '']));
                if (Object.keys(change).length) { collection.updateOne(op.filter, change); results.updated++; }
              } else if (op.action === 'delete') {
                collection.deleteOne(op.filter); results.deleted++;
              } else if (op.action === 'validator') {
                database.runCommand({collMod: op.collection, validator: op.validator});
              } else if (op.action === 'index') {
                const options = {...op.index};
                const key = options.key;
                delete options.key; delete options.v; delete options.ns;
                collection.createIndex(key, options);
              }
            }
            return results;
        """)
        return try await run(profile: profile, database: database, script: script, input: operations)
    }

    func restore(profile: ConnectionProfile, database: String, documents: [BackupDocument]) async throws -> JSONValue {
        let script = wrapped("""
            const results = {restored: 0, removed: 0};
            for (const item of input.documents) {
              const collection = database.getCollection(item.collection);
              if (item.hadDestinationDocument) {
                collection.replaceOne(item.filter, item.destinationDocument, {upsert: true});
                results.restored++;
              } else {
                collection.deleteOne(item.filter);
                results.removed++;
              }
            }
            return results;
        """)
        let values = documents.map { document -> JSONValue in
            .object([
                "collection": .string(document.collection),
                "filter": document.filter,
                "hadDestinationDocument": .bool(document.destinationDocument != nil),
                "destinationDocument": document.destinationDocument ?? .null
            ])
        }
        return try await run(
            profile: profile,
            database: database,
            script: script,
            input: .object(["documents": .array(values)])
        )
    }

    private func wrapped(_ body: String) -> String {
        """
        const fs = require('fs');
        const marker = '\(marker)';
        try {
          const raw = fs.readFileSync(0, 'utf8');
          const input = raw.length ? EJSON.parse(raw) : {};
          const connection = connect(process.env.MONGO_MIGRATOR_URI);
          const database = connection.getSiblingDB(process.env.MONGO_MIGRATOR_DATABASE || 'admin');
          const execute = () => { \(body) };
          print(marker + EJSON.stringify({ok: true, value: execute()}, {relaxed: false}));
        } catch (error) {
          print(marker + EJSON.stringify({ok: false, error: error.message || String(error)}, {relaxed: true}));
        }
        """
    }

    private func run(profile: ConnectionProfile, database: String?, script: String, input: JSONValue? = nil) async throws -> JSONValue {
        guard let executable = ["/opt/homebrew/bin/mongosh", "/usr/local/bin/mongosh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppError.message("mongosh is required. Install it with: brew install mongosh")
        }
        let password = profile.usesPassword ? try KeychainStore.read(for: profile.id) : ""
        let uri = try connectionURI(profile: profile, password: password)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--quiet", "--norc", "--eval", script]
        var environment = ProcessInfo.processInfo.environment
        environment["MONGO_MIGRATOR_URI"] = uri
        environment["MONGO_MIGRATOR_DATABASE"] = database ?? "admin"
        process.environment = environment
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = stdin
        try process.run()
        if let input {
            try stdin.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(input))
        }
        try stdin.fileHandleForWriting.close()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(decoding: outputData, as: UTF8.self)
        guard let line = stdout.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else {
            throw AppError.message(stdout.isEmpty ? "mongosh exited with status \(process.terminationStatus)" : stdout)
        }
        let payload = Data(line.dropFirst(marker.count).utf8)
        let response = try JSONDecoder().decode(ShellResponse.self, from: payload)
        guard response.ok else { throw AppError.message(response.error ?? "MongoDB operation failed") }
        return response.value ?? .null
    }

    private func connectionURI(profile: ConnectionProfile, password: String) throws -> String {
        let trimmed = profile.connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("mongodb://") || trimmed.hasPrefix("mongodb+srv://") else {
            throw AppError.message("Connection string must start with mongodb:// or mongodb+srv://")
        }
        guard !profile.username.isEmpty else { return trimmed }
        let schemeEnd = trimmed.range(of: "://")!.upperBound
        let prefix = String(trimmed[..<schemeEnd])
        var remainder = String(trimmed[schemeEnd...])
        if let at = remainder.firstIndex(of: "@") { remainder = String(remainder[remainder.index(after: at)...]) }
        let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@/"))
        let user = profile.username.addingPercentEncoding(withAllowedCharacters: allowed) ?? profile.username
        let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        var uri = "\(prefix)\(user):\(pass)@\(remainder)"
        if !profile.authenticationDatabase.isEmpty, !uri.contains("authSource=") {
            uri += uri.contains("?") ? "&" : "?"
            uri += "authSource=\(profile.authenticationDatabase.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "admin")"
        }
        return uri
    }
}

// MARK: - Diff engine

enum DiffEngine {
    static func compare(collection: String, source: [JSONValue], destination: [JSONValue], keyPaths: [String], ignoredPaths: Set<String>) -> [DocumentDifference] {
        let sourceMap = source.reduce(into: [String: JSONValue]()) { result, document in
            if let key = identity(document, paths: keyPaths), result[key] == nil { result[key] = document }
        }
        let destinationMap = destination.reduce(into: [String: JSONValue]()) { result, document in
            if let key = identity(document, paths: keyPaths), result[key] == nil { result[key] = document }
        }
        return Set(sourceMap.keys).union(destinationMap.keys).sorted().compactMap { key in
            let left = sourceMap[key]
            let right = destinationMap[key]
            let filter = makeFilter(document: left ?? right, paths: keyPaths)
            if let left, let right {
                let fields = fieldDifferences(source: left, destination: right, ignoredPaths: ignoredPaths)
                guard !fields.isEmpty else { return nil }
                return DocumentDifference(collection: collection, identity: key, filter: filter, source: left, destination: right, kind: .changed, fields: fields, action: .applySource, selectedPaths: Set(fields.map(\.path)))
            }
            if let left {
                return DocumentDifference(collection: collection, identity: key, filter: filter, source: left, destination: nil, kind: .added, fields: fieldDifferences(source: left, destination: nil, ignoredPaths: ignoredPaths), action: .applySource, selectedPaths: [])
            }
            if let right {
                return DocumentDifference(collection: collection, identity: key, filter: filter, source: nil, destination: right, kind: .removed, fields: fieldDifferences(source: nil, destination: right, ignoredPaths: ignoredPaths), action: .keepDestination, selectedPaths: [])
            }
            return nil
        }
    }

    private static func identity(_ document: JSONValue, paths: [String]) -> String? {
        let values = paths.map { document.value(at: $0)?.description ?? "<missing>" }
        guard !values.contains("<missing>") else { return nil }
        return zip(paths, values).map { "\($0)=\($1)" }.joined(separator: " • ")
    }

    private static func makeFilter(document: JSONValue?, paths: [String]) -> JSONValue {
        guard let document else { return .object([:]) }
        return .object(Dictionary(uniqueKeysWithValues: paths.compactMap { path in document.value(at: path).map { (path, $0) } }))
    }

    private static func fieldDifferences(source: JSONValue?, destination: JSONValue?, ignoredPaths: Set<String>) -> [FieldDifference] {
        let left = flatten(source)
        let right = flatten(destination)
        return Set(left.keys).union(right.keys).sorted().compactMap { path in
            guard !ignoredPaths.contains(where: { path == $0 || path.hasPrefix($0 + ".") }), left[path] != right[path] else { return nil }
            return FieldDifference(path: path, source: left[path], destination: right[path])
        }
    }

    private static func flatten(_ value: JSONValue?, prefix: String = "") -> [String: JSONValue] {
        guard let value else { return [:] }
        if case .object(let object) = value {
            return object.reduce(into: [:]) { result, pair in
                let path = prefix.isEmpty ? pair.key : "\(prefix).\(pair.key)"
                if case .object(let nested) = pair.value, !isExtendedJSONScalar(nested) {
                    result.merge(flatten(pair.value, prefix: path)) { _, new in new }
                }
                else { result[path] = pair.value }
            }
        }
        return [prefix: value]
    }

    private static func isExtendedJSONScalar(_ object: [String: JSONValue]) -> Bool {
        let scalarKeys: Set<String> = [
            "$oid", "$date", "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal",
            "$binary", "$regularExpression", "$timestamp", "$minKey", "$maxKey", "$undefined",
            "$dbPointer", "$code", "$symbol"
        ]
        return !scalarKeys.isDisjoint(with: object.keys)
    }
}

// MARK: - Profile UI

struct ProfilesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selectedID) {
                ForEach(store.profiles) { profile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name).fontWeight(.medium)
                        Text(profile.environment).font(.caption).foregroundStyle(profile.isProduction ? .red : .secondary)
                    }.tag(profile.id)
                }
            }
            .frame(minWidth: 210)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(action: add) { Image(systemName: "plus") }
                    Button(action: remove) { Image(systemName: "minus") }.disabled(selectedID == nil)
                    Spacer()
                }.padding(8)
            }

            if let binding = selectedBinding {
                ProfileEditor(profile: binding)
                    .frame(minWidth: 520)
            } else {
                ContentUnavailableView("Select a connection", systemImage: "externaldrive.connected.to.line.below")
                    .frame(minWidth: 520)
            }
        }
        .navigationTitle("Connections")
    }

    private var selectedBinding: Binding<ConnectionProfile>? {
        guard let selectedID, let index = store.profiles.firstIndex(where: { $0.id == selectedID }) else { return nil }
        return $store.profiles[index]
    }

    private func add() {
        selectedID = store.addProfile().id
    }

    private func remove() {
        guard let selectedID, let profile = store.profiles.first(where: { $0.id == selectedID }) else { return }
        store.removeProfile(profile)
        self.selectedID = nil
    }
}

struct ProfileEditor: View {
    @Binding var profile: ConnectionProfile
    @State private var password = ""
    @State private var databases: [String] = []
    @State private var status = ""
    @State private var testing = false
    private let client = MongoShellClient()

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $profile.name)
                Picker("Environment", selection: $profile.environment) {
                    ForEach(["Development", "Staging", "Production", "QA"], id: \.self) { Text($0) }
                }
            }
            Section("MongoDB") {
                TextField("Connection string", text: $profile.connectionString, prompt: Text("mongodb://localhost:27017"))
                    .textContentType(.URL)
                Text("Atlas SRV and local MongoDB connection strings are supported.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Authentication") {
                TextField("Username (optional)", text: $profile.username)
                Toggle("Use password", isOn: $profile.usesPassword)
                if profile.usesPassword {
                    SecureField("Password", text: $password)
                    TextField("Authentication database", text: $profile.authenticationDatabase)
                    Text("The password is stored only in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button(testing ? "Testing…" : "Save & Test") { test() }.disabled(testing)
                    if !status.isEmpty { Text(status).foregroundStyle(status.hasPrefix("Connected") ? .green : .red) }
                }
                if !databases.isEmpty { Text("Databases: \(databases.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { password = (try? KeychainStore.read(for: profile.id)) ?? "" }
    }

    private func test() {
        testing = true
        status = ""
        Task {
            do {
                if profile.usesPassword { try KeychainStore.save(password, for: profile.id) }
                else { KeychainStore.delete(for: profile.id) }
                databases = try await client.test(profile: profile)
                status = "Connected"
            } catch { status = error.localizedDescription }
            testing = false
        }
    }
}

// MARK: - Compare UI

struct ActivityLogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let message: String
    let isError: Bool
}

struct SavedCompareConfiguration: Codable {
    let sourceID: UUID?
    let destinationID: UUID?
    let sourceDatabase: String
    let destinationDatabase: String
    let collections: [String]
    let selectedCollections: Set<String>
    let matchMode: MatchMode
    let keyFields: String
    let ignoredFields: String
    let filter: String
    let limit: Int
    let dryRun: Bool
    let includeDocuments: Bool
    let includeValidators: Bool
    let includeIndexes: Bool
    let matchCollection: String?
    let uniqueIndexesByCollection: [String: [MongoUniqueIndex]]?
    let selectedUniqueIndexIDs: [String: String]?
}

@MainActor
final class CompareViewModel: ObservableObject {
    @Published var sourceID: UUID? { didSet { persistConfiguration() } }
    @Published var destinationID: UUID? { didSet { persistConfiguration() } }
    @Published var sourceDatabases: [String] = []
    @Published var destinationDatabases: [String] = []
    @Published var sourceDatabase = "" { didSet { persistConfiguration() } }
    @Published var destinationDatabase = "" { didSet { persistConfiguration() } }
    @Published var collections: [String] = [] { didSet { persistConfiguration() } }
    @Published var selectedCollections: Set<String> = [] { didSet { persistConfiguration() } }
    @Published var matchMode: MatchMode = .objectID { didSet { persistConfiguration() } }
    @Published var keyFields = "" { didSet { persistConfiguration() } }
    @Published var matchCollection = "" { didSet { persistConfiguration() } }
    @Published var uniqueIndexesByCollection: [String: [MongoUniqueIndex]] = [:] { didSet { persistConfiguration() } }
    @Published var selectedUniqueIndexIDs: [String: String] = [:] { didSet { persistConfiguration() } }
    @Published var ignoredFields = "createdAt, updatedAt" { didSet { persistConfiguration() } }
    @Published var filter = "{}" { didSet { persistConfiguration() } }
    @Published var limit = 1000 { didSet { persistConfiguration() } }
    @Published var differences: [DocumentDifference] = []
    @Published var selectedDifferenceID: UUID?
    @Published var loading = false
    @Published var message = ""
    @Published var dryRun = true { didSet { persistConfiguration() } }
    @Published var showDeleteConfirmation = false
    private var deletionWasConfirmed = false
    @Published var includeDocuments = true { didSet { persistConfiguration() } }
    @Published var includeValidators = false { didSet { persistConfiguration() } }
    @Published var includeIndexes = false { didSet { persistConfiguration() } }
    @Published var schemaOperations: [JSONValue] = []
    @Published var activityLog: [ActivityLogEntry] = []
    let client = MongoShellClient()
    private let defaults: UserDefaults
    private let configurationKey = "compareConfiguration"
    private var isRestoringConfiguration = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreConfiguration()
    }

    var keyPaths: [String] {
        switch matchMode {
        case .objectID: return ["_id"]
        case .uniqueField, .compoundKey: return keyFields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    var activeMatchCollection: String {
        if selectedCollections.contains(matchCollection) { return matchCollection }
        return selectedCollections.sorted().first ?? ""
    }

    func uniqueIndexes(for collection: String) -> [MongoUniqueIndex] {
        uniqueIndexesByCollection[collection] ?? []
    }

    func selectedIndexID(for collection: String) -> String {
        let indexes = uniqueIndexes(for: collection)
        if let selected = selectedUniqueIndexIDs[collection], indexes.contains(where: { $0.id == selected }) {
            return selected
        }
        return indexes.first(where: { $0.name == "_id_" })?.id ?? indexes.first?.id ?? "__custom__"
    }

    func setSelectedIndexID(_ id: String, for collection: String) {
        selectedUniqueIndexIDs[collection] = id
    }

    func selectedIndex(for collection: String) -> MongoUniqueIndex? {
        let id = selectedIndexID(for: collection)
        return uniqueIndexes(for: collection).first(where: { $0.id == id })
    }

    func matchingKeyPaths(for collection: String) -> [String] {
        if let index = selectedIndex(for: collection) { return index.fields }
        let custom = keyFields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return custom.isEmpty ? ["_id"] : custom
    }

    func matchingPartialFilter(for collection: String) -> JSONValue? {
        selectedIndex(for: collection)?.partialFilter
    }

    func loadDatabases(profiles: [ConnectionProfile]) {
        guard let source = profiles.first(where: { $0.id == sourceID }), let destination = profiles.first(where: { $0.id == destinationID }) else {
            report("Choose both a source and destination connection.", isError: true)
            return
        }
        loading = true
        report("Connecting to \(source.name) and \(destination.name)…")
        Task {
            do {
                async let left = client.test(profile: source)
                async let right = client.test(profile: destination)
                sourceDatabases = try await left
                destinationDatabases = try await right
                if sourceDatabase.isEmpty { sourceDatabase = sourceDatabases.first ?? "" }
                if destinationDatabase.isEmpty { destinationDatabase = destinationDatabases.first ?? "" }
                message = "Connections ready"
                report("Connected. Source has \(sourceDatabases.count) databases; destination has \(destinationDatabases.count).")
            } catch {
                message = error.localizedDescription
                report("Connection failed: \(error.localizedDescription)", isError: true)
            }
            loading = false
        }
    }

    func switchMigrationDirection() {
        let previousSourceID = sourceID
        let previousSourceDatabases = sourceDatabases
        let previousSourceDatabase = sourceDatabase

        sourceID = destinationID
        sourceDatabases = destinationDatabases
        sourceDatabase = destinationDatabase
        destinationID = previousSourceID
        destinationDatabases = previousSourceDatabases
        destinationDatabase = previousSourceDatabase

        selectedDifferenceID = nil
        differences = []
        schemaOperations = []
        message = "Migration direction switched"
        report("Switched migration direction: \(sourceDatabase) → \(destinationDatabase). Run Compare to refresh the results.")
    }

    func loadCollections(profiles: [ConnectionProfile]) {
        guard let source = profiles.first(where: { $0.id == sourceID }), let destination = profiles.first(where: { $0.id == destinationID }), !sourceDatabase.isEmpty, !destinationDatabase.isEmpty else {
            report("Connect and choose both databases before loading collections.", isError: true)
            return
        }
        loading = true
        report("Loading shared collections from \(sourceDatabase) and \(destinationDatabase)…")
        Task {
            do {
                async let left = client.collections(profile: source, database: sourceDatabase)
                async let right = client.collections(profile: destination, database: destinationDatabase)
                let shared = Set(try await left).intersection(try await right)
                collections = shared.sorted()
                selectedCollections = selectedCollections.intersection(shared)
                uniqueIndexesByCollection = uniqueIndexesByCollection.filter { shared.contains($0.key) }
                selectedUniqueIndexIDs = selectedUniqueIndexIDs.filter { shared.contains($0.key) }
                if !selectedCollections.contains(matchCollection) {
                    matchCollection = selectedCollections.sorted().first ?? ""
                }
                message = "Found \(collections.count) matching collections"
                report("Found \(collections.count) collections with matching names.")
            } catch {
                message = error.localizedDescription
                report("Could not load collections: \(error.localizedDescription)", isError: true)
            }
            loading = false
        }
    }

    func loadUniqueIndexes(profiles: [ConnectionProfile]) {
        guard let source = profiles.first(where: { $0.id == sourceID }),
              let destination = profiles.first(where: { $0.id == destinationID }),
              !sourceDatabase.isEmpty,
              !destinationDatabase.isEmpty,
              !selectedCollections.isEmpty else {
            report("Choose source, destination, databases, and collections before loading unique indexes.", isError: true)
            return
        }
        loading = true
        report("Loading compatible unique indexes for \(selectedCollections.count) collection(s)…")
        Task {
            do {
                var loaded: [String: [MongoUniqueIndex]] = [:]
                var selections = selectedUniqueIndexIDs
                for collection in selectedCollections.sorted() {
                    async let sourceIndexes = client.uniqueIndexes(profile: source, database: sourceDatabase, collection: collection)
                    async let destinationIndexes = client.uniqueIndexes(profile: destination, database: destinationDatabase, collection: collection)
                    let left = try await sourceIndexes
                    let right = try await destinationIndexes
                    let compatible = left.filter { sourceIndex in
                        right.contains(where: { $0.fields == sourceIndex.fields && $0.partialFilter == sourceIndex.partialFilter })
                    }
                    loaded[collection] = compatible
                    let availableIDs = Set(compatible.map(\.id))
                    if let selected = selections[collection], availableIDs.contains(selected) {
                        // Keep the previously selected matching rule.
                    } else if let objectID = compatible.first(where: { $0.name == "_id_" }) {
                        selections[collection] = objectID.id
                    } else {
                        selections[collection] = compatible.first?.id ?? "__custom__"
                    }
                    report("\(collection): loaded \(compatible.count) compatible unique index(es).")
                }
                uniqueIndexesByCollection = loaded
                selectedUniqueIndexIDs = selections.filter { selectedCollections.contains($0.key) }
                if !selectedCollections.contains(matchCollection) {
                    matchCollection = selectedCollections.sorted().first ?? ""
                }
                message = "Unique indexes ready"
                report("Unique index loading finished.")
            } catch {
                message = error.localizedDescription
                report("Could not load unique indexes: \(error.localizedDescription)", isError: true)
            }
            loading = false
        }
    }

    func compare(profiles: [ConnectionProfile]) {
        guard includeDocuments || includeValidators || includeIndexes else {
            message = "Select documents, validators, or indexes to compare."
            report(message, isError: true)
            return
        }
        guard !includeDocuments || selectedCollections.allSatisfy({ !matchingKeyPaths(for: $0).isEmpty }) else {
            message = "Enter at least one matching field."
            report(message, isError: true)
            return
        }
        guard let source = profiles.first(where: { $0.id == sourceID }), let destination = profiles.first(where: { $0.id == destinationID }), !selectedCollections.isEmpty else {
            message = "Choose source, destination, and at least one collection."
            report(message, isError: true)
            return
        }
        loading = true
        selectedDifferenceID = nil
        differences = []
        schemaOperations = []
        let ignored = Set(ignoredFields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        report("Starting comparison: \(source.name)/\(sourceDatabase) → \(destination.name)/\(destinationDatabase).")
        Task {
            do {
                var result: [DocumentDifference] = []
                var pendingSchema: [JSONValue] = []
                let orderedCollections = selectedCollections.sorted()
                for (index, collection) in orderedCollections.enumerated() {
                    message = "Comparing \(collection) (\(index + 1) of \(orderedCollections.count))"
                    report(message)
                    if includeDocuments {
                        let keyPaths = matchingKeyPaths(for: collection)
                        let partialFilter = matchingPartialFilter(for: collection)
                        if let index = selectedIndex(for: collection) {
                            let partialDescription = index.partialFilter.map { "; partial filter \($0.description)" } ?? ""
                            report("\(collection): matching by \(index.name) [\(keyPaths.joined(separator: ", "))]\(partialDescription).")
                        } else {
                            report("\(collection): matching by custom fields [\(keyPaths.joined(separator: ", "))].")
                        }
                        async let left = client.documents(profile: source, database: sourceDatabase, collection: collection, filter: filter, partialFilter: partialFilter, limit: limit)
                        async let right = client.documents(profile: destination, database: destinationDatabase, collection: collection, filter: filter, partialFilter: partialFilter, limit: limit)
                        let sourceDocuments = try await left
                        let destinationDocuments = try await right
                        let collectionDifferences = DiffEngine.compare(collection: collection, source: sourceDocuments, destination: destinationDocuments, keyPaths: keyPaths, ignoredPaths: ignored)
                        result += collectionDifferences
                        report("\(collection): read \(sourceDocuments.count) source and \(destinationDocuments.count) destination documents; found \(collectionDifferences.count) differences.")
                    }
                    if includeValidators || includeIndexes {
                        async let leftSchema = client.schema(profile: source, database: sourceDatabase, collection: collection)
                        async let rightSchema = client.schema(profile: destination, database: destinationDatabase, collection: collection)
                        let collectionSchemaOperations = makeSchemaOperations(collection: collection, source: try await leftSchema, destination: try await rightSchema)
                        pendingSchema += collectionSchemaOperations
                        report("\(collection): found \(collectionSchemaOperations.count) validator/index differences.")
                    }
                }
                differences = result
                schemaOperations = pendingSchema
                selectedDifferenceID = result.first?.id
                if result.isEmpty && pendingSchema.isEmpty { message = "No differences found" }
                else { message = "Found \(result.count) document and \(pendingSchema.count) schema differences" }
                report("Comparison finished. \(message).")
            } catch {
                message = error.localizedDescription
                report("Comparison failed: \(error.localizedDescription)", isError: true)
            }
            loading = false
        }
    }

    func execute(profiles: [ConnectionProfile], store: AppStore) {
        if differences.contains(where: { $0.action == .deleteDestination }) && !deletionWasConfirmed {
            showDeleteConfirmation = true
            return
        }
        deletionWasConfirmed = false
        guard let source = profiles.first(where: { $0.id == sourceID }), let destination = profiles.first(where: { $0.id == destinationID }) else { return }
        let operations = buildOperations()
        let counts = operationCounts(operations)
        if dryRun {
            let detailsPath = try? BackupStore.create(destination: destination, database: destinationDatabase, differences: differences, schemaOperations: schemaOperations)
            store.history.insert(HistoryEntry(
                date: Date(),
                source: source.name,
                destination: destination.name,
                database: "\(sourceDatabase) → \(destinationDatabase)",
                collections: selectedCollections.sorted(),
                dryRun: true,
                inserts: counts.0,
                updates: counts.1,
                deletions: counts.2,
                status: "Previewed",
                destinationProfileID: destination.id,
                sourceDatabaseName: sourceDatabase,
                destinationDatabaseName: destinationDatabase,
                detailsPath: detailsPath
            ), at: 0)
            message = "Dry run: \(counts.0) inserts, \(counts.1) updates, \(counts.2) deletions"
            report(message)
            return
        }
        let backupPath: String
        do {
            backupPath = try BackupStore.create(destination: destination, database: destinationDatabase, differences: differences, schemaOperations: schemaOperations)
        } catch {
            message = "Could not create the required rollback backup: \(error.localizedDescription)"
            report(message, isError: true)
            return
        }
        loading = true
        report("Applying migration: \(counts.0) inserts, \(counts.1) updates, \(counts.2) deletions.")
        Task {
            do {
                _ = try await client.apply(profile: destination, database: destinationDatabase, operations: operations)
                store.history.insert(HistoryEntry(
                    date: Date(),
                    source: source.name,
                    destination: destination.name,
                    database: "\(sourceDatabase) → \(destinationDatabase)",
                    collections: selectedCollections.sorted(),
                    dryRun: false,
                    inserts: counts.0,
                    updates: counts.1,
                    deletions: counts.2,
                    status: "Completed",
                    backupPath: backupPath,
                    destinationProfileID: destination.id,
                    sourceDatabaseName: sourceDatabase,
                    destinationDatabaseName: destinationDatabase,
                    detailsPath: backupPath
                ), at: 0)
                message = "Migration completed"
                report("Migration completed. Rollback backup: \(backupPath)")
            } catch {
                store.history.insert(HistoryEntry(
                    date: Date(),
                    source: source.name,
                    destination: destination.name,
                    database: "\(sourceDatabase) → \(destinationDatabase)",
                    collections: selectedCollections.sorted(),
                    dryRun: false,
                    inserts: counts.0,
                    updates: counts.1,
                    deletions: counts.2,
                    status: "Failed: \(error.localizedDescription)",
                    backupPath: backupPath,
                    destinationProfileID: destination.id,
                    sourceDatabaseName: sourceDatabase,
                    destinationDatabaseName: destinationDatabase,
                    detailsPath: backupPath
                ), at: 0)
                message = error.localizedDescription
                report("Migration failed: \(error.localizedDescription)", isError: true)
            }
            loading = false
        }
    }

    func confirmDeletion() {
        deletionWasConfirmed = true
    }

    func clearActivityLog() {
        activityLog.removeAll()
    }

    func excludeFieldFromAllDocuments(_ path: String) {
        let normalizedPath = normalizeExcludedPath(path)
        var excluded = Set(ignoredFields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        excluded.insert(normalizedPath)
        ignoredFields = excluded.sorted().joined(separator: ", ")
        for index in differences.indices {
            differences[index].selectedPaths = Set(differences[index].selectedPaths.filter {
                $0 != normalizedPath && !$0.hasPrefix(normalizedPath + ".")
            })
        }
        message = "\(normalizedPath) will not be migrated"
        report("Excluded \(normalizedPath) from every document in this migration.")
    }

    private func restoreConfiguration() {
        guard let data = defaults.data(forKey: configurationKey),
              let saved = try? JSONDecoder().decode(SavedCompareConfiguration.self, from: data) else { return }
        isRestoringConfiguration = true
        sourceID = saved.sourceID
        destinationID = saved.destinationID
        sourceDatabase = saved.sourceDatabase
        destinationDatabase = saved.destinationDatabase
        collections = saved.collections
        selectedCollections = saved.selectedCollections.intersection(saved.collections)
        matchMode = saved.matchMode
        keyFields = saved.keyFields
        matchCollection = saved.matchCollection ?? selectedCollections.sorted().first ?? ""
        uniqueIndexesByCollection = saved.uniqueIndexesByCollection ?? [:]
        selectedUniqueIndexIDs = saved.selectedUniqueIndexIDs ?? [:]
        ignoredFields = saved.ignoredFields
        filter = saved.filter
        limit = min(max(saved.limit, 10), 5000)
        dryRun = saved.dryRun
        includeDocuments = saved.includeDocuments
        includeValidators = saved.includeValidators
        includeIndexes = saved.includeIndexes
        isRestoringConfiguration = false
        report("Restored the previous comparison configuration.")
    }

    private func persistConfiguration() {
        guard !isRestoringConfiguration else { return }
        let configuration = SavedCompareConfiguration(
            sourceID: sourceID,
            destinationID: destinationID,
            sourceDatabase: sourceDatabase,
            destinationDatabase: destinationDatabase,
            collections: collections,
            selectedCollections: selectedCollections,
            matchMode: matchMode,
            keyFields: keyFields,
            ignoredFields: ignoredFields,
            filter: filter,
            limit: limit,
            dryRun: dryRun,
            includeDocuments: includeDocuments,
            includeValidators: includeValidators,
            includeIndexes: includeIndexes,
            matchCollection: matchCollection,
            uniqueIndexesByCollection: uniqueIndexesByCollection,
            selectedUniqueIndexIDs: selectedUniqueIndexIDs
        )
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: configurationKey)
        }
    }

    private func report(_ text: String, isError: Bool = false) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        activityLog.append(ActivityLogEntry(timestamp: timestamp, message: text, isError: isError))
        if activityLog.count > 500 { activityLog.removeFirst(activityLog.count - 500) }
    }

    private func buildOperations() -> JSONValue {
        let excludedPaths = Set(ignoredFields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        var values = differences.compactMap { difference -> JSONValue? in
            switch difference.action {
            case .keepDestination: return nil
            case .deleteDestination:
                return .object(["collection": .string(difference.collection), "action": .string("delete"), "filter": difference.filter])
            case .applySource:
                guard let source = difference.source else { return nil }
                if difference.destination == nil {
                    return .object([
                        "collection": .string(difference.collection),
                        "action": .string("insert"),
                        "document": removing(paths: excludedPaths, from: source)
                    ])
                }
                var set: [String: JSONValue] = [:]
                var unset: [JSONValue] = []
                for field in difference.fields where difference.selectedPaths.contains(field.path) {
                    if let value = field.source { set[field.path] = value }
                    else { unset.append(.string(field.path)) }
                }
                return .object(["collection": .string(difference.collection), "action": .string("update"), "filter": difference.filter, "set": .object(set), "unset": .array(unset)])
            }
        }
        values.append(contentsOf: schemaOperations)
        return .object(["operations": .array(values)])
    }

    private func normalizeExcludedPath(_ path: String) -> String {
        let extendedJSONSuffixes = [
            ".$oid", ".$date", ".$numberInt", ".$numberLong", ".$numberDouble", ".$numberDecimal",
            ".$binary", ".$regularExpression", ".$timestamp"
        ]
        for suffix in extendedJSONSuffixes where path.hasSuffix(suffix) {
            return String(path.dropLast(suffix.count))
        }
        return path
    }

    private func removing(paths: Set<String>, from value: JSONValue) -> JSONValue {
        paths.reduce(value) { result, path in
            removing(pathComponents: path.split(separator: ".").map(String.init), from: result)
        }
    }

    private func removing(pathComponents: [String], from value: JSONValue) -> JSONValue {
        guard let first = pathComponents.first, case .object(var object) = value else { return value }
        if pathComponents.count == 1 {
            object.removeValue(forKey: first)
        } else if let child = object[first] {
            object[first] = removing(pathComponents: Array(pathComponents.dropFirst()), from: child)
        }
        return .object(object)
    }

    private func makeSchemaOperations(collection: String, source: JSONValue, destination: JSONValue) -> [JSONValue] {
        guard case .object(let left) = source, case .object(let right) = destination else { return [] }
        var operations: [JSONValue] = []
        if includeValidators, left["validator"] != right["validator"], let validator = left["validator"] {
            operations.append(.object(["collection": .string(collection), "action": .string("validator"), "validator": validator]))
        }
        if includeIndexes, case .array(let sourceIndexes) = left["indexes"] {
            let destinationIndexes: [JSONValue]
            if case .array(let values) = right["indexes"] { destinationIndexes = values } else { destinationIndexes = [] }
            for index in sourceIndexes {
                guard case .object(let object) = index, case .string(let name) = object["name"] else { continue }
                let destinationIndex = destinationIndexes.first { value in
                    guard case .object(let candidate) = value, case .string(let candidateName) = candidate["name"] else { return false }
                    return candidateName == name
                }
                if destinationIndex != index {
                    operations.append(.object(["collection": .string(collection), "action": .string("index"), "index": index]))
                }
            }
        }
        return operations
    }

    private func operationCounts(_ operations: JSONValue) -> (Int, Int, Int) {
        guard case .object(let root) = operations, case .array(let values) = root["operations"] else { return (0, 0, 0) }
        var result = (0, 0, 0)
        for value in values {
            guard case .object(let object) = value, case .string(let action) = object["action"] else { continue }
            if action == "insert" { result.0 += 1 }
            if action == "update" { result.1 += 1 }
            if action == "delete" { result.2 += 1 }
        }
        return result
    }
}

struct CompareView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model = CompareViewModel()
    @State private var showingCollectionPicker = false

    var body: some View {
        VStack(spacing: 0) {
            configuration
            Divider()
            Group {
                if model.differences.isEmpty && model.schemaOperations.isEmpty {
                    ContentUnavailableView(model.loading ? "Comparing…" : "Ready to compare", systemImage: "arrow.left.arrow.right", description: Text("Choose two saved connections, databases, and matching collections."))
                } else {
                    results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            Divider()
            ActivityLogView(entries: model.activityLog, onClear: model.clearActivityLog)
                .frame(height: 150)
            Divider()
            HStack {
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Toggle("Dry run", isOn: $model.dryRun).toggleStyle(.switch)
                Button(model.dryRun ? "Preview migration" : "Run migration") { model.execute(profiles: store.profiles, store: store) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.loading || (model.differences.isEmpty && model.schemaOperations.isEmpty))
            }.padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Compare & Migrate")
        .alert("Confirm deletions", isPresented: $model.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete and migrate", role: .destructive) {
                model.confirmDeletion()
                model.execute(profiles: store.profiles, store: store)
            }
        } message: {
            Text("This will permanently delete every document marked Delete destination. This action cannot be undone without a backup.")
        }
        .sheet(isPresented: $showingCollectionPicker) {
            CollectionSelectionSheet(collections: model.collections, selection: $model.selectedCollections) {
                model.loadUniqueIndexes(profiles: store.profiles)
            }
        }
    }

    private var configuration: some View {
        VStack(spacing: 12) {
            HStack {
                profilePicker("Source", selection: $model.sourceID)
                Button {
                    model.switchMigrationDirection()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title3)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.bordered)
                .help("Switch migration direction")
                .accessibilityLabel("Switch migration direction")
                .disabled(model.loading || model.sourceID == nil || model.destinationID == nil)
                profilePicker("Destination", selection: $model.destinationID)
                Button("Connect") { model.loadDatabases(profiles: store.profiles) }.disabled(model.loading || model.sourceID == nil || model.destinationID == nil)
            }
            HStack {
                Picker("Source database", selection: $model.sourceDatabase) {
                    if !model.sourceDatabase.isEmpty && !model.sourceDatabases.contains(model.sourceDatabase) {
                        Text(model.sourceDatabase).tag(model.sourceDatabase)
                    }
                    ForEach(model.sourceDatabases, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: .infinity)
                Picker("Destination database", selection: $model.destinationDatabase) {
                    if !model.destinationDatabase.isEmpty && !model.destinationDatabases.contains(model.destinationDatabase) {
                        Text(model.destinationDatabase).tag(model.destinationDatabase)
                    }
                    ForEach(model.destinationDatabases, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: .infinity)
                Button("Load collections") { model.loadCollections(profiles: store.profiles) }.disabled(model.loading || model.sourceDatabase.isEmpty || model.destinationDatabase.isEmpty)
            }
            HStack {
                Text("Collections")
                Button {
                    showingCollectionPicker = true
                } label: {
                    Label("Select collections…", systemImage: "list.bullet.rectangle")
                }
                .disabled(model.collections.isEmpty)
                Text(collectionSelectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if model.selectedCollections.count > 1 {
                        Picker("Collection rule", selection: $model.matchCollection) {
                            ForEach(model.selectedCollections.sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        .frame(minWidth: 260)
                    }
                    Picker("Match by", selection: selectedUniqueIndexBinding) {
                        ForEach(model.uniqueIndexes(for: model.activeMatchCollection)) { index in
                            Text(index.displayName).tag(index.id)
                        }
                        Divider()
                        Text("Custom fields…").tag("__custom__")
                    }
                    .frame(minWidth: 300)
                    .disabled(model.activeMatchCollection.isEmpty)
                    Button {
                        model.loadUniqueIndexes(profiles: store.profiles)
                    } label: {
                        Label("Refresh indexes", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.loading || model.selectedCollections.isEmpty)
                    if selectedUniqueIndexBinding.wrappedValue == "__custom__" {
                        TextField("Fields separated by commas", text: $model.keyFields)
                    }
                    Spacer()
                }
                if let index = model.selectedIndex(for: model.activeMatchCollection), let partialFilter = index.partialFilter {
                    Label("Partial filter applied during comparison: \(partialFilter.description)", systemImage: "line.3.horizontal.decrease.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            HStack {
                TextField("Never migrate fields (for example: policyId, metadata.owner)", text: $model.ignoredFields)
                    .help("Comma-separated field or subdocument paths excluded from every document. A parent path excludes all of its children.")
                TextField("MongoDB filter", text: $model.filter).font(.system(.body, design: .monospaced))
                Stepper("Limit \(model.limit)", value: $model.limit, in: 10...5000, step: 100).fixedSize()
            }
            HStack {
                Toggle("Documents", isOn: $model.includeDocuments)
                Toggle("Validators", isOn: $model.includeValidators)
                Toggle("Indexes", isOn: $model.includeIndexes)
                Spacer()
                Button("Compare") { model.compare(profiles: store.profiles) }.buttonStyle(.borderedProminent).disabled(model.loading || model.selectedCollections.isEmpty)
            }
        }.padding()
    }

    private func profilePicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("Choose…").tag(nil as UUID?)
            ForEach(store.profiles) { profile in Text("\(profile.name) (\(profile.environment))").tag(profile.id as UUID?) }
        }.frame(maxWidth: .infinity)
    }

    private var collectionSelectionSummary: String {
        let names = model.selectedCollections.sorted()
        guard !names.isEmpty else {
            return model.collections.isEmpty ? "Load collections to begin" : "None selected"
        }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more"
    }

    private var selectedUniqueIndexBinding: Binding<String> {
        let collection = model.activeMatchCollection
        return Binding(
            get: { model.selectedIndexID(for: collection) },
            set: { model.setSelectedIndexID($0, for: collection) }
        )
    }

    private var results: some View {
        VStack(spacing: 0) {
            if !model.schemaOperations.isEmpty {
                DisclosureGroup("Schema changes (\(model.schemaOperations.count))") {
                    ForEach(Array(model.schemaOperations.enumerated()), id: \.offset) { _, operation in
                        Text(operation.description)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                Divider()
            }
            HSplitView {
                Table(model.differences, selection: $model.selectedDifferenceID) {
                    TableColumn("Collection") { Text($0.collection) }.width(min: 100, ideal: 140)
                    TableColumn("Document") { Text($0.identity).lineLimit(1) }.width(min: 160, ideal: 260)
                    TableColumn("Difference") { DifferenceKindBadge(kind: $0.kind) }.width(150)
                    TableColumn("Action") { difference in
                        Picker("", selection: actionBinding(for: difference.id)) {
                            ForEach(MigrationAction.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                    }.width(160)
                }.frame(minWidth: 520)

                if let difference = model.differences.first(where: { $0.id == model.selectedDifferenceID }) {
                    DifferenceDetail(
                        difference: differenceBinding(for: difference),
                        onExcludeEverywhere: model.excludeFieldFromAllDocuments
                    )
                        .frame(minWidth: 430)
                } else {
                    ContentUnavailableView("No document selected", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func differenceBinding(for fallback: DocumentDifference) -> Binding<DocumentDifference> {
        Binding(get: {
            model.differences.first(where: { $0.id == fallback.id }) ?? fallback
        }, set: { value in
            if let index = model.differences.firstIndex(where: { $0.id == fallback.id }) {
                model.differences[index] = value
            }
        })
    }

    private func actionBinding(for id: UUID) -> Binding<MigrationAction> {
        Binding(get: { model.differences.first(where: { $0.id == id })?.action ?? .keepDestination }, set: { action in
            if let index = model.differences.firstIndex(where: { $0.id == id }) { model.differences[index].action = action }
        })
    }
}

struct DifferenceKindBadge: View {
    let kind: DifferenceKind

    var body: some View {
        Label(kind.rawValue, systemImage: icon)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch kind {
        case .added: return .green
        case .changed: return .orange
        case .removed: return .red
        case .unchanged: return .secondary
        }
    }

    private var icon: String {
        switch kind {
        case .added: return "plus"
        case .changed: return "pencil"
        case .removed: return "minus"
        case .unchanged: return "equal"
        }
    }
}

struct CollectionSelectionRow: Identifiable {
    let name: String
    var id: String { name }
}

struct CollectionSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let collections: [String]
    @Binding var selection: Set<String>
    let onDone: () -> Void
    @State private var draftSelection: Set<String>
    @State private var searchText = ""

    init(collections: [String], selection: Binding<Set<String>>, onDone: @escaping () -> Void = {}) {
        self.collections = collections.sorted()
        self._selection = selection
        self.onDone = onDone
        self._draftSelection = State(initialValue: selection.wrappedValue)
    }

    private var filteredRows: [CollectionSelectionRow] {
        collections
            .filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }
            .map(CollectionSelectionRow.init(name:))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter collections", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("Select all") { draftSelection = Set(collections) }
                Button("Clear") { draftSelection.removeAll() }
                    .disabled(draftSelection.isEmpty)
            }
            .padding()

            Divider()

            Table(filteredRows) {
                TableColumn("Use") { row in
                    Toggle("", isOn: selectionBinding(for: row.name))
                        .labelsHidden()
                }
                .width(44)

                TableColumn("Collection") { row in
                    Button {
                        toggle(row.name)
                    } label: {
                        Text(row.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if filteredRows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }

            Divider()

            HStack {
                Text("\(draftSelection.count) of \(collections.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    selection = draftSelection.intersection(collections)
                    dismiss()
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 580)
    }

    private func selectionBinding(for collection: String) -> Binding<Bool> {
        Binding(
            get: { draftSelection.contains(collection) },
            set: { selected in
                if selected { draftSelection.insert(collection) }
                else { draftSelection.remove(collection) }
            }
        )
    }

    private func toggle(_ collection: String) {
        if draftSelection.contains(collection) { draftSelection.remove(collection) }
        else { draftSelection.insert(collection) }
    }
}

struct ActivityLogView: View {
    let entries: [ActivityLogEntry]
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Activity Log", systemImage: "text.alignleft")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("\(entries.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: onClear)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if entries.isEmpty {
                            Text("Connection, comparison progress, and errors will appear here.")
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 6)
                        }
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.timestamp)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 76, alignment: .leading)
                                Text(entry.message)
                                    .foregroundStyle(entry.isError ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .onChange(of: entries.count) {
                    if let lastID = entries.last?.id {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}

struct DifferenceDetail: View {
    @Binding var difference: DocumentDifference
    let onExcludeEverywhere: (String) -> Void
    @State private var inspectedField: FieldDifference?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(difference.identity).font(.headline).lineLimit(2)
            Text("Select the fields or subdocuments to copy from source.").font(.caption).foregroundStyle(.secondary)
            Table(difference.fields) {
                TableColumn("Use") { field in
                    Toggle("", isOn: Binding(get: { difference.selectedPaths.contains(field.path) }, set: { selected in
                        if selected { difference.selectedPaths.insert(field.path) } else { difference.selectedPaths.remove(field.path) }
                    })).labelsHidden().disabled(difference.kind != .changed)
                }.width(38)
                TableColumn("Field") { Text($0.path).font(.system(.caption, design: .monospaced)) }.width(min: 100, ideal: 150)
                TableColumn("Source") { Text($0.source?.description ?? "—").lineLimit(3).textSelection(.enabled) }
                TableColumn("Destination") { Text($0.destination?.description ?? "—").lineLimit(3).textSelection(.enabled) }
                TableColumn("View") { field in
                    Button {
                        inspectedField = field
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help("View the complete source and destination values")
                }
                .width(42)
                TableColumn("Skip all") { field in
                    Button {
                        onExcludeEverywhere(field.path)
                    } label: {
                        Image(systemName: "nosign")
                    }
                    .buttonStyle(.borderless)
                    .help("Never migrate \(field.path) for any document")
                }
                .width(54)
            }
            HStack {
                Button("Select all") { difference.selectedPaths = Set(difference.fields.map(\.path)) }
                Button("Select none") { difference.selectedPaths.removeAll() }
                Spacer()
            }
        }
        .padding()
        .sheet(item: $inspectedField) { field in
            FieldValueSheet(field: field)
        }
    }
}

struct FieldValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let field: FieldDifference

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Full field value")
                        .font(.headline)
                    Text(field.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            FieldCodeReview(field: field)
        }
        .frame(minWidth: 900, idealWidth: 1180, minHeight: 560, idealHeight: 760)
    }
}

enum LineDifferenceKind {
    case unchanged
    case inserted
    case modified
    case deleted
}

struct LineDifference: Identifiable {
    let id: Int
    let sourceNumber: Int?
    let source: String?
    let destinationNumber: Int?
    let destination: String?
    let kind: LineDifferenceKind
}

enum LineDiffEngine {
    private typealias NumberedLine = (number: Int, text: String)
    private typealias RawRow = (source: NumberedLine?, destination: NumberedLine?, kind: LineDifferenceKind)

    static func compare(source: String, destination: String) -> [LineDifference] {
        let sourceLines = source.components(separatedBy: "\n")
        let destinationLines = destination.components(separatedBy: "\n")
        let maximumMatrixCells = 2_000_000
        guard destinationLines.isEmpty || sourceLines.count <= maximumMatrixCells / max(destinationLines.count, 1) else {
            return positionalFallback(source: sourceLines, destination: destinationLines)
        }

        let columnCount = destinationLines.count + 1
        var lcs = [Int](repeating: 0, count: (sourceLines.count + 1) * columnCount)
        if !sourceLines.isEmpty && !destinationLines.isEmpty {
            for sourceIndex in stride(from: sourceLines.count - 1, through: 0, by: -1) {
                for destinationIndex in stride(from: destinationLines.count - 1, through: 0, by: -1) {
                    let index = sourceIndex * columnCount + destinationIndex
                    if sourceLines[sourceIndex] == destinationLines[destinationIndex] {
                        lcs[index] = lcs[(sourceIndex + 1) * columnCount + destinationIndex + 1] + 1
                    } else {
                        lcs[index] = max(
                            lcs[(sourceIndex + 1) * columnCount + destinationIndex],
                            lcs[sourceIndex * columnCount + destinationIndex + 1]
                        )
                    }
                }
            }
        }

        var sourceIndex = 0
        var destinationIndex = 0
        var sourceHunk: [NumberedLine] = []
        var destinationHunk: [NumberedLine] = []
        var rows: [RawRow] = []

        func appendHunk() {
            let pairedCount = min(sourceHunk.count, destinationHunk.count)
            for index in 0..<pairedCount {
                rows.append((sourceHunk[index], destinationHunk[index], .modified))
            }
            for line in sourceHunk.dropFirst(pairedCount) {
                rows.append((line, nil, .inserted))
            }
            for line in destinationHunk.dropFirst(pairedCount) {
                rows.append((nil, line, .deleted))
            }
            sourceHunk.removeAll(keepingCapacity: true)
            destinationHunk.removeAll(keepingCapacity: true)
        }

        while sourceIndex < sourceLines.count || destinationIndex < destinationLines.count {
            if sourceIndex < sourceLines.count,
               destinationIndex < destinationLines.count,
               sourceLines[sourceIndex] == destinationLines[destinationIndex] {
                appendHunk()
                rows.append((
                    (sourceIndex + 1, sourceLines[sourceIndex]),
                    (destinationIndex + 1, destinationLines[destinationIndex]),
                    .unchanged
                ))
                sourceIndex += 1
                destinationIndex += 1
            } else if sourceIndex < sourceLines.count,
                      (destinationIndex == destinationLines.count ||
                       lcs[(sourceIndex + 1) * columnCount + destinationIndex] >= lcs[sourceIndex * columnCount + destinationIndex + 1]) {
                sourceHunk.append((sourceIndex + 1, sourceLines[sourceIndex]))
                sourceIndex += 1
            } else if destinationIndex < destinationLines.count {
                destinationHunk.append((destinationIndex + 1, destinationLines[destinationIndex]))
                destinationIndex += 1
            }
        }
        appendHunk()

        return rows.enumerated().map { index, row in
            LineDifference(
                id: index,
                sourceNumber: row.source?.number,
                source: row.source?.text,
                destinationNumber: row.destination?.number,
                destination: row.destination?.text,
                kind: row.kind
            )
        }
    }

    private static func positionalFallback(source: [String], destination: [String]) -> [LineDifference] {
        (0..<max(source.count, destination.count)).map { index in
            let sourceLine = index < source.count ? source[index] : nil
            let destinationLine = index < destination.count ? destination[index] : nil
            let kind: LineDifferenceKind
            if sourceLine == destinationLine { kind = .unchanged }
            else if destinationLine == nil { kind = .inserted }
            else if sourceLine == nil { kind = .deleted }
            else { kind = .modified }
            return LineDifference(
                id: index,
                sourceNumber: sourceLine == nil ? nil : index + 1,
                source: sourceLine,
                destinationNumber: destinationLine == nil ? nil : index + 1,
                destination: destinationLine,
                kind: kind
            )
        }
    }
}

struct FieldCodeReview: View {
    let sourceText: String
    let destinationText: String
    let rows: [LineDifference]
    let columnWidth: CGFloat

    init(field: FieldDifference) {
        sourceText = field.source?.description ?? "—"
        destinationText = field.destination?.description ?? "—"
        rows = LineDiffEngine.compare(source: sourceText, destination: destinationText)
        let longestLine = rows.flatMap { [$0.source ?? "", $0.destination ?? ""] }.map(\.count).max() ?? 0
        columnWidth = min(max(CGFloat(longestLine) * 8.2 + 92, 520), 2_000)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                diffLegend("Inserted from source", color: .green)
                diffLegend("Modified", color: .orange)
                diffLegend("Removed from destination", color: .red)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0) {
                    HStack(spacing: 0) {
                        reviewHeader("Source (incoming)", text: sourceText)
                        Divider()
                        reviewHeader("Destination (current)", text: destinationText)
                    }
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            DiffLineCell(number: row.sourceNumber, text: row.source, kind: row.kind, side: .source, width: columnWidth)
                            Divider()
                            DiffLineCell(number: row.destinationNumber, text: row.destination, kind: row.kind, side: .destination, width: columnWidth)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
        }
    }

    private func reviewHeader(_ title: String, text: String) -> some View {
        HStack {
            Text(title).font(.subheadline).fontWeight(.semibold)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(width: columnWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func diffLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.55)).frame(width: 10, height: 10)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum DiffSide {
    case source
    case destination
}

struct DiffLineCell: View {
    let number: Int?
    let text: String?
    let kind: LineDifferenceKind
    let side: DiffSide
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)
            Text(marker)
                .fontWeight(.bold)
                .foregroundStyle(markerColor)
                .frame(width: 22)
            Text(text ?? "")
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(width: width)
        .frame(minHeight: 22)
        .background(backgroundColor)
    }

    private var marker: String {
        switch (kind, side) {
        case (.inserted, .source): return "+"
        case (.deleted, .destination): return "−"
        case (.modified, _): return "~"
        default: return " "
        }
    }

    private var markerColor: Color {
        switch kind {
        case .inserted: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .unchanged: return .secondary
        }
    }

    private var backgroundColor: Color {
        switch (kind, side) {
        case (.inserted, .source): return .green.opacity(0.18)
        case (.modified, _): return .orange.opacity(0.16)
        case (.deleted, .destination): return .red.opacity(0.18)
        default: return .clear
        }
    }
}

// MARK: - History and app shell

struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedID: UUID?
    @State private var backup: MigrationBackup?
    @State private var detailError = ""
    @State private var reverting = false
    @State private var showRevertConfirmation = false
    @State private var revertMessage = ""
    @State private var inspectedDocument: BackupDocumentInspection?
    private let client = MongoShellClient()

    var body: some View {
        HSplitView {
            Table(store.history, selection: $selectedID) {
                TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }.width(160)
                TableColumn("Route") { Text("\($0.source) → \($0.destination)") }.width(min: 180, ideal: 240)
                TableColumn("Database") { Text($0.database) }.width(min: 160, ideal: 220)
                TableColumn("Collections") { Text($0.collections.joined(separator: ", ")) }.width(min: 140, ideal: 210)
                TableColumn("Mode") { Text($0.dryRun ? "Dry run" : "Applied") }.width(72)
                TableColumn("Changes") { Text("+\($0.inserts)  ~\($0.updates)  −\($0.deletions)") }.width(105)
                TableColumn("Status") { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.status).lineLimit(1)
                        if entry.revertedAt != nil {
                            Label("Reverted", systemImage: "arrow.uturn.backward.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .frame(minWidth: 720)
            .overlay {
                if store.history.isEmpty {
                    ContentUnavailableView("No migrations yet", systemImage: "clock.arrow.circlepath")
                }
            }

            detailPane
                .frame(minWidth: 400, idealWidth: 500)
        }
        .navigationTitle("Migration History")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedID == nil { selectedID = store.history.first?.id }
            loadSelectedBackup()
        }
        .onChange(of: selectedID) { loadSelectedBackup() }
        .alert("Revert this migration?", isPresented: $showRevertConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Revert migration", role: .destructive) { revertSelectedMigration() }
        } message: {
            Text("This restores the backed-up documents in the destination database and removes documents inserted by this migration. Any later edits to those records will be overwritten. Validator and index changes are not reverted.")
        }
        .sheet(item: $inspectedDocument) { inspection in
            FieldValueSheet(field: FieldDifference(
                path: "\(inspection.document.collection) • \(inspection.document.filter.description)",
                source: inspection.document.sourceDocument,
                destination: inspection.document.destinationDocument
            ))
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Migration details").font(.title2).fontWeight(.semibold)
                        Text("\(entry.source) → \(entry.destination)")
                            .font(.headline)
                        Text(entry.date.formatted(date: .complete, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        historyDetailRow("Database", entry.database)
                        historyDetailRow("Collections", entry.collections.joined(separator: ", "))
                        historyDetailRow("Mode", entry.dryRun ? "Dry run" : "Applied")
                        historyDetailRow("Changes", "+\(entry.inserts) inserted   ~\(entry.updates) modified   −\(entry.deletions) deleted")
                        historyDetailRow("Status", entry.status)
                        if let revertedAt = entry.revertedAt {
                            historyDetailRow("Reverted", revertedAt.formatted(date: .abbreviated, time: .standard))
                        }
                        if let revertStatus = entry.revertStatus {
                            historyDetailRow("Revert status", revertStatus)
                        }
                    }

                    Divider()

                    if let backup {
                        HStack {
                            Text("Document changes").font(.headline)
                            Text("\(backup.documents.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        if backup.documents.isEmpty {
                            Text("No document changes were stored for this migration.")
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(Array(backup.documents.enumerated()), id: \.offset) { _, document in
                                    backupDocumentRow(document)
                                }
                            }
                        }

                        if let schemaOperations = backup.schemaOperations, !schemaOperations.isEmpty {
                            DisclosureGroup("Schema changes (\(schemaOperations.count))") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(schemaOperations.enumerated()), id: \.offset) { _, operation in
                                        Text(operation.description)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(8)
                                            .background(Color(nsColor: .textBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }

                        Label("Rollback restores document data only. Validator and index changes are listed for review, but their previous definitions were not captured and cannot be restored automatically.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let path = entry.detailsPath ?? entry.backupPath {
                            Text(path)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    } else if !detailError.isEmpty {
                        Label(detailError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Detailed document data was not saved for this older history entry.")
                            .foregroundStyle(.secondary)
                    }

                    if !entry.dryRun,
                       entry.status == "Completed",
                       entry.revertedAt == nil,
                       destinationProfile(for: entry) == nil {
                        Label("The saved destination connection is required before this migration can be reverted.", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if !revertMessage.isEmpty {
                        Text(revertMessage)
                            .font(.callout)
                            .foregroundStyle(revertMessage.hasPrefix("Revert failed") ? .red : .secondary)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button(role: .destructive) {
                            showRevertConfirmation = true
                        } label: {
                            if reverting {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(entry.revertedAt == nil ? "Revert migration" : "Migration reverted", systemImage: "arrow.uturn.backward")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRevert(entry) || reverting)
                        Spacer()
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a migration", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var selectedEntry: HistoryEntry? {
        guard let selectedID else { return nil }
        return store.history.first(where: { $0.id == selectedID })
    }

    private func historyDetailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func backupDocumentRow(_ document: BackupDocument) -> some View {
        HStack(spacing: 10) {
            Label(migrationAction(for: document).capitalized, systemImage: migrationActionIcon(for: document))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(migrationActionColor(for: document))
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.collection).fontWeight(.medium)
                Text(document.filter.description)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let paths = document.selectedPaths, !paths.isEmpty {
                    Text("Fields: \(paths.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("View change") {
                inspectedDocument = BackupDocumentInspection(document: document)
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadSelectedBackup() {
        backup = nil
        detailError = ""
        revertMessage = ""
        guard let entry = selectedEntry, let path = entry.detailsPath ?? entry.backupPath else { return }
        do {
            backup = try BackupStore.load(path: path)
        } catch {
            detailError = "Could not read migration details: \(error.localizedDescription)"
        }
    }

    private func canRevert(_ entry: HistoryEntry) -> Bool {
        !entry.dryRun &&
        entry.status == "Completed" &&
        entry.revertedAt == nil &&
        backup?.documents.isEmpty == false &&
        destinationProfile(for: entry) != nil
    }

    private func destinationProfile(for entry: HistoryEntry) -> ConnectionProfile? {
        if let id = entry.destinationProfileID ?? backup?.destinationProfileID,
           let profile = store.profiles.first(where: { $0.id == id }) {
            return profile
        }
        return store.profiles.first(where: { $0.name == (backup?.destinationProfile ?? entry.destination) })
    }

    private func revertSelectedMigration() {
        guard let entry = selectedEntry,
              let backup,
              let profile = destinationProfile(for: entry) else { return }
        reverting = true
        revertMessage = "Restoring \(backup.documents.count) document(s)…"
        Task {
            do {
                let result = try await client.restore(profile: profile, database: backup.destinationDatabase, documents: backup.documents)
                if let index = store.history.firstIndex(where: { $0.id == entry.id }) {
                    var updated = store.history[index]
                    updated.revertedAt = Date()
                    updated.revertStatus = "Completed"
                    store.history[index] = updated
                }
                revertMessage = "Revert completed: \(result.description)"
            } catch {
                if let index = store.history.firstIndex(where: { $0.id == entry.id }) {
                    var updated = store.history[index]
                    updated.revertStatus = "Failed: \(error.localizedDescription)"
                    store.history[index] = updated
                }
                revertMessage = "Revert failed: \(error.localizedDescription)"
            }
            reverting = false
        }
    }

    private func migrationAction(for document: BackupDocument) -> String {
        document.migrationAction ?? (document.destinationDocument == nil ? "insert" : "change")
    }

    private func migrationActionIcon(for document: BackupDocument) -> String {
        switch migrationAction(for: document) {
        case "insert": return "plus.circle.fill"
        case "delete": return "minus.circle.fill"
        default: return "pencil.circle.fill"
        }
    }

    private func migrationActionColor(for document: BackupDocument) -> Color {
        switch migrationAction(for: document) {
        case "insert": return .green
        case "delete": return .red
        default: return .orange
        }
    }
}

struct BackupDocumentInspection: Identifiable {
    let id = UUID()
    let document: BackupDocument
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case compare = "Compare & Migrate"
    case connections = "Connections"
    case history = "History"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .compare: return "arrow.left.arrow.right"
        case .connections: return "externaldrive.connected.to.line.below"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct RootView: View {
    @State private var selection: SidebarItem? = .compare
    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("Mongo Migrator")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch selection {
                case .compare: CompareView()
                case .connections: ProfilesView()
                case .history: HistoryView()
                case nil: ContentUnavailableView("Select a section", systemImage: "sidebar.left")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@main
struct MongoMigratorApp: App {
    @StateObject private var store = AppStore()

    init() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 860)
        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mongo Migrator").font(.title2).fontWeight(.semibold)
                Text("Connection passwords are stored in macOS Keychain. Profile metadata and migration history remain on this Mac.")
                Text("MongoDB access uses the locally installed mongosh command-line client.").foregroundStyle(.secondary)
            }.padding().frame(width: 520)
        }
    }
}
