# ZSQLite Troubleshooting Guide

## Overview

This guide covers common issues, their solutions, and debugging techniques for ZSQLite applications.

## Build and Compilation Issues

### 1. SQLite Library Not Found

#### Problem
```
error: library not found for -lsqlite3
```

#### Solution
Install SQLite development libraries:

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install sqlite3 libsqlite3-dev
```

**macOS:**
```bash
# Using Homebrew
brew install sqlite

# Using MacPorts
sudo port install sqlite3
```

**Windows:**
```bash
# Using vcpkg
vcpkg install sqlite3

# Or download SQLite from https://sqlite.org/download.html
```

#### Verification
```bash
# Check SQLite installation
sqlite3 --version

# Check development headers
ls /usr/include/sqlite3.h      # Linux
ls /usr/local/include/sqlite3.h # macOS
```

### 2. Zig Compiler Issues

#### Problem: Zig Version Compatibility
```
error: unrecognized command line option '--build-system'
```

#### Solution
ZSQLite requires Zig 0.11.0 or later:

```bash
# Check Zig version
zig version

# Update Zig if needed
# Download from https://ziglang.org/download/
```

#### Problem: linkLibC() Missing
```
Segmentation fault (core dumped)
```

#### Solution
Ensure `exe.linkLibC()` is included in `build.zig`:

```zig
pub fn build(b: *std.Build) void {
    // ... other code ...
    
    exe.linkSystemLibrary("sqlite3");
    exe.linkLibC();  // ← This is critical!
    
    // ... rest of build ...
}
```

### 3. C Header Issues

#### Problem
```
error: 'sqlite3.h' file not found
```

#### Solution
Verify header location and add include path if needed:

```zig
// In your Zig source file
const c = @cImport({
    @cInclude("sqlite3.h");
});

// If headers are in non-standard location, add to build.zig:
exe.addIncludePath("/usr/local/include");  // Adjust path as needed
```

## Runtime Errors

### 1. Database Connection Issues

#### Problem: Database Locked
```
SQL Error: database is locked
```

#### Solutions

**Check for unclosed connections:**
```zig
// Always close database connections
defer if (db != null) _ = c.sqlite3_close(db);

// Or use RAII pattern
const DatabaseConnection = struct {
    db: ?*c.sqlite3,
    
    fn init(filename: []const u8) !DatabaseConnection {
        var db: ?*c.sqlite3 = null;
        // ... open database ...
        return DatabaseConnection{ .db = db };
    }
    
    fn deinit(self: *DatabaseConnection) void {
        if (self.db != null) {
            _ = c.sqlite3_close(self.db);
        }
    }
};
```

**Set busy timeout:**
```zig
// Set 30-second timeout for locked databases
const rc = c.sqlite3_busy_timeout(db, 30000);
if (rc != c.SQLITE_OK) {
    print("Warning: Could not set busy timeout\n", .{});
}
```

**Use WAL mode for better concurrency:**
```zig
const wal_sql = "PRAGMA journal_mode=WAL";
var buf: [64]u8 = undefined;
const wal_cstr = createCString(&buf, wal_sql);
const rc = c.sqlite3_exec(db, wal_cstr, null, null, null);
```

#### Problem: Disk I/O Error
```
SQL Error: disk I/O error
```

#### Solutions

**Check file permissions:**
```bash
# Ensure proper permissions
ls -la database.db
chmod 644 database.db  # Read/write for owner

# Check directory permissions
ls -la .
chmod 755 .  # Directory must be executable
```

**Check disk space:**
```bash
df -h .  # Check available disk space
```

**Verify file system:**
```bash
fsck /dev/your-device  # Check file system integrity
```

### 2. Memory and Performance Issues

#### Problem: Memory Leaks
```
Memory usage continuously increases
```

#### Solutions

**Proper statement cleanup:**
```zig
// Always finalize prepared statements
var stmt: ?*c.sqlite3_stmt = null;
defer if (stmt != null) _ = c.sqlite3_finalize(stmt);

