# ZSQLite Performance Tuning Guide

## Overview

This guide covers performance optimization techniques for ZSQLite applications, from basic database design to advanced SQLite features.

## Database Design Optimization

### 1. Schema Design

#### Primary Keys
```sql
-- Efficient: Use INTEGER PRIMARY KEY for row IDs
CREATE TABLE users (
    id INTEGER PRIMARY KEY,  -- Maps to SQLite's rowid
    name TEXT NOT NULL,
    email TEXT UNIQUE
);

-- Less efficient: Composite or string primary keys
CREATE TABLE bad_users (
    uuid TEXT PRIMARY KEY,  -- Requires additional index storage
    name TEXT,
    email TEXT
);
```

#### Indexes
```sql
-- Create indexes for frequently queried columns
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_name ON users(name);

-- Composite indexes for multi-column queries
CREATE INDEX idx_users_name_email ON users(name, email);

-- Covering indexes include all needed columns
CREATE INDEX idx_users_covering ON users(name) 
INCLUDE (email, created_at);
```

#### Data Types
```sql
-- Use appropriate data types
CREATE TABLE optimal_types (
    id INTEGER PRIMARY KEY,
    price REAL,              -- For floating point numbers
    quantity INTEGER,        -- For whole numbers
    description TEXT,        -- For strings
    data BLOB,              -- For binary data
    created_at INTEGER      -- Unix timestamp (more efficient than TEXT dates)
);
```

### 2. Normalization vs. Denormalization

#### When to Normalize
```sql
-- Normalized: Reduces storage, maintains consistency
CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, amount REAL);
```

#### When to Denormalize
```sql
-- Denormalized: Faster queries, more storage
CREATE TABLE order_summary (
    id INTEGER PRIMARY KEY,
    customer_name TEXT,     -- Duplicated from customers table
    amount REAL,
    order_date INTEGER
);
```

## Query Optimization

### 1. Use Prepared Statements

#### Zig Implementation
```zig
// Efficient: Prepare once, execute many times
const sql = "SELECT * FROM users WHERE age > ? AND city = ?";
var stmt: ?*c.sqlite3_stmt = null;

// Prepare once
var buf: [256]u8 = undefined;
const sql_cstr = createCString(&buf, sql);
const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

// Execute multiple times
for (queries) |query| {
    _ = c.sqlite3_bind_int(stmt, 1, query.min_age);
    
    var name_buf: [64]u8 = undefined;
    const city_cstr = createCString(&name_buf, query.city);
    _ = c.sqlite3_bind_text(stmt, 2, city_cstr, -1, null);
    
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // Process results
    }
    
    _ = c.sqlite3_reset(stmt);  // Reuse statement
}

_ = c.sqlite3_finalize(stmt);
```

### 2. Query Analysis

#### Use EXPLAIN QUERY PLAN
```sql
-- Analyze query execution
EXPLAIN QUERY PLAN 
SELECT u.name, COUNT(o.id) 
FROM users u 
LEFT JOIN orders o ON u.id = o.user_id 
GROUP BY u.id;
```

#### Common Query Patterns
```sql
-- Efficient: Use indexes
SELECT * FROM users WHERE email = 'john@example.com';

-- Inefficient: Leading wildcards prevent index usage
SELECT * FROM users WHERE email LIKE '%@example.com';

-- Better: Trailing wildcards can use indexes
SELECT * FROM users WHERE email LIKE 'john%';
```

### 3. Batch Operations

#### Bulk Inserts
```zig
// Efficient: Use transactions for bulk operations
try executeSQL(state, "BEGIN TRANSACTION");

const insert_sql = "INSERT INTO users (name, email) VALUES (?, ?)";
var stmt: ?*c.sqlite3_stmt = null;
// ... prepare statement ...

for (users) |user| {
    // Bind and execute
    _ = c.sqlite3_bind_text(stmt, 1, user.name, -1, null);
    _ = c.sqlite3_bind_text(stmt, 2, user.email, -1, null);
    _ = c.sqlite3_step(stmt);
    _ = c.sqlite3_reset(stmt);
}

try executeSQL(state, "COMMIT");
```

