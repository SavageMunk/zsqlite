const std = @import("std");
const zsqlite = @import("lib.zig");

pub fn main() !void {
    std.debug.print("ZSQLite Library Test\n", .{});
    std.debug.print("Version: {s}\n", .{zsqlite.version});
    std.debug.print("Description: {s}\n", .{zsqlite.description});

    // Test opening a database using the library
    const db = try zsqlite.open(":memory:");
    defer zsqlite.close(db) catch {};

    // Test executing SQL
    try zsqlite.exec(db, "CREATE TABLE test (id INTEGER, name TEXT)");
    try zsqlite.exec(db, "INSERT INTO test VALUES (1, 'Hello')");

    // Test prepared statements
    const stmt = try zsqlite.prepare(db, "SELECT * FROM test WHERE id = ?");
    defer zsqlite.finalize(stmt) catch {};

    try zsqlite.bind_int(stmt, 1, 1);

    const step_result = try zsqlite.step(stmt);
    if (step_result == zsqlite.c.SQLITE_ROW) {
        const id = zsqlite.column_int(stmt, 0);
        const name = zsqlite.column_text(stmt, 1);
        std.debug.print("Found row: id={d}, name={s}\n", .{ id, name orelse "NULL" });
    }

    std.debug.print("✅ ZSQLite library test completed successfully!\n", .{});
}
