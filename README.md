# zsqlite - Direct SQLite3 Bindings for Zig

A minimal, direct wrapper around SQLite's C API for Zig. Perfect for developers who want low-level control, transparency, and educational insight into SQLite C bindings.

## Why zsqlite?

**zsqlite** focuses on **direct SQLite C API access** with minimal abstraction, making it ideal for:

- **Learning SQLite C API** - Clear, documented examples of C interop
- **Performance-critical applications** - Zero-overhead direct bindings
- **Educational purposes** - Understanding how SQLite C bindings work
- **Custom wrapper development** - Solid foundation for building your own abstractions
- **Embedded systems** - Minimal dependencies and overhead


## Critical Discovery: linkLibC() Requirement

This project documents a **critical finding** that can save hours of debugging for anyone using SQLite with Zig.

## Project Structure

```
zsqlite/
├── build.zig                 # Build configuration  
├── src/
│   └── main.zig             # Examples and demonstrations
├── .gitignore               # Git ignore patterns
├── LICENSE                  # MIT License
└── README.md                # This file
```

## Prerequisites

### System Requirements
- Zig compiler (tested with 0.15.0-dev.847+850655f06)
- SQLite3 development libraries
- C runtime library support

### Installing SQLite on Ubuntu/Debian
```bash
sudo apt update
sudo apt install sqlite3 libsqlite3-dev
```

## Critical Finding: linkLibC() Requirement

**⚠️ IMPORTANT:** When using SQLite with Zig via `@cImport`, you **must** include `exe.linkLibC()` in your `build.zig` file.

### The Problem
Without `exe.linkLibC()`, the program will:
- Compile successfully
- Link without errors
- Crash with a segmentation fault at runtime when calling SQLite functions

### The Solution
In your `build.zig`, ensure you have both:
```zig
exe.linkSystemLibrary("sqlite3");
exe.linkLibC();  // ← This is critical!
```

### Complete build.zig Example
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsqlite",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    exe.linkSystemLibrary("sqlite3");
    exe.linkLibC();  // Essential for SQLite to work
    
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

## Basic Usage Example

Here's a minimal working example that opens an in-memory SQLite database:

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub fn main() !void {
    std.debug.print("SQLite test started\n", .{});
    
    var db: ?*c.sqlite3 = null;
    var buf: [256]u8 = undefined;
    const filename = ":memory:";
    
    // Prepare null-terminated C string
    std.mem.copyForwards(u8, buf[0..filename.len], filename);
    buf[filename.len] = 0;
    const cstr: [*c]const u8 = &buf;
    
    // Open database
    const rc = c.sqlite3_open(cstr, &db);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.OpenFailed;
    }
    
    std.debug.print("Database opened successfully!\n", .{});
    
    // Clean up
    _ = c.sqlite3_close(db);
}
```

## Error Handling with SQLite

When working with SQLite error messages, you can safely use `c.sqlite3_errmsg(db)` directly with `{s}` format specifier:

```zig
if (rc != c.SQLITE_OK) {
    std.debug.print("SQLite error: {s}\n", .{c.sqlite3_errmsg(db)});
    return error.SQLiteError;
}
```

## Common Issues and Solutions

### 1. Segmentation Fault on Function Call
**Symptom:** Program crashes when calling any SQLite function
**Cause:** Missing `exe.linkLibC()` in build.zig
**Solution:** Add `exe.linkLibC();` to your build configuration

### 2. Format String Errors with Error Messages
**Symptom:** Compile error about `std.mem.span: [*]const u8`
**Cause:** Trying to use `std.mem.span()` on SQLite error message pointers
**Solution:** Use `c.sqlite3_errmsg(db)` directly with `{s}` format

### 3. Library Not Found
**Symptom:** Link error about sqlite3 library
**Cause:** SQLite development libraries not installed
**Solution:** Install with `sudo apt install libsqlite3-dev`

## Debugging Tips

### 1. Verify SQLite Installation
```bash
# Check if SQLite is installed
sqlite3 --version

