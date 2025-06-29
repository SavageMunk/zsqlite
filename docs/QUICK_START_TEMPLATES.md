# ZSQLite Quick Start Templates

Ready-to-use code templates for common ZSQLite use cases.

## Template 1: Basic CRUD Operations

```zig
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); });

pub fn main() !void {
    var db: ?*c.sqlite3 = null;
    var buf: [256]u8 = undefined;
    
    // Open database
    const filename = "app.db";
    std.mem.copyForwards(u8, buf[0..filename.len], filename);
    buf[filename.len] = 0;
    
    var rc = c.sqlite3_open(&buf, &db);
    if (rc != c.SQLITE_OK) return error.OpenFailed;
    defer _ = c.sqlite3_close(db);
    
    // CREATE
    try createTable(db);
    
    // INSERT
    const user_id = try insertUser(db, "Alice", "alice@example.com");
    std.debug.print("Created user with ID: {}\n", .{user_id});
    
    // SELECT
    try selectUsers(db);
    
    // UPDATE
    try updateUser(db, user_id, "Alice Smith");
    
    // DELETE
    try deleteUser(db, user_id);
}

fn createTable(db: ?*c.sqlite3) !void {
    const sql = 
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    email TEXT UNIQUE NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    ;
    
    const rc = c.sqlite3_exec(db, sql, null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Create table error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.CreateTableError;
    }
}

fn insertUser(db: ?*c.sqlite3, name: []const u8, email: []const u8) !i64 {
    const sql = "INSERT INTO users (name, email) VALUES (?, ?)";
    var stmt: ?*c.sqlite3_stmt = null;
    
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, email.ptr, @intCast(email.len), c.SQLITE_STATIC);
    
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.InsertError;
    
    return c.sqlite3_last_insert_rowid(db);
}

fn selectUsers(db: ?*c.sqlite3) !void {
    const sql = "SELECT id, name, email, created_at FROM users";
    var stmt: ?*c.sqlite3_stmt = null;
    
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    std.debug.print("Users:\n");
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(stmt, 0);
        const name = c.sqlite3_column_text(stmt, 1);
        const email = c.sqlite3_column_text(stmt, 2);
        const created_at = c.sqlite3_column_text(stmt, 3);
        
        const name_len = c.sqlite3_column_bytes(stmt, 1);
        const email_len = c.sqlite3_column_bytes(stmt, 2);
        const created_len = c.sqlite3_column_bytes(stmt, 3);
        
        std.debug.print("  {}: {s} <{s}> (created: {s})\n", .{
            id,
            name[0..@intCast(name_len)],
            email[0..@intCast(email_len)],
            created_at[0..@intCast(created_len)]
        });
    }
}

fn updateUser(db: ?*c.sqlite3, id: i64, new_name: []const u8) !void {
    const sql = "UPDATE users SET name = ? WHERE id = ?";
    var stmt: ?*c.sqlite3_stmt = null;
    
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    _ = c.sqlite3_bind_text(stmt, 1, new_name.ptr, @intCast(new_name.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_int64(stmt, 2, id);
    
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.UpdateError;
    
    const changes = c.sqlite3_changes(db);
    std.debug.print("Updated {} row(s)\n", .{changes});
}

fn deleteUser(db: ?*c.sqlite3, id: i64) !void {
    const sql = "DELETE FROM users WHERE id = ?";
    var stmt: ?*c.sqlite3_stmt = null;
    
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.DeleteError;
    
    const changes = c.sqlite3_changes(db);
    std.debug.print("Deleted {} row(s)\n", .{changes});
}
```

## Template 2: Transaction Management

```zig
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); });

pub fn transferMoney(db: ?*c.sqlite3, from_account: i64, to_account: i64, amount: f64) !void {
    // Begin transaction
    var rc = c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, null);
    if (rc != c.SQLITE_OK) return error.TransactionError;
    
    // Ensure rollback on error
    errdefer _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
    
    // Check source account balance
    const balance = try getAccountBalance(db, from_account);
    if (balance < amount) {
        return error.InsufficientFunds;
    }
    
    // Debit source account
    try updateAccountBalance(db, from_account, -amount);
    
    // Credit destination account
    try updateAccountBalance(db, to_account, amount);
    
    // Log transaction
    try logTransaction(db, from_account, to_account, amount);
    
    // Commit transaction
    rc = c.sqlite3_exec(db, "COMMIT", null, null, null);
    if (rc != c.SQLITE_OK) return error.CommitError;
    
    std.debug.print("Transfer completed: ${d:.2} from {} to {}\n", .{amount, from_account, to_account});
}

fn getAccountBalance(db: ?*c.sqlite3, account_id: i64) !f64 {
    const sql = "SELECT balance FROM accounts WHERE id = ?";
    var stmt: ?*c.sqlite3_stmt = null;
    
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    _ = c.sqlite3_bind_int64(stmt, 1, account_id);
    
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_ROW) return error.AccountNotFound;
    
    return c.sqlite3_column_double(stmt, 0);
}

fn updateAccountBalance(db: ?*c.sqlite3, account_id: i64, delta: f64) !void {
    const sql = "UPDATE accounts SET balance = balance + ? WHERE id = ?";
    var stmt: ?*c.sqlite3_stmt = null;
    
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    _ = c.sqlite3_bind_double(stmt, 1, delta);
    _ = c.sqlite3_bind_int64(stmt, 2, account_id);
    
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.UpdateError;
}
```