## SQLite Configuration Tuning

### 1. PRAGMA Settings

#### Journal Mode
```sql
-- WAL mode for better concurrency
PRAGMA journal_mode = WAL;

-- DELETE mode for single-writer scenarios
PRAGMA journal_mode = DELETE;

-- MEMORY mode for temporary databases
PRAGMA journal_mode = MEMORY;
```

#### Synchronization
```sql
-- Full durability (default)
PRAGMA synchronous = FULL;

-- Faster, less durability
PRAGMA synchronous = NORMAL;

-- Fastest, minimal durability (only for temporary data)
PRAGMA synchronous = OFF;
```

#### Cache Size
```sql
-- Increase cache size (in pages, negative = KB)
PRAGMA cache_size = -64000;  -- 64MB cache

-- Check current cache size
PRAGMA cache_size;
```

#### Memory-Mapped I/O
```sql
-- Enable memory-mapped I/O (faster for large databases)
PRAGMA mmap_size = 268435456;  -- 256MB

-- Disable for small databases or memory-constrained systems
PRAGMA mmap_size = 0;
```

### 2. Zig Configuration Implementation

```zig
// Configure database for performance
fn optimizeDatabase(db: *c.sqlite3) !void {
    var buf: [256]u8 = undefined;
    
    // Set WAL mode for better concurrency
    const wal_sql = "PRAGMA journal_mode = WAL";
    const wal_cstr = createCString(&buf, wal_sql);
    var rc = c.sqlite3_exec(db, wal_cstr, null, null, null);
    if (rc != c.SQLITE_OK) return error.ConfigFailed;
    
    // Increase cache size
    const cache_sql = "PRAGMA cache_size = -64000";
    const cache_cstr = createCString(&buf, cache_sql);
    rc = c.sqlite3_exec(db, cache_cstr, null, null, null);
    if (rc != c.SQLITE_OK) return error.ConfigFailed;
    
    // Enable memory-mapped I/O
    const mmap_sql = "PRAGMA mmap_size = 268435456";
    const mmap_cstr = createCString(&buf, mmap_sql);
    rc = c.sqlite3_exec(db, mmap_cstr, null, null, null);
    if (rc != c.SQLITE_OK) return error.ConfigFailed;
    
    // Set busy timeout
    rc = c.sqlite3_busy_timeout(db, 30000);  // 30 seconds
    if (rc != c.SQLITE_OK) return error.ConfigFailed;
}
```

## Memory Management Optimization

### 1. Connection Management

```zig
// Connection pool for multi-threaded applications
const ConnectionPool = struct {
    connections: std.ArrayList(*c.sqlite3),
    mutex: std.Thread.Mutex,
    max_connections: usize,
    
    fn getConnection(self: *ConnectionPool) !*c.sqlite3 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.connections.items.len > 0) {
            return self.connections.pop();
        }
        
        if (self.connections.capacity < self.max_connections) {
            // Create new connection
            var db: ?*c.sqlite3 = null;
            const rc = c.sqlite3_open(":memory:", &db);
            if (rc != c.SQLITE_OK) return error.ConnectionFailed;
            return db.?;
        }
        
        return error.NoConnectionsAvailable;
    }
    
    fn returnConnection(self: *ConnectionPool, db: *c.sqlite3) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connections.append(db) catch {
            // Pool full, close connection
            _ = c.sqlite3_close(db);
        };
    }
};
```

### 2. Statement Caching

```zig
// Cache prepared statements for reuse
const StatementCache = struct {
    statements: std.HashMap([]const u8, *c.sqlite3_stmt, std.hash_map.StringContext, 80),
    
    fn getStatement(self: *StatementCache, db: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
        if (self.statements.get(sql)) |stmt| {
            _ = c.sqlite3_reset(stmt);
            return stmt;
        }
        
        // Prepare new statement
        var stmt: ?*c.sqlite3_stmt = null;
        var buf: [1024]u8 = undefined;
        const sql_cstr = createCString(&buf, sql);
        const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        
        // Cache statement
        const sql_copy = try allocator.dupe(u8, sql);
        try self.statements.put(sql_copy, stmt.?);
        return stmt.?;
    }
};
```

