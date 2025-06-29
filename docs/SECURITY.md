# ZSQLite Security Best Practices

## Overview

This guide covers security considerations when using ZSQLite, including SQL injection prevention, access control, data protection, and secure deployment practices.

## SQL Injection Prevention

### 1. Always Use Prepared Statements

#### Vulnerable Code (DON'T DO THIS)
```zig
// DANGEROUS: Direct string interpolation
const user_input = "'; DROP TABLE users; --";
const sql = try std.fmt.allocPrint(allocator, 
    "SELECT * FROM users WHERE name = '{s}'", .{user_input});
// This creates: SELECT * FROM users WHERE name = ''; DROP TABLE users; --'
```

#### Secure Code (CORRECT APPROACH)
```zig
// SAFE: Use prepared statements with parameter binding
const sql = "SELECT * FROM users WHERE name = ?";
var stmt: ?*c.sqlite3_stmt = null;

var buf: [256]u8 = undefined;
const sql_cstr = createCString(&buf, sql);
var rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

if (rc == c.SQLITE_OK) {
    // Safely bind user input
    var input_buf: [128]u8 = undefined;
    const input_cstr = createCString(&input_buf, user_input);
    _ = c.sqlite3_bind_text(stmt, 1, input_cstr, -1, null);
    
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // Process results safely
    }
}
_ = c.sqlite3_finalize(stmt);
```

### 2. Input Validation and Sanitization

```zig
// Validate input before using in queries
fn validateInput(input: []const u8) bool {
    // Check length
    if (input.len == 0 or input.len > 255) return false;
    
    // Check for null bytes
    for (input) |byte| {
        if (byte == 0) return false;
    }
    
    // Check for suspicious patterns
    const dangerous_patterns = [_][]const u8{
        "--", "/*", "*/", "xp_", "sp_", "exec", "union", "drop", "delete"
    };
    
    const lower_input = std.ascii.lowerString(allocator.alloc(u8, input.len) catch return false, input);
    defer allocator.free(lower_input);
    
    for (dangerous_patterns) |pattern| {
        if (std.mem.indexOf(u8, lower_input, pattern) != null) {
            return false;
        }
    }
    
    return true;
}

// Secure wrapper for user queries
fn executeUserQuery(db: *c.sqlite3, user_sql: []const u8) !void {
    if (!validateInput(user_sql)) {
        return error.InvalidInput;
    }
    
    // Additional checks for read-only operations
    if (!isReadOnlyQuery(user_sql)) {
        return error.WriteOperationNotAllowed;
    }
    
    // Execute with prepared statement
    var stmt: ?*c.sqlite3_stmt = null;
    var buf: [1024]u8 = undefined;
    const sql_cstr = createCString(&buf, user_sql);
    
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // Process results
    }
}
```

### 3. Query Whitelisting

```zig
// Predefined safe queries
const SafeQueries = struct {
    const GET_USER_BY_ID = "SELECT id, name, email FROM users WHERE id = ?";
    const GET_USER_BY_EMAIL = "SELECT id, name FROM users WHERE email = ? AND active = 1";
    const UPDATE_USER_NAME = "UPDATE users SET name = ? WHERE id = ? AND owner_id = ?";
    const LIST_USER_ORDERS = "SELECT id, amount, date FROM orders WHERE user_id = ? ORDER BY date DESC";
};

// Execute only whitelisted queries
fn executeWhitelistedQuery(db: *c.sqlite3, query_type: QueryType, params: []const []const u8) !void {
    const sql = switch (query_type) {
        .get_user_by_id => SafeQueries.GET_USER_BY_ID,
        .get_user_by_email => SafeQueries.GET_USER_BY_EMAIL,
        .update_user_name => SafeQueries.UPDATE_USER_NAME,
        .list_user_orders => SafeQueries.LIST_USER_ORDERS,
    };
    
    var stmt: ?*c.sqlite3_stmt = null;
    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);
    
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    
    // Bind parameters safely
    for (params, 1..) |param, i| {
        var param_buf: [256]u8 = undefined;
        const param_cstr = createCString(&param_buf, param);
        _ = c.sqlite3_bind_text(stmt, @intCast(i), param_cstr, -1, null);
    }
    
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // Process results
    }
}
```

## Access Control and Authorization

### 1. Connection-Level Security

