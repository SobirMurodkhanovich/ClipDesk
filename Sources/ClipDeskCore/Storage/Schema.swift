import Foundation

/// Database schema and ordered migrations. The applied version is stored in `PRAGMA user_version`.
enum Schema {
    struct Migration {
        let version: Int
        let sql: String
    }

    static let migrations: [Migration] = [
        Migration(version: 1, sql: """
            CREATE TABLE entries (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                is_screenshot INTEGER NOT NULL DEFAULT 0,
                title TEXT NOT NULL,
                preview_text TEXT NOT NULL DEFAULT '',
                search_text TEXT NOT NULL DEFAULT '',
                dedupe_key TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                use_count INTEGER NOT NULL DEFAULT 1,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                byte_count INTEGER NOT NULL DEFAULT 0,
                item_count INTEGER NOT NULL DEFAULT 1,
                type_identifiers TEXT NOT NULL DEFAULT '',
                payload_dir TEXT NOT NULL,
                thumbnail_path TEXT,
                source_app_name TEXT,
                source_app_bundle_id TEXT,
                metadata TEXT NOT NULL DEFAULT '{}'
            );
            CREATE UNIQUE INDEX entries_dedupe_key ON entries(dedupe_key);
            CREATE INDEX entries_last_used_at ON entries(last_used_at DESC);

            CREATE TABLE representations (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                item_index INTEGER NOT NULL,
                position INTEGER NOT NULL,
                type TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                inline_data BLOB,
                payload_file TEXT,
                PRIMARY KEY (entry_id, item_index, position)
            );

            CREATE TABLE files (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                original_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                type_identifier TEXT,
                byte_size INTEGER,
                is_directory INTEGER NOT NULL DEFAULT 0,
                modified_at REAL,
                stored_path TEXT,
                storage_state TEXT NOT NULL,
                PRIMARY KEY (entry_id, position)
            );
            """),
    ]

    static var latestVersion: Int { migrations.last?.version ?? 0 }

    static func configure(_ database: SQLiteDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("PRAGMA foreign_keys = ON")
        // Overwrite deleted content in the database file instead of leaving it in free pages.
        try database.execute("PRAGMA secure_delete = ON")
    }

    /// Applies pending migrations, each in its own transaction.
    static func migrate(_ database: SQLiteDatabase) throws {
        let current = try database.userVersion
        guard current <= latestVersion else {
            throw DatabaseError(code: -1, message: "The history database was created by a newer version of ClipDesk.")
        }
        for migration in migrations where migration.version > current {
            try database.transaction {
                try database.execute(migration.sql)
                try database.setUserVersion(migration.version)
            }
        }
    }

    /// Runs SQLite's integrity check. Returns false when the database is damaged.
    static func passesQuickCheck(_ database: SQLiteDatabase) -> Bool {
        let result = try? database.queryFirst("PRAGMA quick_check") { $0.string(0) }
        return result == "ok"
    }
}
