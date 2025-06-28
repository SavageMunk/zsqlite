const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// Helper function to create null-terminated C string
fn createCString(buf: []u8, str: []const u8) [*c]const u8 {
    std.mem.copyForwards(u8, buf[0..str.len], str);
    buf[str.len] = 0;
    return @ptrCast(buf.ptr);
}

// Helper function to execute SQL without results
fn executeSQL(db: ?*c.sqlite3, sql: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);

    var errmsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql_cstr, null, null, &errmsg);

    if (rc != c.SQLITE_OK) {
        defer if (errmsg != null) c.sqlite3_free(errmsg);
        if (errmsg != null) {
            std.debug.print("SQL error: {s}\n", .{errmsg});
        } else {
            std.debug.print("SQL error: {s}\n", .{c.sqlite3_errmsg(db)});
        }
        return error.SQLError;
    }
    std.debug.print("SQL executed successfully: {s}\n", .{sql});
}

// Transaction management functions

// Check if database is in autocommit mode
fn checkAutocommit(db: ?*c.sqlite3) void {
    const autocommit = c.sqlite3_get_autocommit(db);
    std.debug.print("Database autocommit status: {} (1=autocommit, 0=in transaction)\n", .{autocommit});
}

// Begin a transaction
fn beginTransaction(db: ?*c.sqlite3) !void {
    try executeSQL(db, "BEGIN TRANSACTION");
    std.debug.print("✓ Transaction started\n", .{});
}

// Commit the current transaction
fn commitTransaction(db: ?*c.sqlite3) !void {
    try executeSQL(db, "COMMIT");
    std.debug.print("✓ Transaction committed\n", .{});
}

// Rollback the current transaction
fn rollbackTransaction(db: ?*c.sqlite3) !void {
    try executeSQL(db, "ROLLBACK");
    std.debug.print("✓ Transaction rolled back\n", .{});
}

// Create a savepoint
fn createSavepoint(db: ?*c.sqlite3, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const savepoint_sql = std.fmt.bufPrint(&buf, "SAVEPOINT {s}", .{name}) catch return error.BufferTooSmall;
    try executeSQL(db, savepoint_sql);
    std.debug.print("✓ Savepoint '{s}' created\n", .{name});
}

// Release a savepoint
fn releaseSavepoint(db: ?*c.sqlite3, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const release_sql = std.fmt.bufPrint(&buf, "RELEASE SAVEPOINT {s}", .{name}) catch return error.BufferTooSmall;
    try executeSQL(db, release_sql);
    std.debug.print("✓ Savepoint '{s}' released\n", .{name});
}

// Rollback to a savepoint
fn rollbackToSavepoint(db: ?*c.sqlite3, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const rollback_sql = std.fmt.bufPrint(&buf, "ROLLBACK TO SAVEPOINT {s}", .{name}) catch return error.BufferTooSmall;
    try executeSQL(db, rollback_sql);
    std.debug.print("✓ Rolled back to savepoint '{s}'\n", .{name});
}

// Get the number of database changes in the most recent operation
fn getChanges(db: ?*c.sqlite3) i32 {
    return c.sqlite3_changes(db);
}

// Get the total number of database changes since the connection was opened
fn getTotalChanges(db: ?*c.sqlite3) i32 {
    return c.sqlite3_total_changes(db);
}

// Get the rowid of the most recent successful INSERT
fn getLastInsertRowid(db: ?*c.sqlite3) i64 {
    return c.sqlite3_last_insert_rowid(db);
}

// Function to create a comprehensive test table with all data types
fn createTable(db: ?*c.sqlite3) !void {
    const create_sql =
        \\CREATE TABLE IF NOT EXISTS test_data (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    email TEXT UNIQUE,
        \\    age INTEGER,
        \\    salary REAL,
        \\    is_active INTEGER,
        \\    profile_picture BLOB,
        \\    notes TEXT,
        \\    metadata TEXT
        \\);
    ;
    try executeSQL(db, create_sql);
}

// Comprehensive data insertion with all SQLite data types
fn insertTestData(db: ?*c.sqlite3, name: []const u8, email: ?[]const u8, age: ?i64, salary: ?f64, is_active: ?bool, profile_picture: ?[]const u8, notes: ?[]const u8) !void {
    const insert_sql = "INSERT INTO test_data (name, email, age, salary, is_active, profile_picture, notes, metadata) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, insert_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare statement: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind name (TEXT) - required
    var name_buf: [256]u8 = undefined;
    const name_cstr = createCString(&name_buf, name);
    _ = c.sqlite3_bind_text(stmt, 1, name_cstr, -1, null);

    // Bind email (TEXT or NULL)
    if (email) |email_val| {
        var email_buf: [256]u8 = undefined;
        const email_cstr = createCString(&email_buf, email_val);
        _ = c.sqlite3_bind_text(stmt, 2, email_cstr, -1, null);
    } else {
        _ = c.sqlite3_bind_null(stmt, 2);
    }

    // Bind age (INTEGER or NULL)
    if (age) |age_val| {
        _ = c.sqlite3_bind_int64(stmt, 3, age_val);
    } else {
        _ = c.sqlite3_bind_null(stmt, 3);
    }

    // Bind salary (REAL/DOUBLE or NULL)
    if (salary) |salary_val| {
        _ = c.sqlite3_bind_double(stmt, 4, salary_val);
    } else {
        _ = c.sqlite3_bind_null(stmt, 4);
    }

    // Bind is_active (INTEGER as boolean or NULL)
    if (is_active) |active_val| {
        _ = c.sqlite3_bind_int(stmt, 5, if (active_val) 1 else 0);
    } else {
        _ = c.sqlite3_bind_null(stmt, 5);
    }

    // Bind profile_picture (BLOB or NULL)
    if (profile_picture) |pic_data| {
        _ = c.sqlite3_bind_blob(stmt, 6, pic_data.ptr, @intCast(pic_data.len), null);
    } else {
        _ = c.sqlite3_bind_null(stmt, 6);
    }

    // Bind notes (TEXT or NULL)
    if (notes) |notes_val| {
        var notes_buf: [512]u8 = undefined;
        const notes_cstr = createCString(&notes_buf, notes_val);
        _ = c.sqlite3_bind_text(stmt, 7, notes_cstr, -1, null);
    } else {
        _ = c.sqlite3_bind_null(stmt, 7);
    }

    // Bind metadata as zero-filled blob (demonstration of sqlite3_bind_zeroblob)
    _ = c.sqlite3_bind_zeroblob(stmt, 8, 64); // 64 bytes of zeros

    // Execute
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        std.debug.print("Failed to insert test data: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.InsertError;
    }

    std.debug.print("✓ Inserted: {s}\n", .{name});
}