```zig
// Secure database opening with minimal permissions
fn openDatabaseSecurely(filename: []const u8, read_only: bool) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    var buf: [512]u8 = undefined;
    const filename_cstr = createCString(&buf, filename);
    
    const flags = if (read_only) 
        c.SQLITE_OPEN_READONLY 
    else 
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    
    const rc = c.sqlite3_open_v2(filename_cstr, &db, flags, null);
    if (rc != c.SQLITE_OK) {
        if (db != null) _ = c.sqlite3_close(db);
        return error.OpenFailed;
    }
    
    // Set security pragmas
    try setSecurityPragmas(db.?);
    
    return db.?;
}

fn setSecurityPragmas(db: *c.sqlite3) !void {
    var buf: [256]u8 = undefined;
    
    // Disable dangerous functions
    const disable_extensions = "PRAGMA trusted_schema = OFF";
    const ext_cstr = createCString(&buf, disable_extensions);
    var rc = c.sqlite3_exec(db, ext_cstr, null, null, null);
    if (rc != c.SQLITE_OK) return error.PragmaFailed;
    
    // Set maximum query execution time
    rc = c.sqlite3_busy_timeout(db, 10000); // 10 seconds max
    if (rc != c.SQLITE_OK) return error.TimeoutFailed;
    
    // Limit memory usage
    const memory_limit = "PRAGMA max_page_count = 1048576"; // ~4GB limit
    const mem_cstr = createCString(&buf, memory_limit);
    rc = c.sqlite3_exec(db, mem_cstr, null, null, null);
    if (rc != c.SQLITE_OK) return error.PragmaFailed;
}
```

### 2. Role-Based Access Control

```zig
const UserRole = enum {
    admin,
    read_write,
    read_only,
    guest,
};

const Permission = struct {
    can_read: bool = false,
    can_write: bool = false,
    can_create: bool = false,
    can_drop: bool = false,
    can_alter: bool = false,
};

fn getPermissions(role: UserRole) Permission {
    return switch (role) {
        .admin => Permission{
            .can_read = true,
            .can_write = true,
            .can_create = true,
            .can_drop = true,
            .can_alter = true,
        },
        .read_write => Permission{
            .can_read = true,
            .can_write = true,
            .can_create = false,
            .can_drop = false,
            .can_alter = false,
        },
        .read_only => Permission{
            .can_read = true,
            .can_write = false,
            .can_create = false,
            .can_drop = false,
            .can_alter = false,
        },
        .guest => Permission{
            .can_read = true,
            .can_write = false,
            .can_create = false,
            .can_drop = false,
            .can_alter = false,
        },
    };
}

fn checkPermission(sql: []const u8, role: UserRole) bool {
    const perms = getPermissions(role);
    const upper_sql = std.ascii.lowerString(allocator.alloc(u8, sql.len) catch return false, sql);
    defer allocator.free(upper_sql);
    
    if (std.mem.startsWith(u8, upper_sql, "select") or 
        std.mem.startsWith(u8, upper_sql, "explain")) {
        return perms.can_read;
    }
    
    if (std.mem.startsWith(u8, upper_sql, "insert") or 
        std.mem.startsWith(u8, upper_sql, "update") or 
        std.mem.startsWith(u8, upper_sql, "delete")) {
        return perms.can_write;
    }
    
    if (std.mem.startsWith(u8, upper_sql, "create")) {
        return perms.can_create;
    }
    
    if (std.mem.startsWith(u8, upper_sql, "drop")) {
        return perms.can_drop;
    }
    
    if (std.mem.startsWith(u8, upper_sql, "alter")) {
        return perms.can_alter;
    }
    
    return false; // Deny by default
}
```

## Data Protection

### 1. Encryption at Rest

```zig
// Note: SQLite encryption requires SQLite Encryption Extension (SEE) or SQLCipher
// This is an example of how to handle encrypted databases

fn openEncryptedDatabase(filename: []const u8, password: []const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    var buf: [512]u8 = undefined;
    const filename_cstr = createCString(&buf, filename);
    
    const rc = c.sqlite3_open(filename_cstr, &db);
    if (rc != c.SQLITE_OK) return error.OpenFailed;
    
    // Set encryption key (requires SQLCipher or SEE)
    var key_buf: [256]u8 = undefined;
    const key_cstr = createCString(&key_buf, password);
    
    // This would work with SQLCipher:
    // const key_rc = c.sqlite3_key(db, key_cstr, @intCast(password.len));
    // if (key_rc != c.SQLITE_OK) return error.EncryptionFailed;
    
    return db.?;
}

// Secure password handling
fn hashPassword(password: []const u8, salt: []const u8) ![32]u8 {
    // Use a proper password hashing library like Argon2 or bcrypt
    // This is a simplified example
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(password);
    hasher.update(salt);
    return hasher.finalResult();
}
```

