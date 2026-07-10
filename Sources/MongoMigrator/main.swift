import SwiftUI
import Security

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
}

struct BackupDocument: Codable {
    let collection: String
    let filter: JSONValue
    let destinationDocument: JSONValue?
}

struct MigrationBackup: Codable {
    let createdAt: Date
    let destinationProfile: String
    let destinationDatabase: String
    let documents: [BackupDocument]
}

enum BackupStore {
    static func create(destination: ConnectionProfile, database: String, differences: [DocumentDifference]) throws -> String {
        let documents = differences.compactMap { difference -> BackupDocument? in
            guard difference.action != .keepDestination else { return nil }
            return BackupDocument(collection: difference.collection, filter: difference.filter, destinationDocument: difference.destination)
        }
        let backup = MigrationBackup(createdAt: Date(), destinationProfile: destination.name, destinationDatabase: database, documents: documents)
        let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = applicationSupport.appendingPathComponent("Mongo Migrator/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let safeDate = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("migration-\(safeDate).json")
        try JSONEncoder.pretty.encode(backup).write(to: url, options: [.atomic, .completeFileProtection])
        return url.path
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
    private let defaults = UserDefaults(suiteName: "com.team.MongoMigrator") ?? .standard

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

    func documents(profile: ConnectionProfile, database: String, collection: String, filter: String, limit: Int) async throws -> [JSONValue] {
        let script = wrapped("""
            const query = input.filter ? EJSON.parse(input.filter) : {};
            return database.getCollection(input.collection).find(query).limit(input.limit).toArray();
        """)
        let input: JSONValue = .object([
            "filter": .string(filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : filter),
            "collection": .string(collection),
            "limit": .number(Double(limit))
        ])
        let value = try await run(profile: profile, database: database, script: script, input: input)
        guard case .array(let items) = value else { return [] }
        return items
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
                if case .object = pair.value { result.merge(flatten(pair.value, prefix: path)) { _, new in new } }
                else { result[path] = pair.value }
            }
        }
        return [prefix: value]
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

@MainActor
final class CompareViewModel: ObservableObject {
    @Published var sourceID: UUID?
    @Published var destinationID: UUID?
    @Published var sourceDatabases: [String] = []
    @Published var destinationDatabases: [String] = []
    @Published var sourceDatabase = ""
    @Published var destinationDatabase = ""
    @Published var collections: [String] = []
    @Published var selectedCollections: Set<String> = []
    @Published var matchMode: MatchMode = .objectID
    @Published var keyFields = ""
    @Published var ignoredFields = "createdAt, updatedAt"
    @Published var filter = "{}"
    @Published var limit = 1000
    @Published var differences: [DocumentDifference] = []
    @Published var selectedDifferenceID: UUID?
    @Published var loading = false
    @Published var message = ""
    @Published var dryRun = true
    @Published var showDeleteConfirmation = false
    private var deletionWasConfirmed = false
    @Published var includeDocuments = true
    @Published var includeValidators = false
    @Published var includeIndexes = false
    @Published var schemaOperations: [JSONValue] = []
    @Published var activityLog: [ActivityLogEntry] = []
    let client = MongoShellClient()

    var keyPaths: [String] {
        switch matchMode {
        case .objectID: return ["_id"]
        case .uniqueField, .compoundKey: return keyFields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
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
                message = "Found \(collections.count) matching collections"
                report("Found \(collections.count) collections with matching names.")
            } catch {
                message = error.localizedDescription
                report("Could not load collections: \(error.localizedDescription)", isError: true)
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
        guard !includeDocuments || !keyPaths.isEmpty else {
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
                        async let left = client.documents(profile: source, database: sourceDatabase, collection: collection, filter: filter, limit: limit)
                        async let right = client.documents(profile: destination, database: destinationDatabase, collection: collection, filter: filter, limit: limit)
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
            store.history.insert(HistoryEntry(date: Date(), source: source.name, destination: destination.name, database: "\(sourceDatabase) → \(destinationDatabase)", collections: selectedCollections.sorted(), dryRun: true, inserts: counts.0, updates: counts.1, deletions: counts.2, status: "Previewed"), at: 0)
            message = "Dry run: \(counts.0) inserts, \(counts.1) updates, \(counts.2) deletions"
            report(message)
            return
        }
        let backupPath: String
        do {
            backupPath = try BackupStore.create(destination: destination, database: destinationDatabase, differences: differences)
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
                store.history.insert(HistoryEntry(date: Date(), source: source.name, destination: destination.name, database: "\(sourceDatabase) → \(destinationDatabase)", collections: selectedCollections.sorted(), dryRun: false, inserts: counts.0, updates: counts.1, deletions: counts.2, status: "Completed", backupPath: backupPath), at: 0)
                message = "Migration completed"
                report("Migration completed. Rollback backup: \(backupPath)")
            } catch {
                store.history.insert(HistoryEntry(date: Date(), source: source.name, destination: destination.name, database: "\(sourceDatabase) → \(destinationDatabase)", collections: selectedCollections.sorted(), dryRun: false, inserts: counts.0, updates: counts.1, deletions: counts.2, status: "Failed: \(error.localizedDescription)", backupPath: backupPath), at: 0)
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

    private func report(_ text: String, isError: Bool = false) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        activityLog.append(ActivityLogEntry(timestamp: timestamp, message: text, isError: isError))
        if activityLog.count > 500 { activityLog.removeFirst(activityLog.count - 500) }
    }

    private func buildOperations() -> JSONValue {
        var values = differences.compactMap { difference -> JSONValue? in
            switch difference.action {
            case .keepDestination: return nil
            case .deleteDestination:
                return .object(["collection": .string(difference.collection), "action": .string("delete"), "filter": difference.filter])
            case .applySource:
                guard let source = difference.source else { return nil }
                if difference.destination == nil {
                    return .object(["collection": .string(difference.collection), "action": .string("insert"), "document": source])
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

    var body: some View {
        VStack(spacing: 0) {
            configuration
            Divider()
            if model.differences.isEmpty && model.schemaOperations.isEmpty {
                ContentUnavailableView(model.loading ? "Comparing…" : "Ready to compare", systemImage: "arrow.left.arrow.right", description: Text("Choose two saved connections, databases, and matching collections."))
            } else {
                results
            }
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
    }

    private var configuration: some View {
        VStack(spacing: 12) {
            HStack {
                profilePicker("Source", selection: $model.sourceID)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                profilePicker("Destination", selection: $model.destinationID)
                Button("Connect") { model.loadDatabases(profiles: store.profiles) }.disabled(model.loading || model.sourceID == nil || model.destinationID == nil)
            }
            HStack {
                Picker("Source database", selection: $model.sourceDatabase) { ForEach(model.sourceDatabases, id: \.self) { Text($0) } }.frame(maxWidth: .infinity)
                Picker("Destination database", selection: $model.destinationDatabase) { ForEach(model.destinationDatabases, id: \.self) { Text($0) } }.frame(maxWidth: .infinity)
                Button("Load collections") { model.loadCollections(profiles: store.profiles) }.disabled(model.loading || model.sourceDatabase.isEmpty || model.destinationDatabase.isEmpty)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("Collections").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(model.collections, id: \.self) { collection in
                                Toggle(collection, isOn: Binding(get: { model.selectedCollections.contains(collection) }, set: { selected in
                                    if selected { model.selectedCollections.insert(collection) } else { model.selectedCollections.remove(collection) }
                                })).toggleStyle(.button)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Picker("Match by", selection: $model.matchMode) { ForEach(MatchMode.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 220)
                if model.matchMode != .objectID {
                    TextField(model.matchMode == .compoundKey ? "Fields separated by commas" : "Unique field", text: $model.keyFields)
                }
                TextField("Ignored fields, comma separated", text: $model.ignoredFields)
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
                    TableColumn("Difference") { Text($0.kind.rawValue) }.width(130)
                    TableColumn("Action") { difference in
                        Picker("", selection: actionBinding(for: difference.id)) {
                            ForEach(MigrationAction.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                    }.width(160)
                }.frame(minWidth: 520)

                if let difference = model.differences.first(where: { $0.id == model.selectedDifferenceID }) {
                    DifferenceDetail(difference: differenceBinding(for: difference.id))
                        .frame(minWidth: 430)
                } else {
                    ContentUnavailableView("No document selected", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
    }

    private func differenceBinding(for id: UUID) -> Binding<DocumentDifference> {
        Binding(get: { model.differences.first(where: { $0.id == id })! }, set: { value in
            if let index = model.differences.firstIndex(where: { $0.id == id }) { model.differences[index] = value }
        })
    }

    private func actionBinding(for id: UUID) -> Binding<MigrationAction> {
        Binding(get: { model.differences.first(where: { $0.id == id })?.action ?? .keepDestination }, set: { action in
            if let index = model.differences.firstIndex(where: { $0.id == id }) { model.differences[index].action = action }
        })
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
            }
            HStack {
                Button("Select all") { difference.selectedPaths = Set(difference.fields.map(\.path)) }
                Button("Select none") { difference.selectedPaths.removeAll() }
                Spacer()
            }
        }.padding()
    }
}

// MARK: - History and app shell

struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Table(store.history) {
            TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }.width(160)
            TableColumn("Route") { Text("\($0.source) → \($0.destination)") }.width(min: 180, ideal: 260)
            TableColumn("Database") { Text($0.database) }.width(min: 150, ideal: 220)
            TableColumn("Collections") { Text($0.collections.joined(separator: ", ")) }.width(min: 150, ideal: 240)
            TableColumn("Mode") { Text($0.dryRun ? "Dry run" : "Applied") }.width(80)
            TableColumn("Changes") { Text("+\($0.inserts)  ~\($0.updates)  −\($0.deletions)") }.width(110)
            TableColumn("Status") { Text($0.status) }
        }
        .navigationTitle("Migration History")
        .overlay { if store.history.isEmpty { ContentUnavailableView("No migrations yet", systemImage: "clock.arrow.circlepath") } }
    }
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
            switch selection {
            case .compare: CompareView()
            case .connections: ProfilesView()
            case .history: HistoryView()
            case nil: ContentUnavailableView("Select a section", systemImage: "sidebar.left")
            }
        }
    }
}

@main
struct MongoMigratorApp: App {
    @StateObject private var store = AppStore()
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