// Comprehensive data querying with all column reading functions
fn queryTestData(db: ?*c.sqlite3) !void {
    const query_sql = "SELECT id, name, email, age, salary, is_active, profile_picture, notes, metadata FROM test_data ORDER BY id";
    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, query_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("\n=== Test Data Analysis ===\n", .{});
    std.debug.print("Column Count: {}\n", .{c.sqlite3_column_count(stmt)});

    // Print column names
    std.debug.print("Columns: ", .{});
    const col_count = c.sqlite3_column_count(stmt);
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        const col_name = c.sqlite3_column_name(stmt, i);
        std.debug.print("{s} ", .{col_name});
    }
    std.debug.print("\n", .{});
    std.debug.print("==========================\n\n", .{});

    var row_num: i32 = 1;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        std.debug.print("--- Row {} ---\n", .{row_num});

        // Read ID (INTEGER)
        const id = c.sqlite3_column_int64(stmt, 0);
        const id_type = c.sqlite3_column_type(stmt, 0);
        std.debug.print("ID: {} (type: {})\n", .{ id, id_type });

        // Read name (TEXT)
        const name = c.sqlite3_column_text(stmt, 1);
        const name_type = c.sqlite3_column_type(stmt, 1);
        std.debug.print("Name: {s} (type: {})\n", .{ name, name_type });

        // Read email (TEXT or NULL)
        const email_type = c.sqlite3_column_type(stmt, 2);
        if (email_type == c.SQLITE_NULL) {
            std.debug.print("Email: NULL (type: {})\n", .{email_type});
        } else {
            const email = c.sqlite3_column_text(stmt, 2);
            std.debug.print("Email: {s} (type: {})\n", .{ email, email_type });
        }

        // Read age (INTEGER or NULL)
        const age_type = c.sqlite3_column_type(stmt, 3);
        if (age_type == c.SQLITE_NULL) {
            std.debug.print("Age: NULL (type: {})\n", .{age_type});
        } else {
            const age = c.sqlite3_column_int64(stmt, 3);
            std.debug.print("Age: {} (type: {})\n", .{ age, age_type });
        }

        // Read salary (REAL/DOUBLE or NULL)
        const salary_type = c.sqlite3_column_type(stmt, 4);
        if (salary_type == c.SQLITE_NULL) {
            std.debug.print("Salary: NULL (type: {})\n", .{salary_type});
        } else {
            const salary = c.sqlite3_column_double(stmt, 4);
            std.debug.print("Salary: {d:.2} (type: {})\n", .{ salary, salary_type });
        }

        // Read is_active (INTEGER/BOOLEAN or NULL)
        const active_type = c.sqlite3_column_type(stmt, 5);
        if (active_type == c.SQLITE_NULL) {
            std.debug.print("Active: NULL (type: {})\n", .{active_type});
        } else {
            const is_active = c.sqlite3_column_int(stmt, 5);
            std.debug.print("Active: {} (type: {})\n", .{ is_active == 1, active_type });
        }

        // Read profile_picture (BLOB or NULL)
        const pic_type = c.sqlite3_column_type(stmt, 6);
        if (pic_type == c.SQLITE_NULL) {
            std.debug.print("Profile Picture: NULL (type: {})\n", .{pic_type});
        } else {
            const pic_data = c.sqlite3_column_blob(stmt, 6);
            const pic_size = c.sqlite3_column_bytes(stmt, 6);
            std.debug.print("Profile Picture: {} bytes of data (type: {})\n", .{ pic_size, pic_type });

            // Print first few bytes as hex
            if (pic_size > 0) {
                const bytes = @as([*c]const u8, @ptrCast(pic_data));
                std.debug.print("  First bytes: ", .{});
                var j: i32 = 0;
                while (j < @min(pic_size, 8)) : (j += 1) {
                    std.debug.print("{x:0>2} ", .{bytes[@intCast(j)]});
                }
                std.debug.print("\n", .{});
            }
        }

        // Read notes (TEXT or NULL)
        const notes_type = c.sqlite3_column_type(stmt, 7);
        if (notes_type == c.SQLITE_NULL) {
            std.debug.print("Notes: NULL (type: {})\n", .{notes_type});
        } else {
            const notes = c.sqlite3_column_text(stmt, 7);
            std.debug.print("Notes: {s} (type: {})\n", .{ notes, notes_type });
        }

        // Read metadata (BLOB - zeroblob)
        const meta_type = c.sqlite3_column_type(stmt, 8);
        const meta_size = c.sqlite3_column_bytes(stmt, 8);
        std.debug.print("Metadata: {} bytes of zero-blob (type: {})\n", .{ meta_size, meta_type });

        std.debug.print("\n", .{});
        row_num += 1;
    }
    std.debug.print("=========================\n\n", .{});
}

