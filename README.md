# Mongo Migrator

Mongo Migrator is a native SwiftUI app for comparing and selectively synchronizing MongoDB data between environments. It supports local MongoDB deployments and MongoDB Atlas, stores credentials in macOS Keychain, and includes a local MCP server for AI coding agents such as Codex, Claude, and Pi.

The app is designed for controlled, on-demand workflows such as:

- Copying production configuration data back to staging.
- Promoting document structures and selected data from staging to production.
- Reviewing document, validator, and index differences before applying changes.
- Migrating complete documents or selected fields and subdocuments.

## Features

### Connection profiles

- Save multiple named environments, including Development, Staging, QA, and Production.
- Connect with `mongodb://` or `mongodb+srv://` connection strings.
- Use unauthenticated local connections or username/password authentication.
- Store passwords only in macOS Keychain.
- Test connections and discover available databases.

### Comparison and migration

- Compare one source database with one destination database.
- Select multiple shared collections in a migration.
- Match documents by `_id`, a unique field, or a compound key.
- Apply MongoDB filters and ignore environment-specific fields.
- Compare documents, collection validators, and indexes.
- Review field-level and nested-field differences.
- Choose whether to apply the source, keep the destination, or delete the destination document.
- Select individual fields and subdocuments for updates.
- Preview changes with dry-run mode.
- Require explicit confirmation before deletions.
- Create a local rollback backup before every applied migration.
- Keep local migration history and MCP audit records.

### MCP server

The bundled stdio MCP server exposes the saved connection profiles to compatible AI agents without returning connection strings or passwords. It provides tools to:

- List saved profiles, databases, and collections.
- Find documents with an Extended JSON filter.
- Compare documents, validators, and indexes.
- Prepare a short-lived migration plan and dry-run preview.
- Apply an approved plan using an exact confirmation phrase.

Write operations are separated into prepare and apply steps. The apply tool is marked as destructive, requires the confirmation returned by the prepared plan, expires plans after 30 minutes, creates a backup first, and consumes a plan after successful use.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode 16 or later with the Swift 6 toolchain
- Homebrew
- MongoDB Shell (`mongosh`)

Install `mongosh`:

```sh
brew install mongosh
```

## Build and run

Build the release app bundle:

```sh
./build-app.sh
```

The signed development build is created at:

```text
dist/Mongo Migrator.app
```

Launch it with:

```sh
open "dist/Mongo Migrator.app"
```

The build uses ad-hoc code signing for internal team distribution. It is not notarized or prepared for the Mac App Store.

## Getting started

1. Open **Connections** and create a profile for each MongoDB environment.
2. Enter the connection string and optional username/password authentication.
3. Select **Save & Test** to store the password in Keychain and verify access.
4. Open **Compare & Migrate**.
5. Select the source and destination profiles, then connect.
6. Select the source and destination databases and load their shared collections.
7. Choose collections, document matching fields, ignored fields, filters, and migration categories.
8. Compare the environments and review each document and field action.
9. Run a dry-run preview.
10. Disable dry-run mode and apply the migration when the preview is correct.

Production connections are identified visually, but production writes do not currently require a separate role or administrator approval. Review the destination profile carefully before applying a plan.

## MCP setup

Build the app before configuring an agent. The MCP executable is bundled at:

```text
dist/Mongo Migrator.app/Contents/MacOS/MongoMigratorMCP
```

Open the app and save or test the required profiles before using MCP tools.

### Codex

```sh
./mcp/codex-install.sh
codex mcp get mongo-migrator
```

### Claude Code

```sh
./mcp/claude-install.sh
claude mcp get mongo-migrator
```

The equivalent project configuration is available in [`mcp/claude.mcp.json`](mcp/claude.mcp.json).

### Pi

Pi requires an MCP client extension. The setup script installs `pi-mcp-extension` as a project package and writes `.pi/mcp.json`:

```sh
./mcp/pi-install.sh
```

Start Pi and use `/mcp` to inspect the connection. Review third-party Pi extensions before installing them in a sensitive environment.

The source configuration is available in [`mcp/pi.mcp.json`](mcp/pi.mcp.json).

## MCP tools

| Tool | Access | Purpose |
| --- | --- | --- |
| `mongo_list_profiles` | Read-only | List profile names, IDs, environments, and authentication modes. |
| `mongo_list_databases` | Read-only | List databases available to a saved profile. |
| `mongo_list_collections` | Read-only | List collections in a database. |
| `mongo_find_documents` | Read-only | Query documents with an optional Extended JSON filter. |
| `mongo_compare` | Read-only | Compare documents, validators, and indexes. |
| `mongo_prepare_migration` | Read-only | Create a dry-run plan, preview, expiration, and confirmation phrase. |
| `mongo_apply_migration` | Write/destructive | Apply an approved plan after creating a rollback backup. |

MCP audit records are written to:

```text
~/Library/Application Support/Mongo Migrator/mcp-audit.jsonl
```

## Security model

- Passwords are stored as generic password items in macOS Keychain.
- Saved profile metadata does not contain passwords.
- MCP profile listing does not expose connection strings or credentials.
- MongoDB credentials are passed to the local `mongosh` child process through its environment, not command-line arguments.
- MCP uses local stdio transport and does not open a network listener.
- Migration plans are held in MCP server memory and expire after 30 minutes.
- Applied migrations create local JSON rollback packages.
- Deletions require a distinct `DELETE AND APPLY <plan-id>` confirmation.

Rollback backups are stored at:

```text
~/Library/Application Support/Mongo Migrator/Backups/
```

Backups can contain sensitive destination data. Protect the macOS user account and remove obsolete backups according to the team's retention policy.

## Current scope and limitations

- Synchronization is on demand; change streams and continuous synchronization are not implemented.
- Authentication currently supports unauthenticated connections and username/password credentials.
- SSH tunnels, custom TLS certificate management, IAM, X.509, LDAP, and Kerberos are not included.
- The desktop comparison limit is 5,000 documents per collection; MCP limits requests to 1,000 documents.
- Collections must have matching names in both databases to appear in the desktop collection picker.
- Index synchronization creates or updates source indexes but does not automatically remove destination-only indexes.
- The app creates rollback packages but does not yet provide a one-click restore interface.
- The release bundle is intended for internal team use and is ad-hoc signed.

## Development

Build debug executables:

```sh
swift build
```

Run the SwiftUI executable directly:

```sh
swift run MongoMigrator
```

Run the MCP server directly over stdio:

```sh
swift run MongoMigratorMCP
```

Project layout:

```text
.
├── Package.swift
├── Sources
│   ├── MongoMigrator
│   │   └── main.swift
│   └── MongoMigratorMCP
│       └── main.swift
├── build-app.sh
├── Info.plist
└── mcp
    ├── claude-install.sh
    ├── claude.mcp.json
    ├── codex-install.sh
    ├── pi-install.sh
    └── pi.mcp.json
```

## License

No open-source license has been added. The repository is currently intended for internal team use.