// Or use RAII
const PreparedStatement = struct {
    stmt: ?*c.sqlite3_stmt,
    
    fn init(db: *c.sqlite3, sql: []const u8) !PreparedStatement {
        var stmt: ?*c.sqlite3_stmt = null;
        var buf: [1024]u8 = undefined;
        const sql_cstr = createCString(&buf, sql);
        const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        return PreparedStatement{ .stmt = stmt };
    }
    
    fn deinit(self: *PreparedStatement) void {
        if (self.stmt != null) {
            _ = c.sqlite3_finalize(self.stmt);
        }
    }
};
```

**Monitor memory usage:**
```zig
// Check SQLite memory usage
const memory_used = c.sqlite3_memory_used();
const memory_high = c.sqlite3_memory_highwater(0);
print("Memory: {d} bytes used, {d} high water mark\n", .{ memory_used, memory_high });
```

#### Problem: Slow Query Performance
```
Queries taking too long to execute
```

#### Solutions

**Use EXPLAIN QUERY PLAN:**
```zig
fn analyzeQuery(db: *c.sqlite3, sql: []const u8) !void {
    var explain_buf: [2048]u8 = undefined;
    const explain_sql = try std.fmt.bufPrint(explain_buf[0..], "EXPLAIN QUERY PLAN {s}", .{sql});
    
    print("Query Plan:\n");
    try executeSQL(&(.{.db = db}), explain_sql);
}
```

**Add missing indexes:**
```sql
-- Find missing indexes
SELECT * FROM sqlite_master WHERE type = 'index';

-- Create indexes for frequently queried columns
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_orders_date ON orders(created_date);
```

**Optimize configuration:**
```zig
fn optimizeForPerformance(db: *c.sqlite3) !void {
    var buf: [256]u8 = undefined;
    
    // Increase cache size
    const cache_sql = "PRAGMA cache_size = -64000";  // 64MB
    const cache_cstr = createCString(&buf, cache_sql);
    _ = c.sqlite3_exec(db, cache_cstr, null, null, null);
    
    // Use WAL mode
    const wal_sql = "PRAGMA journal_mode = WAL";
    const wal_cstr = createCString(&buf, wal_sql);
    _ = c.sqlite3_exec(db, wal_cstr, null, null, null);
    
    // Enable memory-mapped I/O
    const mmap_sql = "PRAGMA mmap_size = 268435456";  // 256MB
    const mmap_cstr = createCString(&buf, mmap_sql);
    _ = c.sqlite3_exec(db, mmap_cstr, null, null, null);
}
```

### 3. CLI-Specific Issues

#### Problem: CLI Not Starting
```
./zig-out/bin/zsl
bash: ./zig-out/bin/zsl: No such file or directory
```

#### Solutions

**Build the CLI:**
```bash
zig build cli
# or
zig build && ./zig-out/bin/zsl
```

**Check build configuration:**
```zig
// In build.zig, ensure CLI target exists
const cli = b.addExecutable(.{
    .name = "zsl",
    .root_source_file = b.path("src/cli.zig"),
    .target = target,
    .optimize = optimize,
});

cli.linkSystemLibrary("sqlite3");
cli.linkLibC();
b.installArtifact(cli);
```

#### Problem: Configuration File Issues
```
Error loading configuration: FileNotFound
```

#### Solutions

**Create default configuration:**
```bash
# Create .zslrc file manually
cat > .zslrc << EOF
# ZSQLite CLI Configuration
syntax_highlighting=true
show_query_time=true
result_format=table
prompt=zsl> 
EOF
```

**Or let CLI create it:**
```bash
# Run CLI once to create default config
echo "\\q" | ./zig-out/bin/zsl
```

## Debugging Techniques

### 1. Enable Verbose Logging

```zig
// Add debug logging to your application
const DEBUG = @import("builtin").mode == .Debug;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG) {
        std.debug.print("[DEBUG] " ++ fmt ++ "\n", args);
    }
}