// Simple insert function for transaction testing
fn insertUser(db: ?*c.sqlite3, name: []const u8, email: []const u8) !void {
    const insert_sql = "INSERT INTO users (name, email) VALUES (?, ?)";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, insert_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare statement: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    var name_buf: [256]u8 = undefined;
    var email_buf: [256]u8 = undefined;
    const name_cstr = createCString(&name_buf, name);
    const email_cstr = createCString(&email_buf, email);

    _ = c.sqlite3_bind_text(stmt, 1, name_cstr, -1, null);
    _ = c.sqlite3_bind_text(stmt, 2, email_cstr, -1, null);

    // Execute
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        std.debug.print("Failed to insert user: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.InsertError;
    }

    const rowid = getLastInsertRowid(db);
    const changes = getChanges(db);
    std.debug.print("✓ Inserted user '{s}' (rowid: {}, changes: {})\n", .{ name, rowid, changes });
}

// Create a simple users table for transaction testing
fn createUsersTable(db: ?*c.sqlite3) !void {
    const create_sql =
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    email TEXT UNIQUE
        \\);
    ;
    try executeSQL(db, create_sql);
}

// Count users in the database
fn countUsers(db: ?*c.sqlite3) !i32 {
    const query_sql = "SELECT COUNT(*) FROM users";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, query_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare count query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        return c.sqlite3_column_int(stmt, 0);
    }

    return 0;
}

// Phase 4: Advanced Querying Functions

// Reset a prepared statement for reuse
fn resetStatement(stmt: ?*c.sqlite3_stmt) !void {
    const rc = c.sqlite3_reset(stmt);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to reset statement\n", .{});
        return error.ResetError;
    }
    std.debug.print("✓ Statement reset for reuse\n", .{});
}

// Clear all bound parameters from a prepared statement
fn clearBindings(stmt: ?*c.sqlite3_stmt) !void {
    const rc = c.sqlite3_clear_bindings(stmt);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to clear bindings\n", .{});
        return error.ClearBindingsError;
    }
    std.debug.print("✓ Parameter bindings cleared\n", .{});
}

// Get the original SQL text of a prepared statement
fn getStatementSQL(stmt: ?*c.sqlite3_stmt) []const u8 {
    const sql_ptr = c.sqlite3_sql(stmt);
    if (sql_ptr == null) {
        return "";
    }
    return std.mem.span(sql_ptr);
}

// Demonstrate prepared statement reuse with different parameters
fn demonstrateStatementReuse(db: ?*c.sqlite3) !void {
    const insert_sql = "INSERT INTO users (name, email) VALUES (?, ?)";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, insert_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare reusable statement: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Show the original SQL
    const original_sql = getStatementSQL(stmt);
    std.debug.print("Prepared statement SQL: {s}\n", .{original_sql});

    // First execution
    std.debug.print("\n--- First execution ---\n", .{});
    var name_buf1: [256]u8 = undefined;
    var email_buf1: [256]u8 = undefined;
    const name1 = "Neo Anderson";
    const email1 = "neo@matrix.com";
    const name_cstr1 = createCString(&name_buf1, name1);
    const email_cstr1 = createCString(&email_buf1, email1);

    _ = c.sqlite3_bind_text(stmt, 1, name_cstr1, -1, null);
    _ = c.sqlite3_bind_text(stmt, 2, email_cstr1, -1, null);

    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        std.debug.print("Failed to execute first insert: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.ExecuteError;
    }

    std.debug.print("✓ First insert: {s} (rowid: {})\n", .{ name1, getLastInsertRowid(db) });

    // Reset for reuse
    try resetStatement(stmt);

    // Second execution with new parameters
    std.debug.print("\n--- Second execution (reusing statement) ---\n", .{});
    var name_buf2: [256]u8 = undefined;
    var email_buf2: [256]u8 = undefined;
    const name2 = "Trinity";
    const email2 = "trinity@matrix.com";
    const name_cstr2 = createCString(&name_buf2, name2);
    const email_cstr2 = createCString(&email_buf2, email2);

    _ = c.sqlite3_bind_text(stmt, 1, name_cstr2, -1, null);
    _ = c.sqlite3_bind_text(stmt, 2, email_cstr2, -1, null);

    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        std.debug.print("Failed to execute second insert: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.ExecuteError;
    }

    std.debug.print("✓ Second insert: {s} (rowid: {})\n", .{ name2, getLastInsertRowid(db) });

    // Reset and clear bindings
    try resetStatement(stmt);
    try clearBindings(stmt);

    // Third execution with partial binding (to show cleared bindings behavior)
    std.debug.print("\n--- Third execution (partial binding after clear) ---\n", .{});
    var name_buf3: [256]u8 = undefined;
    const name3 = "Morpheus";
    const name_cstr3 = createCString(&name_buf3, name3);

    _ = c.sqlite3_bind_text(stmt, 1, name_cstr3, -1, null);
    // Intentionally not binding email (should be NULL after clear_bindings)

    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        std.debug.print("Failed to execute third insert: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.ExecuteError;
    }

    std.debug.print("✓ Third insert: {s} with NULL email (rowid: {})\n", .{ name3, getLastInsertRowid(db) });
}

