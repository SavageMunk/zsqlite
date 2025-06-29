//! ZSQLite Library Usage Demo
//!
//! This demonstrates how to use ZSQLite as a library dependency

const std = @import("std");
const zsqlite = @import("zsqlite");

pub fn main() !void {
    std.debug.print("ZSQLite Library Demo\n", .{});
    std.debug.print("Using ZSQLite as a library dependency\n\n", .{});

    // Test basic library functionality
    var db: ?*zsqlite.c.sqlite3 = null;
    const rc = zsqlite.c.sqlite3_open(":memory:", &db);
    defer _ = zsqlite.c.sqlite3_close(db);

    if (rc != zsqlite.c.SQLITE_OK) {
        std.debug.print("❌ Failed to open database\n", .{});
        return;
    }

    std.debug.print("✅ Database opened successfully\n", .{});

    // Create a table
    const create_sql = "CREATE TABLE demo (id INTEGER PRIMARY KEY, message TEXT)";
    _ = zsqlite.c.sqlite3_exec(db, create_sql, null, null, null);

    // Insert some data
    const insert_sql = "INSERT INTO demo (message) VALUES ('Hello from ZSQLite!')";
    _ = zsqlite.c.sqlite3_exec(db, insert_sql, null, null, null);

    // Query the data
    var stmt: ?*zsqlite.c.sqlite3_stmt = null;
    _ = zsqlite.c.sqlite3_prepare_v2(db, "SELECT * FROM demo", -1, &stmt, null);
    defer _ = zsqlite.c.sqlite3_finalize(stmt);

    if (zsqlite.c.sqlite3_step(stmt) == zsqlite.c.SQLITE_ROW) {
        const id = zsqlite.c.sqlite3_column_int(stmt, 0);
        const message = zsqlite.c.sqlite3_column_text(stmt, 1);
        std.debug.print("Found row: id={d}, message={s}\n", .{ id, message });
    }

    std.debug.print("✅ ZSQLite library demo completed successfully!\n", .{});
}