## Template 3: Bulk Operations

```zig
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); });

const User = struct {
    name: []const u8,
    email: []const u8,
    age: i32,
};

pub fn bulkInsertUsers(db: ?*c.sqlite3, users: []const User) !void {
    // Begin transaction for better performance
    var rc = c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, null);
    if (rc != c.SQLITE_OK) return error.TransactionError;
    
    errdefer _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
    
    const sql = "INSERT INTO users (name, email, age) VALUES (?, ?, ?)";
    var stmt: ?*c.sqlite3_stmt = null;
    
    rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    for (users) |user| {
        // Bind parameters
        _ = c.sqlite3_bind_text(stmt, 1, user.name.ptr, @intCast(user.name.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, user.email.ptr, @intCast(user.email.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int(stmt, 3, user.age);
        
        // Execute
        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            std.debug.print("Failed to insert user: {s}\n", .{user.name});
            return error.InsertError;
        }
        
        // Reset for next iteration
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
    }
    
    // Commit transaction
    rc = c.sqlite3_exec(db, "COMMIT", null, null, null);
    if (rc != c.SQLITE_OK) return error.CommitError;
    
    std.debug.print("Successfully inserted {} users\n", .{users.len});
}
```

## Template 4: Configuration & Optimization

```zig
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); });

pub fn optimizeDatabase(db: ?*c.sqlite3) !void {
    // Enable WAL mode for better concurrency
    var rc = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Warning: Could not enable WAL mode\n", .{});
    }
    
    // Increase cache size (10MB)
    rc = c.sqlite3_exec(db, "PRAGMA cache_size=10000", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Warning: Could not set cache size\n", .{});
    }
    
    // Set synchronous mode to NORMAL for better performance
    rc = c.sqlite3_exec(db, "PRAGMA synchronous=NORMAL", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Warning: Could not set synchronous mode\n", .{});
    }
    
    // Enable foreign keys
    rc = c.sqlite3_exec(db, "PRAGMA foreign_keys=ON", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Warning: Could not enable foreign keys\n", .{});
    }
    
    // Set busy timeout to 5 seconds
    rc = c.sqlite3_busy_timeout(db, 5000);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Warning: Could not set busy timeout\n", .{});
    }
    
    std.debug.print("Database optimization completed\n", .{});
}
```

## Template 5: Database Introspection

```zig
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); });

pub fn analyzeDatabase(db: ?*c.sqlite3) !void {
    try listTables(db);
    try showDatabaseInfo(db);
}

fn listTables(db: ?*c.sqlite3) !void {
    const sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name";
    var stmt: ?*c.sqlite3_stmt = null;
    
    var rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    std.debug.print("Database Objects:\n");
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name = c.sqlite3_column_text(stmt, 0);
        const obj_type = c.sqlite3_column_text(stmt, 1);
        
        const name_len = c.sqlite3_column_bytes(stmt, 0);
        const type_len = c.sqlite3_column_bytes(stmt, 1);
        
        std.debug.print("  {s}: {s}\n", .{
            obj_type[0..@intCast(type_len)],
            name[0..@intCast(name_len)]
        });
        
        // Show table structure if it's a table
        if (std.mem.eql(u8, obj_type[0..@intCast(type_len)], "table")) {
            try showTableStructure(db, name[0..@intCast(name_len)]);
        }
    }
}

fn showTableStructure(db: ?*c.sqlite3, table_name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = std.fmt.bufPrint(&buf, "PRAGMA table_info({s})", .{table_name}) catch return;
    
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    std.debug.print("    Columns:\n");
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const col_name = c.sqlite3_column_text(stmt, 1);
        const col_type = c.sqlite3_column_text(stmt, 2);
        const not_null = c.sqlite3_column_int(stmt, 3);
        const pk = c.sqlite3_column_int(stmt, 5);
        
        const name_len = c.sqlite3_column_bytes(stmt, 1);
        const type_len = c.sqlite3_column_bytes(stmt, 2);
        
        std.debug.print("      {s} {s}", .{
            col_name[0..@intCast(name_len)],
            col_type[0..@intCast(type_len)]
        });
        
        if (pk != 0) std.debug.print(" PRIMARY KEY", .{});
        if (not_null != 0) std.debug.print(" NOT NULL", .{});
        
        std.debug.print("\n", .{});
    }
}

fn showDatabaseInfo(db: ?*c.sqlite3) !void {
    // Get database schema version
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, "PRAGMA schema_version", -1, &stmt, null);
    if (rc == c.SQLITE_OK) {
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const version = c.sqlite3_column_int(stmt, 0);
            std.debug.print("Schema version: {}\n", .{version});
        }
    }
}
```