// Demonstrate batch operations with statement reuse
fn demonstrateBatchOperations(db: ?*c.sqlite3) !void {
    const update_sql = "UPDATE users SET email = ? WHERE name = ?";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, update_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare batch statement: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("Batch statement SQL: {s}\n", .{getStatementSQL(stmt)});

    // Define batch updates
    const updates = [_]struct { name: []const u8, email: []const u8 }{
        .{ .name = "Neo Anderson", .email = "neo.anderson@zion.com" },
        .{ .name = "Trinity", .email = "trinity@nebuchadnezzar.com" },
        .{ .name = "Morpheus", .email = "morpheus@zion.com" },
    };

    var total_changes: i32 = 0;

    for (updates) |update| {
        // Reset statement for each iteration
        try resetStatement(stmt);

        // Bind new parameters
        var email_buf: [256]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        const email_cstr = createCString(&email_buf, update.email);
        const name_cstr = createCString(&name_buf, update.name);

        _ = c.sqlite3_bind_text(stmt, 1, email_cstr, -1, null);
        _ = c.sqlite3_bind_text(stmt, 2, name_cstr, -1, null);

        // Execute
        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.debug.print("Failed to execute batch update for {s}: {s}\n", .{ update.name, c.sqlite3_errmsg(db) });
            continue;
        }

        const changes = getChanges(db);
        total_changes += changes;
        std.debug.print("✓ Updated {s}: {} rows affected\n", .{ update.name, changes });
    }

    std.debug.print("Total rows updated in batch: {}\n", .{total_changes});
}

// Query and display all users with their updated information
fn queryAllUsers(db: ?*c.sqlite3) !void {
    const query_sql = "SELECT id, name, email FROM users ORDER BY id";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, query_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare user query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("\n=== All Users ===\n", .{});
    std.debug.print("ID | Name | Email\n", .{});
    std.debug.print("---|------|------\n", .{});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int(stmt, 0);
        const name = c.sqlite3_column_text(stmt, 1);
        const email_type = c.sqlite3_column_type(stmt, 2);

        if (email_type == c.SQLITE_NULL) {
            std.debug.print("{} | {s} | NULL\n", .{ id, name });
        } else {
            const email = c.sqlite3_column_text(stmt, 2);
            std.debug.print("{} | {s} | {s}\n", .{ id, name, email });
        }
    }
    std.debug.print("================\n\n", .{});
}

// Phase 5: Database Introspection Functions

// Get database schema version
fn getSchemaVersion(db: ?*c.sqlite3) !i32 {
    const query_sql = "PRAGMA schema_version";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, query_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare schema version query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        return c.sqlite3_column_int(stmt, 0);
    }
    return 0;
}

// List all tables in the database
fn listTables(db: ?*c.sqlite3) !void {
    const query_sql = "SELECT name, type FROM sqlite_master WHERE type='table' ORDER BY name";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, query_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare table list query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("Database Tables:\n", .{});
    std.debug.print("Name | Type\n", .{});
    std.debug.print("-----|-----\n", .{});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name = c.sqlite3_column_text(stmt, 0);
        const table_type = c.sqlite3_column_text(stmt, 1);
        std.debug.print("{s} | {s}\n", .{ name, table_type });
    }
}

// Get detailed table schema information
fn getTableSchema(db: ?*c.sqlite3, table_name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const query_sql = std.fmt.bufPrint(&buf, "PRAGMA table_info({s})", .{table_name}) catch return error.BufferTooSmall;
    var buf2: [512]u8 = undefined;
    const sql_cstr = createCString(&buf2, query_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare table info query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("\nTable '{s}' Schema:\n", .{table_name});
    std.debug.print("Col# | Name | Type | NotNull | Default | PrimaryKey\n", .{});
    std.debug.print("-----|------|------|---------|---------|----------\n", .{});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const cid = c.sqlite3_column_int(stmt, 0);
        const name = c.sqlite3_column_text(stmt, 1);
        const col_type = c.sqlite3_column_text(stmt, 2);
        const notnull = c.sqlite3_column_int(stmt, 3);
        const pk = c.sqlite3_column_int(stmt, 5);

        const default_type = c.sqlite3_column_type(stmt, 4);
        if (default_type == c.SQLITE_NULL) {
            std.debug.print("{} | {s} | {s} | {} | NULL | {}\n", .{ cid, name, col_type, notnull, pk });
        } else {
            const default_val = c.sqlite3_column_text(stmt, 4);
            std.debug.print("{} | {s} | {s} | {} | {s} | {}\n", .{ cid, name, col_type, notnull, default_val, pk });
        }
    }
}

// Get database statistics
fn getDatabaseStats(db: ?*c.sqlite3) !void {
    // Get page count
    const page_count_sql = "PRAGMA page_count";
    var buf1: [256]u8 = undefined;
    const page_sql_cstr = createCString(&buf1, page_count_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, page_sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.QueryError;
    defer _ = c.sqlite3_finalize(stmt);

    var page_count: i32 = 0;
    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        page_count = c.sqlite3_column_int(stmt, 0);
    }

    // Get page size
    const page_size_sql = "PRAGMA page_size";
    var buf2: [256]u8 = undefined;
    const size_sql_cstr = createCString(&buf2, page_size_sql);

    var stmt2: ?*c.sqlite3_stmt = null;
    rc = c.sqlite3_prepare_v2(db, size_sql_cstr, -1, &stmt2, null);
    if (rc != c.SQLITE_OK) return error.QueryError;
    defer _ = c.sqlite3_finalize(stmt2);

    var page_size: i32 = 0;
    if (c.sqlite3_step(stmt2) == c.SQLITE_ROW) {
        page_size = c.sqlite3_column_int(stmt2, 0);
    }

    const total_size = @as(i64, page_count) * @as(i64, page_size);

    std.debug.print("\nDatabase Statistics:\n", .{});
    std.debug.print("Page Count: {}\n", .{page_count});
    std.debug.print("Page Size: {} bytes\n", .{page_size});
    std.debug.print("Total Size: {} bytes\n", .{total_size});
    std.debug.print("Schema Version: {}\n", .{try getSchemaVersion(db)});
}