// Use in your code
debugLog("Opening database: {s}", .{filename});
debugLog("Executing SQL: {s}", .{sql});
```

### 2. SQLite Error Diagnosis

```zig
fn diagnoseError(db: *c.sqlite3, rc: c_int) void {
    print("SQLite Error Code: {d}\n", .{rc});
    print("Error Message: {s}\n", .{std.mem.span(c.sqlite3_errmsg(db))});
    print("Extended Error Code: {d}\n", .{c.sqlite3_extended_errcode(db)});
    
    // Get last insert rowid and changes
    print("Last Insert RowID: {d}\n", .{c.sqlite3_last_insert_rowid(db)});
    print("Changes: {d}\n", .{c.sqlite3_changes(db)});
    print("Total Changes: {d}\n", .{c.sqlite3_total_changes(db)});
}
```

### 3. Memory Debugging

```zig
// Custom allocator for debugging
const DebugAllocator = struct {
    parent: std.mem.Allocator,
    allocations: u32 = 0,
    deallocations: u32 = 0,
    
    pub fn alloc(self: *DebugAllocator, len: usize, alignment: u29) ![]u8 {
        const result = try self.parent.alloc(u8, len);
        self.allocations += 1;
        std.debug.print("ALLOC: {d} bytes, total allocs: {d}\n", .{ len, self.allocations });
        return result;
    }
    
    pub fn free(self: *DebugAllocator, buf: []u8) void {
        self.parent.free(buf);
        self.deallocations += 1;
        std.debug.print("FREE: {d} bytes, total frees: {d}\n", .{ buf.len, self.deallocations });
    }
    
    pub fn printStats(self: *DebugAllocator) void {
        std.debug.print("Memory Stats: {d} allocs, {d} frees, {d} leaks\n", 
            .{ self.allocations, self.deallocations, self.allocations - self.deallocations });
    }
};
```

### 4. SQL Query Debugging

```zig
// Log all SQL queries with timing
fn debugExecuteSQL(db: *c.sqlite3, sql: []const u8) !void {
    const start_time = std.time.microTimestamp();
    
    std.debug.print("QUERY: {s}\n", .{sql});
    
    var buf: [2048]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);
    const rc = c.sqlite3_exec(db, sql_cstr, debugCallback, null, null);
    
    const end_time = std.time.microTimestamp();
    const duration = end_time - start_time;
    
    if (rc != c.SQLITE_OK) {
        std.debug.print("ERROR: {s} (took {d}μs)\n", .{ std.mem.span(c.sqlite3_errmsg(db)), duration });
        return error.SQLError;
    } else {
        std.debug.print("SUCCESS: Query completed in {d}μs\n", .{duration});
    }
}

fn debugCallback(data: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, azColName: [*c][*c]u8) callconv(.c) c_int {
    _ = data;
    
    std.debug.print("ROW: ");
    for (0..@intCast(argc)) |i| {
        if (i > 0) std.debug.print(", ");
        const col_name = std.mem.span(azColName[i]);
        const value = if (argv[i] != null) std.mem.span(argv[i]) else "NULL";
        std.debug.print("{s}={s}", .{ col_name, value });
    }
    std.debug.print("\n");
    
    return 0;
}
```

## Platform-Specific Issues

### 1. Windows Issues

#### Problem: DLL Not Found
```
The program can't start because sqlite3.dll is missing
```

#### Solutions

**Install SQLite DLL:**
1. Download SQLite DLL from https://sqlite.org/download.html
2. Place `sqlite3.dll` in your application directory
3. Or install to system PATH

**Static linking (if available):**
```zig
// In build.zig
exe.linkSystemLibrary("sqlite3");
exe.linkLibC();
// For static linking on Windows:
exe.want_lto = false;
```

### 2. macOS Issues

#### Problem: dylib Loading Issues
```
dyld: Library not loaded: /usr/local/lib/libsqlite3.dylib
```

#### Solutions

**Fix library paths:**
```bash
# Check current paths
otool -L your_executable

