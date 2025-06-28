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

// Function to create a test table
fn createTable(db: ?*c.sqlite3) !void {
    const create_sql =
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    email TEXT UNIQUE,
        \\    age INTEGER
        \\);
    ;
    try executeSQL(db, create_sql);
}

// Function to insert data using prepared statements
fn insertUser(db: ?*c.sqlite3, name: []const u8, email: []const u8, age: i32) !void {
    const insert_sql = "INSERT INTO users (name, email, age) VALUES (?, ?, ?)";
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
    _ = c.sqlite3_bind_int(stmt, 3, age);

    // Execute
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        std.debug.print("Failed to insert user: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.InsertError;
    }

    std.debug.print("Inserted user: {s} ({s}), age {}\n", .{ name, email, age });
}

// Function to query and display users
fn queryUsers(db: ?*c.sqlite3) !void {
    const query_sql = "SELECT id, name, email, age FROM users ORDER BY id";
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, query_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("\n=== Users in database ===\n", .{});
    std.debug.print("ID | Name | Email | Age\n", .{});
    std.debug.print("---|------|-------|----\n", .{});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int(stmt, 0);
        const name = c.sqlite3_column_text(stmt, 1);
        const email = c.sqlite3_column_text(stmt, 2);
        const age = c.sqlite3_column_int(stmt, 3);

        std.debug.print("{} | {s} | {s} | {}\n", .{ id, name, email, age });
    }
    std.debug.print("=========================\n\n", .{});
}

pub fn main() !void {
    std.debug.print("zsqlite Demo\n", .{});
    std.debug.print("============\n\n", .{});

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

    // Create table
    std.debug.print("Creating table...\n", .{});
    try createTable(db);
    std.debug.print("✓ Table created\n\n", .{});

    // Insert some test data
    std.debug.print("Inserting test data...\n", .{});
    try insertUser(db, "Alice Johnson", "alice@example.com", 28);
    try insertUser(db, "Bob Smith", "bob@example.com", 35);
    try insertUser(db, "Charlie Brown", "charlie@example.com", 42);
    std.debug.print("✓ Test data inserted\n\n", .{});

    // Query and display data
    std.debug.print("Querying data...\n", .{});
    try queryUsers(db);

    // Demonstrate error handling with duplicate email
    std.debug.print("Testing constraint violation...\n", .{});
    insertUser(db, "Alice Clone", "alice@example.com", 30) catch |err| {
        std.debug.print("✓ Caught expected error: {}\n\n", .{err});
    };

    std.debug.print("Demo completed successfully!\n", .{});
}