## I/O Optimization

### 1. Batch Operations

```sql
-- Use INSERT OR REPLACE for upserts
INSERT OR REPLACE INTO cache (key, value, expires) 
VALUES ('key1', 'value1', 1234567890);

-- Use compound statements
WITH RECURSIVE
  cnt(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM cnt WHERE x<1000)
INSERT INTO test_data (id, value) 
SELECT x, 'value' || x FROM cnt;
```

### 2. Temporary Tables and Views

```sql
-- Use temporary tables for complex operations
CREATE TEMP TABLE calculation_temp AS
SELECT customer_id, SUM(amount) as total
FROM orders 
WHERE order_date > strftime('%s', 'now', '-1 month')
GROUP BY customer_id;

-- Create indexes on temporary tables
CREATE INDEX temp_idx ON calculation_temp(customer_id);

-- Use the temporary table
SELECT c.name, t.total
FROM customers c
JOIN calculation_temp t ON c.id = t.customer_id
ORDER BY t.total DESC;
```

## Monitoring and Profiling

### 1. Performance Metrics

```zig
// Timing wrapper for operations
fn timedExecute(db: *c.sqlite3, sql: []const u8) !i64 {
    const start = std.time.microTimestamp();
    
    var buf: [1024]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);
    const rc = c.sqlite3_exec(db, sql_cstr, null, null, null);
    
    const end = std.time.microTimestamp();
    const duration = end - start;
    
    if (rc != c.SQLITE_OK) return error.ExecutionFailed;
    return duration;
}
```

### 2. Database Statistics

```sql
-- Check database statistics
SELECT 
    name,
    SUM("ncell") as total_cells,
    SUM("payload") as total_payload,
    SUM("unused") as unused_space
FROM dbstat 
GROUP BY name;

-- Check index usage
SELECT 
    tbl as table_name,
    idx as index_name,
    stat as statistics
FROM sqlite_stat1;
```

### 3. Query Performance Analysis

```zig
// Analyze query performance
fn analyzeQuery(db: *c.sqlite3, sql: []const u8) !void {
    // Get query plan
    var plan_buf: [2048]u8 = undefined;
    const plan_sql = try std.fmt.bufPrint(plan_buf[0..], "EXPLAIN QUERY PLAN {s}", .{sql});
    
    print("Query Plan for: {s}\n", .{sql});
    print("================\n");
    
    try executeSQL(&CLIState{.db = db}, plan_sql);
    
    // Time the actual query
    const duration = try timedExecute(db, sql);
    print("Execution time: {d} microseconds\n", .{duration});
}
```

## Best Practices Summary

### 1. Schema Design
- Use INTEGER PRIMARY KEY when possible
- Create indexes for frequently queried columns
- Choose appropriate data types
- Consider denormalization for read-heavy workloads

### 2. Query Optimization  
- Use prepared statements for repeated queries
- Analyze queries with EXPLAIN QUERY PLAN
- Batch operations in transactions
- Avoid leading wildcards in LIKE queries

### 3. Configuration
- Set appropriate journal mode (WAL for concurrency)
- Tune cache size based on available memory
- Enable memory-mapped I/O for large databases
- Set reasonable busy timeout values

### 4. Application Design
- Pool database connections
- Cache prepared statements
- Use temporary tables for complex operations
- Monitor and profile query performance

### 5. Maintenance
- Regular VACUUM operations for databases with many deletes
- Update statistics with ANALYZE command
- Monitor database file size and growth
- Plan for backup and recovery procedures

By following these performance tuning guidelines, ZSQLite applications can achieve optimal performance while maintaining data integrity and reliability.