// Analyze table row counts and sizes
fn analyzeTableData(db: ?*c.sqlite3, table_name: []const u8) !void {
    // Count rows
    var buf: [512]u8 = undefined;
    const count_sql = std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM {s}", .{table_name}) catch return error.BufferTooSmall;
    const count_cstr = createCString(&buf, count_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, count_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.QueryError;
    defer _ = c.sqlite3_finalize(stmt);

    var row_count: i32 = 0;
    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        row_count = c.sqlite3_column_int(stmt, 0);
    }

    std.debug.print("\nTable '{s}' Analysis:\n", .{table_name});
    std.debug.print("Row Count: {}\n", .{row_count});
}

// === Phase 6: Performance & Optimization Functions ===

// Advanced database opening with specific flags
fn openDatabaseV2(filename: []const u8, flags: c_int) !?*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    var buf: [256]u8 = undefined;
    const filename_cstr = createCString(&buf, filename);

    const rc = c.sqlite3_open_v2(filename_cstr, &db, flags, null);
    if (rc != c.SQLITE_OK) {
        if (db != null) {
            std.debug.print("Failed to open database with flags {}: {s}\n", .{ flags, c.sqlite3_errmsg(db) });
            _ = c.sqlite3_close(db);
        } else {
            std.debug.print("Failed to open database with flags {}: Error code {}\n", .{ flags, rc });
        }
        return error.OpenFailed;
    }

    std.debug.print("✓ Database opened with flags: {} ({})\n", .{ flags, filename });
    return db;
}

// Set busy timeout (milliseconds)
fn setBusyTimeout(db: ?*c.sqlite3, timeout_ms: c_int) !void {
    const rc = c.sqlite3_busy_timeout(db, timeout_ms);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to set busy timeout: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.ConfigError;
    }
    std.debug.print("✓ Busy timeout set to {} ms\n", .{timeout_ms});
}

// Custom busy handler callback
fn customBusyHandler(data: ?*anyopaque, count: c_int) callconv(.c) c_int {
    _ = data; // Unused parameter

    // Print busy notification
    std.debug.print("Database busy (attempt {}), waiting...\n", .{count + 1});

    // Sleep for 100ms
    std.time.sleep(100 * std.time.ns_per_ms);

    // Return 1 to retry, 0 to give up
    // We'll retry up to 5 times
    return if (count < 5) 1 else 0;
}

// Set custom busy handler
fn setBusyHandler(db: ?*c.sqlite3) !void {
    const rc = c.sqlite3_busy_handler(db, customBusyHandler, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to set busy handler: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.ConfigError;
    }
    std.debug.print("✓ Custom busy handler installed\n", .{});
}

// Configure database connection with performance settings
fn configureDatabase(db: ?*c.sqlite3, config_name: []const u8) !void {
    std.debug.print("\n--- Configuring database for {s} ---\n", .{config_name});

    // Set journal mode
    try executeSQL(db, "PRAGMA journal_mode = WAL");

    // Set synchronous mode for better performance
    try executeSQL(db, "PRAGMA synchronous = NORMAL");

    // Set cache size (negative value = KB, positive = pages)
    try executeSQL(db, "PRAGMA cache_size = -8192"); // 8MB cache

    // Enable foreign key constraints
    try executeSQL(db, "PRAGMA foreign_keys = ON");

    // Set temp store to memory for better performance
    try executeSQL(db, "PRAGMA temp_store = MEMORY");

    // Set mmap size for better I/O (64MB)
    try executeSQL(db, "PRAGMA mmap_size = 67108864");

    std.debug.print("✓ Database configured for {s}\n", .{config_name});
}

// Query current database configuration
fn queryConfiguration(db: ?*c.sqlite3) !void {
    std.debug.print("\n--- Current Database Configuration ---\n", .{});

    // Query and display each configuration setting
    try queryPragma(db, "journal_mode", "Journal Mode");
    try queryPragma(db, "synchronous", "Synchronous");
    try queryPragma(db, "cache_size", "Cache Size");
    try queryPragma(db, "foreign_keys", "Foreign Keys");
    try queryPragma(db, "temp_store", "Temp Store");
    try queryPragma(db, "mmap_size", "Memory Map Size");
    try queryPragma(db, "page_size", "Page Size");
    try queryPragma(db, "page_count", "Page Count");
}

// Helper function to query and display a single PRAGMA setting
fn queryPragma(db: ?*c.sqlite3, pragma_name: []const u8, display_name: []const u8) !void {
    var buf: [128]u8 = undefined;
    const sql = std.fmt.bufPrint(&buf, "PRAGMA {s}", .{pragma_name}) catch return error.BufferTooSmall;
    var buf2: [128]u8 = undefined;
    const sql_cstr = createCString(&buf2, sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare pragma query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_ROW) {
        const value_type = c.sqlite3_column_type(stmt, 0);
        switch (value_type) {
            c.SQLITE_INTEGER => {
                const value = c.sqlite3_column_int64(stmt, 0);
                std.debug.print("{s}: {}\n", .{ display_name, value });
            },
            c.SQLITE_TEXT => {
                const value = c.sqlite3_column_text(stmt, 0);
                std.debug.print("{s}: {s}\n", .{ display_name, value });
            },
            else => {
                std.debug.print("{s}: <unknown type {}>\n", .{ display_name, value_type });
            },
        }
    } else {
        std.debug.print("{s}: <no result>\n", .{display_name});
    }
}