### 2. Sensitive Data Handling

```zig
// Secure memory for sensitive data
const SecureString = struct {
    data: []u8,
    allocator: std.mem.Allocator,
    
    fn init(allocator: std.mem.Allocator, size: usize) !SecureString {
        const data = try allocator.alloc(u8, size);
        // Zero memory
        std.mem.set(u8, data, 0);
        return SecureString{
            .data = data,
            .allocator = allocator,
        };
    }
    
    fn deinit(self: *SecureString) void {
        // Zero memory before freeing
        std.mem.set(u8, self.data, 0);
        self.allocator.free(self.data);
    }
    
    fn setData(self: *SecureString, value: []const u8) void {
        const copy_len = @min(value.len, self.data.len);
        std.mem.copy(u8, self.data[0..copy_len], value[0..copy_len]);
    }
};

// Secure credential storage
fn storeCredentials(db: *c.sqlite3, username: []const u8, password: []const u8) !void {
    // Generate random salt
    var salt: [16]u8 = undefined;
    std.crypto.random.bytes(&salt);
    
    // Hash password
    const hashed = try hashPassword(password, &salt);
    
    // Store in database
    const sql = "INSERT INTO users (username, password_hash, salt) VALUES (?, ?, ?)";
    var stmt: ?*c.sqlite3_stmt = null;
    var buf: [256]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);
    
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    
    // Bind parameters
    var user_buf: [128]u8 = undefined;
    const user_cstr = createCString(&user_buf, username);
    _ = c.sqlite3_bind_text(stmt, 1, user_cstr, -1, null);
    _ = c.sqlite3_bind_blob(stmt, 2, &hashed, hashed.len, null);
    _ = c.sqlite3_bind_blob(stmt, 3, &salt, salt.len, null);
    
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.InsertFailed;
    }
}
```

## File System Security

### 1. Secure File Permissions

```zig
// Set restrictive file permissions (Unix-like systems)
fn setSecurePermissions(filename: []const u8) !void {
    const file = std.fs.cwd().openFile(filename, .{}) catch return error.FileNotFound;
    defer file.close();
    
    // Set permissions to read/write for owner only (600)
    try file.chmod(0o600);
}

// Validate file paths to prevent directory traversal
fn validatePath(path: []const u8) bool {
    // Check for directory traversal attempts
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    if (std.mem.indexOf(u8, path, "~") != null) return false;
    
    // Check for absolute paths (may be restricted)
    if (path.len > 0 and path[0] == '/') return false;
    
    // Check for null bytes
    for (path) |byte| {
        if (byte == 0) return false;
    }
    
    return true;
}

// Secure database file creation
fn createSecureDatabase(filename: []const u8) !*c.sqlite3 {
    if (!validatePath(filename)) return error.InvalidPath;
    
    // Create with restrictive permissions
    const file = try std.fs.cwd().createFile(filename, .{ .mode = 0o600 });
    file.close();
    
    // Open database
    var db: ?*c.sqlite3 = null;
    var buf: [512]u8 = undefined;
    const filename_cstr = createCString(&buf, filename);
    
    const rc = c.sqlite3_open(filename_cstr, &db);
    if (rc != c.SQLITE_OK) return error.OpenFailed;
    
    return db.?;
}
```

### 2. Temporary File Security

