//! Core SQLite wrapper functions
//!
//! This module provides safe Zig wrappers around SQLite C API functions,
//! with proper error handling and memory management.

const std = @import("std");

// Import SQLite C API
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

// Error types
pub const SQLiteError = error{
    SQLError,
    InvalidDatabase,
    PrepareError,
    BindError,
    StepError,
    OpenError,
    CloseError,
};

// Helper function to create null-terminated C string
pub fn createCString(buf: []u8, str: []const u8) [*c]const u8 {
    std.mem.copyForwards(u8, buf[0..str.len], str);
    buf[str.len] = 0;
    return @ptrCast(buf.ptr);
}

// Core database operations

/// Open a SQLite database
pub fn open(path: []const u8) SQLiteError!*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    var buf: [512]u8 = undefined;
    const path_cstr = createCString(&buf, path);

    const rc = c.sqlite3_open(path_cstr, &db);
    if (rc != c.SQLITE_OK) {
        if (db) |database| {
            _ = c.sqlite3_close(database);
        }
        return SQLiteError.OpenError;
    }

    return db.?;
}

/// Close a SQLite database
pub fn close(db: *c.sqlite3) SQLiteError!void {
    const rc = c.sqlite3_close(db);
    if (rc != c.SQLITE_OK) {
        return SQLiteError.CloseError;
    }
}

/// Execute SQL without returning results
pub fn exec(db: *c.sqlite3, sql: []const u8) SQLiteError!void {
    var buf: [4096]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);

    var error_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql_cstr, null, null, &error_msg);

    if (rc != c.SQLITE_OK) {
        defer if (error_msg != null) c.sqlite3_free(error_msg);
        return SQLiteError.SQLError;
    }
}

/// Prepare a SQL statement
pub fn prepare(db: *c.sqlite3, sql: []const u8) SQLiteError!*c.sqlite3_stmt {
    var buf: [4096]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        return SQLiteError.PrepareError;
    }

    return stmt.?;
}

/// Execute a prepared statement step
pub fn step(stmt: *c.sqlite3_stmt) SQLiteError!c_int {
    const rc = c.sqlite3_step(stmt);
    return rc;
}

/// Finalize a prepared statement
pub fn finalize(stmt: *c.sqlite3_stmt) SQLiteError!void {
    const rc = c.sqlite3_finalize(stmt);
    if (rc != c.SQLITE_OK) {
        return SQLiteError.SQLError;
    }
}

// Binding functions

/// Bind text to a parameter
pub fn bind_text(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) SQLiteError!void {
    const rc = c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT);
    if (rc != c.SQLITE_OK) {
        return SQLiteError.BindError;
    }
}

/// Bind integer to a parameter
pub fn bind_int(stmt: *c.sqlite3_stmt, index: c_int, value: c_int) SQLiteError!void {
    const rc = c.sqlite3_bind_int(stmt, index, value);
    if (rc != c.SQLITE_OK) {
        return SQLiteError.BindError;
    }
}

/// Bind 64-bit integer to a parameter
pub fn bind_int64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) SQLiteError!void {
    const rc = c.sqlite3_bind_int64(stmt, index, value);
    if (rc != c.SQLITE_OK) {
        return SQLiteError.BindError;
    }
}

/// Bind double to a parameter
pub fn bind_double(stmt: *c.sqlite3_stmt, index: c_int, value: f64) SQLiteError!void {
    const rc = c.sqlite3_bind_double(stmt, index, value);
    if (rc != c.SQLITE_OK) {
        return SQLiteError.BindError;
    }
}

/// Bind null to a parameter
pub fn bind_null(stmt: *c.sqlite3_stmt, index: c_int) SQLiteError!void {
    const rc = c.sqlite3_bind_null(stmt, index);
    if (rc != c.SQLITE_OK) {
        return SQLiteError.BindError;
    }
}

// Column access functions

/// Get text from a column
pub fn column_text(stmt: *c.sqlite3_stmt, index: c_int) ?[]const u8 {
    const text_ptr = c.sqlite3_column_text(stmt, index);
    if (text_ptr == null) return null;

    const len = c.sqlite3_column_bytes(stmt, index);
    return @as([*]const u8, @ptrCast(text_ptr))[0..@intCast(len)];
}

/// Get integer from a column
pub fn column_int(stmt: *c.sqlite3_stmt, index: c_int) c_int {
    return c.sqlite3_column_int(stmt, index);
}

/// Get 64-bit integer from a column
pub fn column_int64(stmt: *c.sqlite3_stmt, index: c_int) i64 {
    return c.sqlite3_column_int64(stmt, index);
}

/// Get double from a column
pub fn column_double(stmt: *c.sqlite3_stmt, index: c_int) f64 {
    return c.sqlite3_column_double(stmt, index);
}

/// Get column count
pub fn column_count(stmt: *c.sqlite3_stmt) c_int {
    return c.sqlite3_column_count(stmt);
}

/// Get column name
pub fn column_name(stmt: *c.sqlite3_stmt, index: c_int) ?[]const u8 {
    const name_ptr = c.sqlite3_column_name(stmt, index);
    if (name_ptr == null) return null;

    return std.mem.span(name_ptr);
}

// Transaction functions

/// Check if database is in autocommit mode
pub fn get_autocommit(db: *c.sqlite3) bool {
    return c.sqlite3_get_autocommit(db) != 0;
}

/// Begin a transaction
pub fn begin_transaction(db: *c.sqlite3) SQLiteError!void {
    try exec(db, "BEGIN TRANSACTION");
}

/// Commit the current transaction
pub fn commit_transaction(db: *c.sqlite3) SQLiteError!void {
    try exec(db, "COMMIT");
}

/// Rollback the current transaction
pub fn rollback_transaction(db: *c.sqlite3) SQLiteError!void {
    try exec(db, "ROLLBACK");
}

// Information functions

/// Get number of changes from last operation
pub fn changes(db: *c.sqlite3) c_int {
    return c.sqlite3_changes(db);
}

/// Get total number of changes
pub fn total_changes(db: *c.sqlite3) c_int {
    return c.sqlite3_total_changes(db);
}

/// Get last insert rowid
pub fn last_insert_rowid(db: *c.sqlite3) i64 {
    return c.sqlite3_last_insert_rowid(db);
}

/// Get error message
pub fn errmsg(db: *c.sqlite3) []const u8 {
    return std.mem.span(c.sqlite3_errmsg(db));
}

/// Get SQLite version
pub fn libversion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

// Tests
const testing = std.testing;

test "sqlite basic operations" {
    // Test basic open/close
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(":memory:", &db);
    defer _ = c.sqlite3_close(db);

    try testing.expect(rc == c.SQLITE_OK);
    try testing.expect(db != null);
}

test "sqlite wrapper functions" {
    const db = try open(":memory:");
    defer close(db) catch {};

    // Test table creation
    try exec(db, "CREATE TABLE test (id INTEGER, name TEXT)");

    // Test prepared statement
    const stmt = try prepare(db, "INSERT INTO test (id, name) VALUES (?, ?)");
    defer finalize(stmt) catch {};

    try bind_int(stmt, 1, 42);
    try bind_text(stmt, 2, "test");

    const step_result = try step(stmt);
    try testing.expect(step_result == c.SQLITE_DONE);
}