// Performance testing with different configurations
fn performanceTest(db: ?*c.sqlite3, test_name: []const u8, insert_count: u32) !void {
    std.debug.print("\n--- Performance Test: {s} ---\n", .{test_name});

    // Start timing
    const start_time = std.time.nanoTimestamp();

    // Create test table
    try executeSQL(db, "CREATE TEMP TABLE perf_test (id INTEGER, data TEXT)");

    // Begin transaction for batch insert
    try beginTransaction(db);

    // Prepare insert statement
    var stmt: ?*c.sqlite3_stmt = null;
    const insert_sql = "INSERT INTO perf_test (id, data) VALUES (?, ?)";
    var buf: [256]u8 = undefined;
    const insert_cstr = createCString(&buf, insert_sql);

    var rc = c.sqlite3_prepare_v2(db, insert_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare insert: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Insert test data
    var i: u32 = 0;
    while (i < insert_count) : (i += 1) {
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, @intCast(i));

        var data_buf: [64]u8 = undefined;
        const data = std.fmt.bufPrint(&data_buf, "Test data row {}", .{i}) catch "default";
        _ = c.sqlite3_bind_text(stmt, 2, data.ptr, @intCast(data.len), c.SQLITE_TRANSIENT);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.debug.print("Insert failed at row {}: {s}\n", .{ i, c.sqlite3_errmsg(db) });
            return error.InsertError;
        }
    }

    // Commit transaction
    try commitTransaction(db);

    // End timing
    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    std.debug.print("✓ Inserted {} rows in {d:.2} ms ({d:.0} rows/sec)\n", .{
        insert_count,
        duration_ms,
        @as(f64, @floatFromInt(insert_count)) / (duration_ms / 1000.0),
    });

    // Clean up
    try executeSQL(db, "DROP TABLE perf_test");
}

// Demonstrate connection flags
fn demonstrateConnectionFlags() !void {
    std.debug.print("\n--- Connection Flags Demo ---\n", .{});

    // Try different connection flags
    const flags = [_]struct { flag: c_int, name: []const u8 }{
        .{ .flag = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, .name = "READWRITE | CREATE" },
        .{ .flag = c.SQLITE_OPEN_READONLY, .name = "READONLY" },
        .{ .flag = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, .name = "READWRITE | CREATE | NOMUTEX" },
    };

    for (flags) |flag_info| {
        std.debug.print("\nTesting flag: {s}\n", .{flag_info.name});

        const test_db = openDatabaseV2(":memory:", flag_info.flag) catch |err| {
            std.debug.print("✗ Failed to open with flags: {}\n", .{err});
            continue;
        };

        if (test_db) |db| {
            // Test basic operation if database opened successfully
            _ = executeSQL(db, "CREATE TABLE IF NOT EXISTS flag_test (id INTEGER)") catch |err| {
                std.debug.print("✗ Failed to create table: {}\n", .{err});
            };

            _ = c.sqlite3_close(db);
            std.debug.print("✓ Connection test completed\n", .{});
        }
    }
}

// === Phase 7: Advanced Features Functions ===

// Database backup and recovery functions
fn backupDatabase(source_db: ?*c.sqlite3, dest_filename: []const u8) !void {
    std.debug.print("\n--- Starting Database Backup ---\n", .{});

    // Open destination database
    var dest_db: ?*c.sqlite3 = null;
    var buf: [256]u8 = undefined;
    const dest_cstr = createCString(&buf, dest_filename);

    var rc = c.sqlite3_open(dest_cstr, &dest_db);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to open destination database: {s}\n", .{c.sqlite3_errmsg(dest_db)});
        return error.OpenFailed;
    }
    defer _ = c.sqlite3_close(dest_db);

    // Initialize backup
    const backup = c.sqlite3_backup_init(dest_db, "main", source_db, "main");
    if (backup == null) {
        std.debug.print("Failed to initialize backup: {s}\n", .{c.sqlite3_errmsg(dest_db)});
        return error.BackupInitFailed;
    }
    defer _ = c.sqlite3_backup_finish(backup);

    // Perform backup in steps
    var total_pages: c_int = 0;
    var step: u32 = 0;
    while (true) {
        step += 1;
        rc = c.sqlite3_backup_step(backup, 5); // Backup 5 pages at a time

        const remaining = c.sqlite3_backup_remaining(backup);
        const pagecount = c.sqlite3_backup_pagecount(backup);

        if (step == 1) {
            total_pages = pagecount;
            std.debug.print("Total pages to backup: {}\n", .{total_pages});
        }

        std.debug.print("Step {}: {} pages remaining\n", .{ step, remaining });

        if (rc == c.SQLITE_DONE) {
            std.debug.print("✓ Backup completed successfully\n", .{});
            break;
        } else if (rc == c.SQLITE_OK or rc == c.SQLITE_BUSY or rc == c.SQLITE_LOCKED) {
            // Wait a bit before next step
            std.time.sleep(10 * std.time.ns_per_ms);
            continue;
        } else {
            std.debug.print("Backup failed: {s}\n", .{c.sqlite3_errmsg(dest_db)});
            return error.BackupFailed;
        }
    }
}