```zig
// Secure temporary database creation
fn createSecureTempDatabase() !*c.sqlite3 {
    // Use in-memory database for sensitive temporary data
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(":memory:", &db);
    if (rc != c.SQLITE_OK) return error.OpenFailed;
    
    // Set security pragmas
    try setSecurityPragmas(db.?);
    
    return db.?;
}

// Secure cleanup of temporary files
fn secureCleanup(filename: []const u8) void {
    // Overwrite file with random data before deletion
    const file = std.fs.cwd().openFile(filename, .{ .mode = .write_only }) catch return;
    defer file.close();
    
    const file_size = file.getEndPos() catch return;
    const writer = file.writer();
    
    var random_data: [4096]u8 = undefined;
    var remaining = file_size;
    
    while (remaining > 0) {
        std.crypto.random.bytes(&random_data);
        const write_size = @min(remaining, random_data.len);
        writer.writeAll(random_data[0..write_size]) catch break;
        remaining -= write_size;
    }
    
    // Delete file
    std.fs.cwd().deleteFile(filename) catch {};
}
```

## Logging and Monitoring

### 1. Security Event Logging

```zig
const SecurityEvent = enum {
    failed_login,
    sql_injection_attempt,
    unauthorized_access,
    privilege_escalation,
    suspicious_query,
};

fn logSecurityEvent(event: SecurityEvent, details: []const u8, user: ?[]const u8) void {
    const timestamp = std.time.timestamp();
    const user_str = user orelse "unknown";
    
    // Log to secure log file or system log
    const log_msg = std.fmt.allocPrint(allocator,
        "[SECURITY] {d}: {s} - User: {s} - Details: {s}\n",
        .{ timestamp, @tagName(event), user_str, details }
    ) catch return;
    defer allocator.free(log_msg);
    
    // Write to secure log file
    const log_file = std.fs.cwd().openFile("security.log", .{ 
        .mode = .write_only 
    }) catch return;
    defer log_file.close();
    
    log_file.seekFromEnd(0) catch return;
    log_file.writeAll(log_msg) catch return;
}

// Monitor for suspicious activity
fn detectSuspiciousQuery(sql: []const u8) bool {
    const suspicious_patterns = [_][]const u8{
        "union select", "information_schema", "sys.tables",
        "load_extension", "attach database", "pragma",  
        "'; drop", "'; delete", "'; update",
    };
    
    const lower_sql = std.ascii.lowerString(allocator.alloc(u8, sql.len) catch return false, sql);
    defer allocator.free(lower_sql);
    
    for (suspicious_patterns) |pattern| {
        if (std.mem.indexOf(u8, lower_sql, pattern) != null) {
            return true;
        }
    }
    
    return false;
}
```

### 2. Performance Monitoring for Security

```zig
// Rate limiting to prevent abuse
const RateLimiter = struct {
    requests: std.HashMap([]const u8, RequestInfo, std.hash_map.StringContext, 80),
    
    const RequestInfo = struct {
        count: u32,
        first_request: i64,
    };
    
    fn checkRateLimit(self: *RateLimiter, user: []const u8, max_requests: u32, window_seconds: i64) bool {
        const now = std.time.timestamp();
        
        if (self.requests.getPtr(user)) |info| {
            // Reset counter if window expired
            if (now - info.first_request > window_seconds) {
                info.count = 1;
                info.first_request = now;
                return true;
            }
            
            // Check if limit exceeded
            if (info.count >= max_requests) {
                logSecurityEvent(.unauthorized_access, "Rate limit exceeded", user);
                return false;
            }
            
            info.count += 1;
            return true;
        } else {
            // First request from this user
            self.requests.put(try allocator.dupe(u8, user), RequestInfo{
                .count = 1,
                .first_request = now,
            }) catch return false;
            return true;
        }
    }
};
```

## Security Best Practices Summary

### 1. Input Validation
- Always use prepared statements with parameter binding
- Validate and sanitize all user inputs
- Use query whitelisting for user-facing applications
- Implement proper error handling without information disclosure

### 2. Access Control
- Open databases with minimal required permissions
- Implement role-based access control
- Use connection-level security settings
- Validate file paths to prevent directory traversal

### 3. Data Protection
- Consider encryption for sensitive data
- Use secure memory handling for credentials
- Implement proper password hashing
- Secure temporary file handling

### 4. Monitoring and Logging
- Log all security-relevant events
- Monitor for suspicious query patterns
- Implement rate limiting
- Regular security audits

### 5. Deployment Security
- Set restrictive file permissions
- Use secure database file locations
- Regular security updates
- Secure backup and recovery procedures

### 6. Development Practices
- Security code reviews
- Static analysis tools
- Regular dependency updates
- Security testing in CI/CD pipelines

By following these security best practices, ZSQLite applications can maintain strong security posture while providing necessary functionality.