## Template 6: Error Handling Wrapper

```zig
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); });

const SQLiteDB = struct {
    db: ?*c.sqlite3,
    
    const Self = @This();
    
    pub fn init(filename: []const u8) !Self {
        var buf: [512]u8 = undefined;
        std.mem.copyForwards(u8, buf[0..filename.len], filename);
        buf[filename.len] = 0;
        
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(&buf, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| {
                std.debug.print("Open error: {s}\n", .{c.sqlite3_errmsg(d)});
                _ = c.sqlite3_close(d);
            }
            return error.OpenError;
        }
        
        return Self{ .db = db };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
    }
    
    pub fn exec(self: *Self, sql: []const u8) !void {
        var buf: [1024]u8 = undefined;
        std.mem.copyForwards(u8, buf[0..sql.len], sql);
        buf[sql.len] = 0;
        
        const rc = c.sqlite3_exec(self.db, &buf, null, null, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("Exec error: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.ExecError;
        }
    }
    
    pub fn prepare(self: *Self, sql: []const u8) !SQLiteStmt {
        return SQLiteStmt.init(self.db, sql);
    }
};

const SQLiteStmt = struct {
    stmt: ?*c.sqlite3_stmt,
    
    const Self = @This();
    
    pub fn init(db: ?*c.sqlite3, sql: []const u8) !Self {
        var buf: [1024]u8 = undefined;
        std.mem.copyForwards(u8, buf[0..sql.len], sql);
        buf[sql.len] = 0;
        
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, &buf, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.debug.print("Prepare error: {s}\n", .{c.sqlite3_errmsg(db)});
            return error.PrepareError;
        }
        
        return Self{ .stmt = stmt };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.stmt) |stmt| {
            _ = c.sqlite3_finalize(stmt);
        }
    }
    
    pub fn bindText(self: *Self, index: i32, text: []const u8) !void {
        const rc = c.sqlite3_bind_text(self.stmt, index, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
        if (rc != c.SQLITE_OK) return error.BindError;
    }
    
    pub fn bindInt(self: *Self, index: i32, value: i32) !void {
        const rc = c.sqlite3_bind_int(self.stmt, index, value);
        if (rc != c.SQLITE_OK) return error.BindError;
    }
    
    pub fn step(self: *Self) !bool {
        const rc = c.sqlite3_step(self.stmt);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.StepError,
        };
    }
    
    pub fn columnText(self: *Self, index: i32) []const u8 {
        const text = c.sqlite3_column_text(self.stmt, index);
        const len = c.sqlite3_column_bytes(self.stmt, index);
        return text[0..@intCast(len)];
    }
    
    pub fn columnInt(self: *Self, index: i32) i32 {
        return c.sqlite3_column_int(self.stmt, index);
    }
    
    pub fn reset(self: *Self) !void {
        const rc = c.sqlite3_reset(self.stmt);
        if (rc != c.SQLITE_OK) return error.ResetError;
    }
};

// Usage example:
pub fn exampleUsage() !void {
    var db = try SQLiteDB.init("example.db");
    defer db.deinit();
    
    try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT)");
    
    var stmt = try db.prepare("INSERT INTO users (name) VALUES (?)");
    defer stmt.deinit();
    
    try stmt.bindText(1, "Alice");
    _ = try stmt.step();
    
    try stmt.reset();
    try stmt.bindText(1, "Bob");
    _ = try stmt.step();
}
```

These templates provide production-ready patterns for common ZSQLite use cases. Copy and modify them for your specific needs!
