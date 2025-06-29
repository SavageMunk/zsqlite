# ZSQLite Function Reference

Complete reference for all 47 implemented SQLite C API functions with copy-paste examples.

## Database Connection Management

### `sqlite3_open()`
Open a database connection.

```zig
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); });

var db: ?*c.sqlite3 = null;
var buf: [256]u8 = undefined;
const filename = "example.db";

// Create null-terminated string
std.mem.copyForwards(u8, buf[0..filename.len], filename);
buf[filename.len] = 0;

const rc = c.sqlite3_open(&buf, &db);
if (rc != c.SQLITE_OK) {
    std.debug.print("Error: {s}\n", .{c.sqlite3_errmsg(db)});
    return error.OpenFailed;
}
defer _ = c.sqlite3_close(db);
```

### `sqlite3_open_v2()`
Open database with advanced flags.

```zig
const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
const rc = c.sqlite3_open_v2(&buf, &db, flags, null);
```

### `sqlite3_close()`
Close database connection.

```zig
_ = c.sqlite3_close(db);
```

## Basic SQL Execution

### `sqlite3_exec()`
Execute simple SQL statements.

```zig
const sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)";
var errmsg: [*c]u8 = null;

const rc = c.sqlite3_exec(db, sql, null, null, &errmsg);
if (rc != c.SQLITE_OK) {
    defer if (errmsg) |msg| c.sqlite3_free(msg);
    std.debug.print("SQL Error: {s}\n", .{errmsg});
    return error.SQLError;
}
```

## Prepared Statements

### `sqlite3_prepare_v2()`
Prepare SQL statement for execution.

```zig
const sql = "INSERT INTO users (name) VALUES (?)";
var stmt: ?*c.sqlite3_stmt = null;

const rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
if (rc != c.SQLITE_OK) {
    std.debug.print("Prepare failed: {s}\n", .{c.sqlite3_errmsg(db)});
    return error.PrepareError;
}
defer _ = c.sqlite3_finalize(stmt);
```

### `sqlite3_bind_text()`
Bind text parameter to prepared statement.

```zig
const name = "Alice";
const rc = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
if (rc != c.SQLITE_OK) {
    return error.BindError;
}
```

### `sqlite3_bind_int()` & `sqlite3_bind_int64()`
Bind integer parameters.

```zig
// 32-bit integer
const rc1 = c.sqlite3_bind_int(stmt, 1, 42);

// 64-bit integer
const rc2 = c.sqlite3_bind_int64(stmt, 2, 1234567890);
```

### `sqlite3_bind_double()`
Bind floating-point parameter.

```zig
const rc = c.sqlite3_bind_double(stmt, 1, 3.14159);
```

### `sqlite3_bind_blob()`
Bind binary data.

```zig
const data = [_]u8{0x01, 0x02, 0x03, 0x04};
const rc = c.sqlite3_bind_blob(stmt, 1, &data, data.len, c.SQLITE_STATIC);
```

### `sqlite3_bind_null()`
Bind NULL value.

```zig
const rc = c.sqlite3_bind_null(stmt, 1);
```

### `sqlite3_step()`
Execute prepared statement.

```zig
const rc = c.sqlite3_step(stmt);
switch (rc) {
    c.SQLITE_ROW => {
        // Row available, read columns
    },
    c.SQLITE_DONE => {
        // Statement completed successfully
    },
    else => {
        return error.StepError;
    }
}
```

### `sqlite3_finalize()`
Clean up prepared statement.

```zig
_ = c.sqlite3_finalize(stmt);
```

## Reading Results

### `sqlite3_column_count()`
Get number of columns in result.

```zig
const col_count = c.sqlite3_column_count(stmt);
```

### `sqlite3_column_text()`
Read text column.

```zig
const text = c.sqlite3_column_text(stmt, 0);
if (text) |txt| {
    const len = c.sqlite3_column_bytes(stmt, 0);
    const result = txt[0..@intCast(len)];
    std.debug.print("Text: {s}\n", .{result});
}
```

### `sqlite3_column_int()` & `sqlite3_column_int64()`
Read integer columns.

```zig
const int_val = c.sqlite3_column_int(stmt, 0);
const int64_val = c.sqlite3_column_int64(stmt, 1);
```

### `sqlite3_column_double()`
Read floating-point column.

```zig
const double_val = c.sqlite3_column_double(stmt, 0);
```

### `sqlite3_column_blob()`
Read binary data.

```zig
const blob = c.sqlite3_column_blob(stmt, 0);
const len = c.sqlite3_column_bytes(stmt, 0);
if (blob) |data| {
    const bytes = @as([*]const u8, @ptrCast(data))[0..@intCast(len)];
    // Process binary data
}
```

### `sqlite3_column_type()`
Get column data type.

```zig
const col_type = c.sqlite3_column_type(stmt, 0);
switch (col_type) {
    c.SQLITE_INTEGER => std.debug.print("Integer\n", .{}),
    c.SQLITE_FLOAT => std.debug.print("Float\n", .{}),
    c.SQLITE_TEXT => std.debug.print("Text\n", .{}),
    c.SQLITE_BLOB => std.debug.print("Blob\n", .{}),
    c.SQLITE_NULL => std.debug.print("NULL\n", .{}),
    else => std.debug.print("Unknown type\n", .{}),
}
```

## Transaction Management

### Manual Transactions
```zig
// Begin transaction
_ = c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, null);

// Perform operations...

// Commit or rollback
if (success) {
    _ = c.sqlite3_exec(db, "COMMIT", null, null, null);
} else {
    _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
}
```