# Check development libraries
dpkg -l | grep sqlite
```

### 2. Verbose Build Output
```bash
zig build run --verbose
```

### 3. Using GDB for Runtime Issues
```bash
# Build and debug
zig build
gdb .zig-cache/o/[hash]/zsqlite
```

## Building and Running

```bash
# Build the project
zig build

# Run the project
zig build run

# Clean build cache
rm -rf .zig-cache zig-out
```

## Type Information

When working with SQLite functions, Zig's `@TypeOf()` can help understand the function signatures:

```zig
std.debug.print("sqlite3_open type: {s}\n", .{@typeName(@TypeOf(c.sqlite3_open))});
// Output: fn ([*c]const u8, [*c]?*cimport.struct_sqlite3) callconv(.c) c_int
```

## Memory Management

- SQLite handles its own memory management for most operations
- Always call `c.sqlite3_close(db)` to clean up database connections
- For error messages from `sqlite3_exec`, use `c.sqlite3_free()` when needed

## Further Reading

- [SQLite C API Documentation](https://sqlite.org/c3ref/intro.html)
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [Zig C Interoperability](https://ziglang.org/documentation/master/#C)

## Contributing

When adding new SQLite functionality:
1. Test with both file and in-memory databases
2. Ensure proper error handling
3. Document any new linkage requirements
4. Update this README with findings

---

**Key Takeaway:** The `exe.linkLibC()` requirement is essential but not obvious. This finding can save hours of debugging for anyone working with SQLite in Zig.

## Core SQLite Functions Roadmap

SQLite has 200+ functions, but most applications only need a core subset. This roadmap shows our implementation plan for **direct C API bindings** - ideal for developers who want control and transparency.

### **Phase 1: Essential Core (COMPLETED)**
*Basic database operations - minimum viable functionality*

- ✓ `sqlite3_open()` - Open database connection
- ✓ `sqlite3_close()` - Close database connection  
- ✓ `sqlite3_exec()` - Execute simple SQL statements
- ✓ `sqlite3_prepare_v2()` - Prepare SQL statements
- ✓ `sqlite3_bind_*()` - Bind parameters (text, int)
- ✓ `sqlite3_step()` - Execute prepared statement
- ✓ `sqlite3_finalize()` - Clean up prepared statement
- ✓ `sqlite3_column_*()` - Read result columns
- ✓ `sqlite3_errmsg()` - Get error messages

### **Phase 2: Complete Data Types (COMPLETED)**
*Support all SQLite data types and binding*

**Binding Functions:**
- ✓ `sqlite3_bind_blob()` - Bind binary data
- ✓ `sqlite3_bind_double()` - Bind floating point
- ✓ `sqlite3_bind_int64()` - Bind 64-bit integers
- ✓ `sqlite3_bind_null()` - Bind NULL values
- ✓ `sqlite3_bind_zeroblob()` - Bind zero-filled blob

**Column Reading Functions:**
- ✓ `sqlite3_column_blob()` - Read binary data
- ✓ `sqlite3_column_double()` - Read floating point
- ✓ `sqlite3_column_int64()` - Read 64-bit integers
- ✓ `sqlite3_column_bytes()` - Get data size
- ✓ `sqlite3_column_type()` - Get column data type
- ✓ `sqlite3_column_name()` - Get column name
- ✓ `sqlite3_column_count()` - Get number of columns

### **Phase 3: Transaction Management (COMPLETED)**
*Essential for data integrity*

- ✓ `sqlite3_get_autocommit()` - Check autocommit status
- ✓ Manual transaction handling via `sqlite3_exec()`:
  - `BEGIN TRANSACTION`
  - `COMMIT`
  - `ROLLBACK`
  - `SAVEPOINT` / `RELEASE SAVEPOINT`
- ✓ `sqlite3_changes()` - Get number of changed rows
- ✓ `sqlite3_total_changes()` - Get total changes in session
- ✓ `sqlite3_last_insert_rowid()` - Get last inserted row ID

### **Phase 4: Advanced Querying (COMPLETED)**
*Performance and flexibility improvements*

- ✓ `sqlite3_reset()` - Reset prepared statement for reuse
- ✓ `sqlite3_clear_bindings()` - Clear bound parameters
- ✓ `sqlite3_sql()` - Get original SQL text
- ✓ `sqlite3_changes()` - Get number of changed rows
- ✓ `sqlite3_last_insert_rowid()` - Get last inserted row ID
- ✓ `sqlite3_total_changes()` - Get total changes in session

### **Phase 5: Database Introspection (COMPLETED)**
*Schema discovery and metadata*

- ✓ `PRAGMA` statement support via `sqlite3_exec()`:
  - ✓ `PRAGMA schema_version` - Get schema version number
  - ✓ `PRAGMA table_list` - List all tables in database
  - ✓ `PRAGMA table_info(table_name)` - Get column information for table
  - ✓ `PRAGMA foreign_key_list(table_name)` - Get foreign key constraints
  - ✓ `PRAGMA index_list(table_name)` - Get indexes for table
  - ✓ `PRAGMA database_list` - List attached databases
- ✓ Database statistics and analysis:
  - ✓ Row counting with `SELECT COUNT(*) FROM table`
  - ✓ Table existence checking
  - ✓ Schema analysis and validation

### **Phase 6: Performance & Optimization (COMPLETED)**
*For production applications*

- ✓ `sqlite3_open_v2()` - Advanced database opening with flags
- ✓ `sqlite3_busy_timeout()` - Set busy timeout
- ✓ `sqlite3_busy_handler()` - Custom busy handler
- ✓ Connection configuration:
  - ✓ `PRAGMA journal_mode`
  - ✓ `PRAGMA synchronous`
  - ✓ `PRAGMA cache_size`
  - ✓ `PRAGMA foreign_keys`
  - ✓ `PRAGMA temp_store`
  - ✓ `PRAGMA mmap_size`

### **Phase 7: Advanced Features (NEXT PRIORITY)**
*For specialized use cases*

**Backup & Recovery:**
- [ ] `sqlite3_backup_init()`
- [ ] `sqlite3_backup_step()`
- [ ] `sqlite3_backup_finish()`

**User-Defined Functions:**
- [ ] `sqlite3_create_function()`
- [ ] `sqlite3_value_*()` functions
- [ ] `sqlite3_result_*()` functions

**WAL Mode Support:**
- [ ] `sqlite3_wal_checkpoint()`
- [ ] `sqlite3_wal_autocheckpoint()`

### **Function Categories by Usage**

**Critical (90% of applications need these):**
- Database connection management
- Basic CRUD operations
- Prepared statements
- Error handling
- Common data types (text, integer, real)

**Important (60% of applications):**
- Transactions
- Binary data (blobs)
- Metadata queries
- Row count/last insert ID

**Advanced (20% of applications):**
- Custom functions
- Backup/restore
- Performance tuning
- WAL mode

**Specialized (5% of applications):**
- Virtual tables
- Extensions
- Encryption hooks
- Custom VFS

### **Release Strategy**

**v0.1.0** - Phase 1 (COMPLETED) - Basic functionality working
**v0.2.0** - Phase 2 (COMPLETED) - Complete data type support
**v0.3.0** - Phase 3 (COMPLETED) - Transaction management
**v0.4.0** - Phase 4 (COMPLETED) - Advanced querying
**v0.5.0** - Phase 5 (COMPLETED) - Database introspection
**v0.6.0** - Phase 6 (COMPLETED) - Performance & optimization
**v1.0.0** - Phase 7 (Production ready)
**v2.0.0** - Phase 8+ (Advanced features)

### **Implementation Notes**

1. **Error Handling**: Every function should return Zig errors, not SQLite error codes
2. **Memory Safety**: Use Zig allocators and slices instead of raw C pointers where possible
3. **Type Safety**: Use Zig's compile-time type checking for SQL parameters
4. **Resource Management**: Use `defer` and RAII patterns for cleanup
5. **Documentation**: Each function should have usage examples

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

### SQLite License Notice

This project links to SQLite, which is in the public domain. See [SQLite Copyright](https://sqlite.org/copyright.html) for details.