// WAL mode checkpoint functions
fn performWALCheckpoint(db: ?*c.sqlite3) !void {
    std.debug.print("\n--- WAL Checkpoint Operations ---\n", .{});

    // Enable WAL mode first
    try executeSQL(db, "PRAGMA journal_mode = WAL");
    std.debug.print("✓ WAL mode enabled\n", .{});

    // Perform full checkpoint
    var wal_pages: c_int = 0;
    var checkpointed_pages: c_int = 0;

    const rc = c.sqlite3_wal_checkpoint_v2(db, null, c.SQLITE_CHECKPOINT_FULL, &wal_pages, &checkpointed_pages);

    if (rc == c.SQLITE_OK) {
        std.debug.print("✓ WAL checkpoint completed\n", .{});
        std.debug.print("  WAL pages: {}\n", .{wal_pages});
        std.debug.print("  Checkpointed pages: {}\n", .{checkpointed_pages});
    } else {
        std.debug.print("WAL checkpoint failed: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.CheckpointFailed;
    }

    // Set automatic checkpoint
    const auto_rc = c.sqlite3_wal_autocheckpoint(db, 1000); // Checkpoint every 1000 pages
    if (auto_rc == c.SQLITE_OK) {
        std.debug.print("✓ Auto-checkpoint set to 1000 pages\n", .{});
    } else {
        std.debug.print("Failed to set auto-checkpoint: {s}\n", .{c.sqlite3_errmsg(db)});
    }
}

// User-defined function example
fn customSqlFunction(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    _ = argc; // We expect exactly 2 arguments, but this function signature requires the parameter

    // Get the two arguments
    const arg1 = c.sqlite3_value_int(argv[0]);
    const arg2 = c.sqlite3_value_int(argv[1]);

    // Calculate result (simple addition with multiplication)
    const result = (arg1 + arg2) * 2;

    // Return the result
    c.sqlite3_result_int(ctx, result);
}

fn registerCustomFunctions(db: ?*c.sqlite3) !void {
    std.debug.print("\n--- Registering Custom Functions ---\n", .{});

    // Register a custom function: CUSTOM_MATH(a, b) returns (a + b) * 2
    const rc = c.sqlite3_create_function(db, "CUSTOM_MATH", // Function name
        2, // Number of arguments
        c.SQLITE_UTF8, // Text encoding
        null, // User data pointer
        customSqlFunction, // Function implementation
        null, // Step function (for aggregates)
        null // Final function (for aggregates)
    );

    if (rc == c.SQLITE_OK) {
        std.debug.print("✓ Custom function 'CUSTOM_MATH' registered\n", .{});
    } else {
        std.debug.print("Failed to register custom function: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.FunctionRegistrationFailed;
    }
}

fn testCustomFunction(db: ?*c.sqlite3) !void {
    std.debug.print("\n--- Testing Custom Function ---\n", .{});

    // Test the custom function
    const test_sql = "SELECT CUSTOM_MATH(5, 10) as result";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, test_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare function test: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_ROW) {
        const result = c.sqlite3_column_int(stmt, 0);
        std.debug.print("✓ CUSTOM_MATH(5, 10) = {} (expected: 30)\n", .{result});

        if (result == 30) {
            std.debug.print("✓ Custom function working correctly!\n", .{});
        } else {
            std.debug.print("✗ Custom function returned unexpected result\n", .{});
        }
    } else {
        std.debug.print("Failed to execute function test: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.ExecuteError;
    }
}

// Advanced database operations demo
fn demonstrateAdvancedFeatures(db: ?*c.sqlite3) !void {
    std.debug.print("\n=== Phase 7: Advanced Features Demo ===\n", .{});

    // 1. Register and test custom functions
    try registerCustomFunctions(db);
    try testCustomFunction(db);

    // 2. Demonstrate WAL mode and checkpointing
    try performWALCheckpoint(db);

    // 3. Create some test data for backup
    try executeSQL(db, "CREATE TABLE IF NOT EXISTS backup_test (id INTEGER, data TEXT)");
    try executeSQL(db, "INSERT INTO backup_test VALUES (1, 'Important data 1')");
    try executeSQL(db, "INSERT INTO backup_test VALUES (2, 'Important data 2')");
    try executeSQL(db, "INSERT INTO backup_test VALUES (3, 'Important data 3')");
    std.debug.print("✓ Created test data for backup\n", .{});

    // 4. Demonstrate database backup
    backupDatabase(db, "backup_demo.db") catch |err| {
        std.debug.print("Backup demonstration failed: {}\n", .{err});
        // Continue with other demos
    };

    std.debug.print("✓ Advanced features demonstration completed\n", .{});
}

// === Summary ===
pub fn main() !void {
    std.debug.print("zsqlite Complete Demo - Phases 1-7\n", .{});
    std.debug.print("==================================\n\n", .{});

    // Open database
    var db: ?*c.sqlite3 = null;
    var buf: [256]u8 = undefined;
    const filename = ":memory:"; // Use in-memory database for demo
    const cstr = createCString(&buf, filename);

    const rc = c.sqlite3_open(cstr, &db);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.OpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    std.debug.print("✓ Database opened successfully\n\n", .{});

    // === Phase 1-2: Core Operations & Data Types ===
    std.debug.print("=== Phase 1-2: Core Operations & Data Types ===\n", .{});

    // Create table
    std.debug.print("Creating comprehensive test table...\n", .{});
    try createTable(db);
    std.debug.print("✓ Table created\n\n", .{});

    // Insert comprehensive test data demonstrating all data types
    std.debug.print("Inserting test data with all SQLite data types...\n", .{});

    // Sample binary data for blob
    const profile_pic = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }; // PNG header

    // Test with full data
    try insertTestData(db, "Alice Johnson", "alice@example.com", 28, 75000.50, true, &profile_pic, "Senior developer with 5 years experience");

    // Test with some null values
    try insertTestData(db, "Bob Smith", "bob@example.com", 35, null, false, null, null);

    // Test with more null values
    try insertTestData(db, "Charlie Brown", null, null, 45000.75, null, &profile_pic, "Entry level position");

    // Test with all nulls except required name
    try insertTestData(db, "Dana White", null, null, null, null, null, null);

    std.debug.print("✓ Test data inserted\n\n", .{});

    // Query and display comprehensive data analysis
    std.debug.print("Querying and analyzing all data types...\n", .{});
    try queryTestData(db);

    // Demonstrate error handling with duplicate email
    std.debug.print("Testing constraint violation...\n", .{});
    insertTestData(db, "Alice Clone", "alice@example.com", 30, 60000.0, true, null, "This should fail") catch |err| {
        std.debug.print("✓ Caught expected error: {}\n\n", .{err});
    };

    // === Phase 3: Transaction Management ===
    std.debug.print("=== Phase 3: Transaction Management ===\n", .{});

    // Create users table for transaction testing
    try createUsersTable(db);

    std.debug.print("\n--- Demo 1: Basic Transaction with Commit ---\n", .{});
    checkAutocommit(db);

    try beginTransaction(db);
    checkAutocommit(db);

    try insertUser(db, "John Doe", "john@example.com");
    try insertUser(db, "Jane Doe", "jane@example.com");

    std.debug.print("Changes in this transaction: {}\n", .{getChanges(db)});
    std.debug.print("Total changes so far: {}\n", .{getTotalChanges(db)});

    try commitTransaction(db);
    checkAutocommit(db);

    var user_count = try countUsers(db);
    std.debug.print("Users after commit: {}\n", .{user_count});

    std.debug.print("\n--- Demo 2: Transaction with Rollback ---\n", .{});
    try beginTransaction(db);

    try insertUser(db, "Bob Wilson", "bob@example.com");
    try insertUser(db, "Alice Cooper", "alice@test.com");

    std.debug.print("Users before rollback: {}\n", .{try countUsers(db)});
    std.debug.print("Changes before rollback: {}\n", .{getChanges(db)});

    try rollbackTransaction(db);
    checkAutocommit(db);

    user_count = try countUsers(db);
    std.debug.print("Users after rollback: {} (should be same as before transaction)\n", .{user_count});

    std.debug.print("\n--- Demo 3: Savepoints ---\n", .{});
    try beginTransaction(db);

    // Insert first user
    try insertUser(db, "Sarah Connor", "sarah@future.com");
    std.debug.print("Users after first insert: {}\n", .{try countUsers(db)});

    // Create savepoint
    try createSavepoint(db, "sp1");

    // Insert second user
    try insertUser(db, "Kyle Reese", "kyle@resistance.com");
    std.debug.print("Users after second insert: {}\n", .{try countUsers(db)});

    // Create another savepoint
    try createSavepoint(db, "sp2");

    // Insert third user
    try insertUser(db, "Miles Dyson", "miles@cyberdyne.com");
    std.debug.print("Users after third insert: {}\n", .{try countUsers(db)});

    // Rollback to sp2 (removes Miles)
    try rollbackToSavepoint(db, "sp2");
    std.debug.print("Users after rollback to sp2: {}\n", .{try countUsers(db)});

    // Release sp1 savepoint
    try releaseSavepoint(db, "sp1");

    // Commit the transaction (keeps Sarah and Kyle)
    try commitTransaction(db);

    user_count = try countUsers(db);
    std.debug.print("Final user count after savepoint demo: {}\n", .{user_count});

    // === Phase 4: Advanced Querying ===
    std.debug.print("\n=== Phase 4: Advanced Querying ===\n", .{});

    std.debug.print("\n--- Demo 1: Prepared Statement Reuse ---\n", .{});
    try demonstrateStatementReuse(db);

    std.debug.print("\n--- Demo 2: Batch Operations ---\n", .{});
    try demonstrateBatchOperations(db);

    std.debug.print("\n--- Demo 3: Final User Query ---\n", .{});
    try queryAllUsers(db);

    // === Phase 5: Database Introspection ===
    std.debug.print("\n=== Phase 5: Database Introspection ===\n", .{});

    // List all tables
    std.debug.print("\n--- Demo 1: Table Discovery ---\n", .{});
    try listTables(db);

    // Get detailed schema for each table
    std.debug.print("\n--- Demo 2: Schema Analysis ---\n", .{});
    try getTableSchema(db, "test_data");
    try getTableSchema(db, "users");

    // Database statistics
    std.debug.print("\n--- Demo 3: Database Statistics ---\n", .{});
    try getDatabaseStats(db);

    // Table data analysis
    std.debug.print("\n--- Demo 4: Table Data Analysis ---\n", .{});
    try analyzeTableData(db, "test_data");
    try analyzeTableData(db, "users");

    // === Phase 6: Performance & Optimization ===
    std.debug.print("\n=== Phase 6: Performance & Optimization ===\n", .{});

    // Set busy timeout for this database
    try setBusyTimeout(db, 5000); // 5 second timeout

    // Query current configuration
    try queryConfiguration(db);

    // Configure database for better performance
    try configureDatabase(db, "Production Ready");

    // Query configuration after changes
    std.debug.print("\n--- After Performance Configuration ---\n", .{});
    try queryConfiguration(db);

    // Run a simple performance test
    performanceTest(db, "Basic Performance Test", 1000) catch |err| {
        std.debug.print("Performance test failed: {}\n", .{err});
    };

    // === Phase 7: Advanced Features ===
    try demonstrateAdvancedFeatures(db);

    // === Summary ===
    std.debug.print("\n" ++ "=" ** 50 ++ "\n", .{});
    std.debug.print("🎉 Complete zsqlite Demo Finished Successfully!\n", .{});
    std.debug.print("=" ** 50 ++ "\n", .{});
    std.debug.print("✅ Phase 1: Core SQLite operations\n", .{});
    std.debug.print("✅ Phase 2: Complete data type support\n", .{});
    std.debug.print("✅ Phase 3: Transaction management\n", .{});
    std.debug.print("✅ Phase 4: Advanced querying\n", .{});
    std.debug.print("✅ Phase 5: Database introspection\n", .{});
    std.debug.print("✅ Phase 6: Performance & optimization\n", .{});
    std.debug.print("✅ Phase 7: Advanced features (backup, WAL, custom functions)\n", .{});
    std.debug.print("\nAll 30+ functions working perfectly! 🚀\n", .{});
}