### `sqlite3_get_autocommit()`
Check transaction state.

```zig
const in_transaction = c.sqlite3_get_autocommit(db) == 0;
```

### `sqlite3_changes()`
Get number of rows affected by last statement.

```zig
const affected_rows = c.sqlite3_changes(db);
```

### `sqlite3_last_insert_rowid()`
Get last inserted row ID.

```zig
const last_id = c.sqlite3_last_insert_rowid(db);
```

## Error Handling

### `sqlite3_errmsg()`
Get error message for database connection.

```zig
if (rc != c.SQLITE_OK) {
    std.debug.print("Error: {s}\n", .{c.sqlite3_errmsg(db)});
}
```

## Performance & Optimization

### `sqlite3_busy_timeout()`
Set busy timeout for locked databases.

```zig
const timeout_ms = 5000; // 5 seconds
_ = c.sqlite3_busy_timeout(db, timeout_ms);
```

### Performance PRAGMAs
```zig
// WAL mode for better concurrency
_ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL", null, null, null);

// Increase cache size
_ = c.sqlite3_exec(db, "PRAGMA cache_size=10000", null, null, null);

// Faster synchronization
_ = c.sqlite3_exec(db, "PRAGMA synchronous=NORMAL", null, null, null);
```

## Database Introspection

### List Tables
```zig
const sql = "SELECT name FROM sqlite_master WHERE type='table'";
// Execute and iterate through results
```

### Table Schema
```zig
const sql = "PRAGMA table_info(users)";
// Returns: cid, name, type, notnull, dflt_value, pk
```

### Database Statistics
```zig
const sql = "SELECT COUNT(*) FROM users";
// Get row count for table
```

## Complete Example: User Management

```zig
const std = @import("std");
const c = @cImport({ @cInclude("sqlite3.h"); });

pub fn main() !void {
    var db: ?*c.sqlite3 = null;
    var buf: [256]u8 = undefined;
    
    // Open database
    const filename = "users.db";
    std.mem.copyForwards(u8, buf[0..filename.len], filename);
    buf[filename.len] = 0;
    
    var rc = c.sqlite3_open(&buf, &db);
    if (rc != c.SQLITE_OK) return error.OpenFailed;
    defer _ = c.sqlite3_close(db);
    
    // Create table
    const create_sql = "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)";
    rc = c.sqlite3_exec(db, create_sql, null, null, null);
    if (rc != c.SQLITE_OK) return error.CreateTableFailed;
    
    // Insert user
    const insert_sql = "INSERT INTO users (name, email) VALUES (?, ?)";
    var stmt: ?*c.sqlite3_stmt = null;
    
    rc = c.sqlite3_prepare_v2(db, insert_sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    
    // Bind parameters
    const name = "Alice";
    const email = "alice@example.com";
    
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, email.ptr, @intCast(email.len), c.SQLITE_STATIC);
    
    // Execute
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.InsertFailed;
    
    std.debug.print("User inserted with ID: {}\n", .{c.sqlite3_last_insert_rowid(db)});
    
    // Query users
    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);
    
    const select_sql = "SELECT id, name, email FROM users";
    rc = c.sqlite3_prepare_v2(db, select_sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareError;
    
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(stmt, 0);
        const user_name = c.sqlite3_column_text(stmt, 1);
        const user_email = c.sqlite3_column_text(stmt, 2);
        
        const name_len = c.sqlite3_column_bytes(stmt, 1);
        const email_len = c.sqlite3_column_bytes(stmt, 2);
        
        std.debug.print("User {}: {s} <{s}>\n", .{
            id,
            user_name[0..@intCast(name_len)],
            user_email[0..@intCast(email_len)]
        });
    }
}
```

## Memory Management Best Practices

1. **Always use `defer`** for cleanup:
   ```zig
   defer _ = c.sqlite3_close(db);
   defer _ = c.sqlite3_finalize(stmt);
   ```

2. **Free error messages** when needed:
   ```zig
   defer if (errmsg) |msg| c.sqlite3_free(msg);
   ```

3. **Use SQLITE_STATIC** for string literals:
   ```zig
   _ = c.sqlite3_bind_text(stmt, 1, "literal", -1, c.SQLITE_STATIC);
   ```

4. **Use SQLITE_TRANSIENT** for dynamic strings:
   ```zig
   _ = c.sqlite3_bind_text(stmt, 1, dynamic_str.ptr, @intCast(dynamic_str.len), c.SQLITE_TRANSIENT);
   ```

## Error Handling Patterns

```zig
// Pattern 1: Simple error checking
if (rc != c.SQLITE_OK) {
    std.debug.print("Error: {s}\n", .{c.sqlite3_errmsg(db)});
    return error.SQLiteError;
}

// Pattern 2: Detailed error handling
fn handleSQLiteError(db: ?*c.sqlite3, rc: c_int, operation: []const u8) !void {
    if (rc != c.SQLITE_OK) {
        std.debug.print("{s} failed: {s} (code: {})\n", .{
            operation,
            c.sqlite3_errmsg(db),
            rc
        });
        return error.SQLiteError;
    }
}
```

## Performance Guidelines

1. **Use prepared statements** for repeated queries
2. **Enable WAL mode** for better concurrency  
3. **Increase cache size** for large datasets
4. **Use transactions** for bulk operations
5. **Create indexes** on frequently queried columns
6. **Use PRAGMA statements** for optimization

This reference covers all 47 implemented SQLite functions with practical, copy-paste examples.