# Fix paths if needed
install_name_tool -change /old/path/libsqlite3.dylib /new/path/libsqlite3.dylib your_executable
```

**Use system SQLite:**
```bash
# Ensure using system SQLite
export DYLD_LIBRARY_PATH="/usr/lib:$DYLD_LIBRARY_PATH"
```

### 3. Linux Distribution Issues

#### Problem: Old SQLite Version
```
error: undefined symbol: sqlite3_prepare_v2
```

#### Solutions

**Check SQLite version:**
```bash
sqlite3 --version
```

**Update SQLite:**
```bash
# Ubuntu/Debian
sudo apt update && sudo apt upgrade sqlite3 libsqlite3-dev

# CentOS/RHEL
sudo yum update sqlite sqlite-devel

# Fedora
sudo dnf update sqlite sqlite-devel
```

## Performance Troubleshooting

### 1. Query Performance Issues

**Use SQLite's built-in profiling:**
```bash
# Enable query profiler
sqlite3 database.db
.timer on
.explain on
SELECT * FROM large_table WHERE condition;
```

**Profile with Zig:**
```zig
fn profileQuery(db: *c.sqlite3, sql: []const u8, iterations: u32) !void {
    var total_time: i64 = 0;
    var min_time: i64 = std.math.maxInt(i64);
    var max_time: i64 = 0;
    
    for (0..iterations) |_| {
        const start = std.time.microTimestamp();
        
        var buf: [1024]u8 = undefined;
        const sql_cstr = createCString(&buf, sql);
        const rc = c.sqlite3_exec(db, sql_cstr, null, null, null);
        
        const end = std.time.microTimestamp();
        const duration = end - start;
        
        if (rc != c.SQLITE_OK) return error.QueryFailed;
        
        total_time += duration;
        min_time = @min(min_time, duration);
        max_time = @max(max_time, duration);
    }
    
    const avg_time = @divTrunc(total_time, @as(i64, @intCast(iterations)));
    print("Query Performance ({d} runs):\n", .{iterations});
    print("  Average: {d}μs\n", .{avg_time});
    print("  Min: {d}μs\n", .{min_time});
    print("  Max: {d}μs\n", .{max_time});
}
```

### 2. Memory Usage Issues

**Monitor SQLite memory:**
```zig
fn checkMemoryUsage(db: *c.sqlite3) void {
    print("SQLite Memory Usage:\n");
    print("  Current: {d} bytes\n", .{c.sqlite3_memory_used()});
    print("  High water: {d} bytes\n", .{c.sqlite3_memory_highwater(0)});
    print("  Page cache used: {d} pages\n", .{c.sqlite3_db_status(db, c.SQLITE_DBSTATUS_CACHE_USED, null, null, 0)});
}
```

## Getting Help

### 1. Gathering Information

When reporting issues, include:

```bash
# System information
uname -a                    # System details
zig version                 # Zig version
sqlite3 --version           # SQLite version
ldd ./zig-out/bin/zsl      # Library dependencies (Linux)
otool -L ./zig-out/bin/zsl # Library dependencies (macOS)

# Build information
zig build --verbose         # Verbose build output

# Runtime information
gdb ./zig-out/bin/zsl      # Debugger output if crashing
valgrind --tool=memcheck   # Memory debugging (Linux)
```

### 2. Useful Resources

- **SQLite Documentation**: https://sqlite.org/docs.html
- **Zig Documentation**: https://ziglang.org/documentation/
- **ZSQLite Repository**: Include link to your repository
- **SQLite Forum**: https://sqlite.org/forum/forum
- **Zig Community**: https://github.com/ziglang/zig/discussions

### 3. Creating Minimal Reproductions

```zig
// Example minimal reproduction template
const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub fn main() !void {
    std.debug.print("Minimal reproduction for issue #XXX\n", .{});
    std.debug.print("Zig version: {s}\n", .{@import("builtin").zig_version_string});
    
    // Your minimal reproduction code here
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(":memory:", &db);
    
    if (rc != c.SQLITE_OK) {
        std.debug.print("Error: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.OpenFailed;
    }
    
    defer _ = c.sqlite3_close(db);
    
    // Demonstrate the issue
    // ...
}
```

This troubleshooting guide should help resolve most common issues with ZSQLite. If you encounter problems not covered here, please create a minimal reproduction and report it with the system information listed above.
