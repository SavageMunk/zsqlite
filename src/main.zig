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

// Function to create a comprehensive test table with all data types
fn createTable(db: ?*c.sqlite3) !void {
    const create_sql =
        \\CREATE TABLE IF NOT EXISTS test_data (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    email TEXT UNIQUE,
        \\    age INTEGER,
        \\    salary REAL,
        \\    is_active INTEGER,
        \\    profile_picture BLOB,
        \\    notes TEXT,
        \\    metadata TEXT
        \\);
    ;
    try executeSQL(db, create_sql);
}

// Comprehensive data insertion with all SQLite data types
fn insertTestData(db: ?*c.sqlite3, name: []const u8, email: ?[]const u8, age: ?i64, salary: ?f64, is_active: ?bool, profile_picture: ?[]const u8, notes: ?[]const u8) !void {
    const insert_sql = "INSERT INTO test_data (name, email, age, salary, is_active, profile_picture, notes, metadata) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, insert_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare statement: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.PrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind name (TEXT) - required
    var name_buf: [256]u8 = undefined;
    const name_cstr = createCString(&name_buf, name);
    _ = c.sqlite3_bind_text(stmt, 1, name_cstr, -1, null);

    // Bind email (TEXT or NULL)
    if (email) |email_val| {
        var email_buf: [256]u8 = undefined;
        const email_cstr = createCString(&email_buf, email_val);
        _ = c.sqlite3_bind_text(stmt, 2, email_cstr, -1, null);
    } else {
        _ = c.sqlite3_bind_null(stmt, 2);
    }

    // Bind age (INTEGER or NULL)
    if (age) |age_val| {
        _ = c.sqlite3_bind_int64(stmt, 3, age_val);
    } else {
        _ = c.sqlite3_bind_null(stmt, 3);
    }

    // Bind salary (REAL/DOUBLE or NULL)
    if (salary) |salary_val| {
        _ = c.sqlite3_bind_double(stmt, 4, salary_val);
    } else {
        _ = c.sqlite3_bind_null(stmt, 4);
    }

    // Bind is_active (INTEGER as boolean or NULL)
    if (is_active) |active_val| {
        _ = c.sqlite3_bind_int(stmt, 5, if (active_val) 1 else 0);
    } else {
        _ = c.sqlite3_bind_null(stmt, 5);
    }

    // Bind profile_picture (BLOB or NULL)
    if (profile_picture) |pic_data| {
        _ = c.sqlite3_bind_blob(stmt, 6, pic_data.ptr, @intCast(pic_data.len), null);
    } else {
        _ = c.sqlite3_bind_null(stmt, 6);
    }

    // Bind notes (TEXT or NULL)
    if (notes) |notes_val| {
        var notes_buf: [512]u8 = undefined;
        const notes_cstr = createCString(&notes_buf, notes_val);
        _ = c.sqlite3_bind_text(stmt, 7, notes_cstr, -1, null);
    } else {
        _ = c.sqlite3_bind_null(stmt, 7);
    }

    // Bind metadata as zero-filled blob (demonstration of sqlite3_bind_zeroblob)
    _ = c.sqlite3_bind_zeroblob(stmt, 8, 64); // 64 bytes of zeros

    // Execute
    rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        std.debug.print("Failed to insert test data: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.InsertError;
    }

    std.debug.print("✓ Inserted: {s}\n", .{name});
}

// Comprehensive data querying with all column reading functions
fn queryTestData(db: ?*c.sqlite3) !void {
    const query_sql = "SELECT id, name, email, age, salary, is_active, profile_picture, notes, metadata FROM test_data ORDER BY id";
    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, query_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_cstr, -1, &stmt, null);

    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to prepare query: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.QueryError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("\n=== Test Data Analysis ===\n", .{});
    std.debug.print("Column Count: {}\n", .{c.sqlite3_column_count(stmt)});

    // Print column names
    std.debug.print("Columns: ", .{});
    const col_count = c.sqlite3_column_count(stmt);
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        const col_name = c.sqlite3_column_name(stmt, i);
        std.debug.print("{s} ", .{col_name});
    }
    std.debug.print("\n", .{});
    std.debug.print("==========================\n\n", .{});

    var row_num: i32 = 1;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        std.debug.print("--- Row {} ---\n", .{row_num});

        // Read ID (INTEGER)
        const id = c.sqlite3_column_int64(stmt, 0);
        const id_type = c.sqlite3_column_type(stmt, 0);
        std.debug.print("ID: {} (type: {})\n", .{ id, id_type });

        // Read name (TEXT)
        const name = c.sqlite3_column_text(stmt, 1);
        const name_type = c.sqlite3_column_type(stmt, 1);
        std.debug.print("Name: {s} (type: {})\n", .{ name, name_type });

        // Read email (TEXT or NULL)
        const email_type = c.sqlite3_column_type(stmt, 2);
        if (email_type == c.SQLITE_NULL) {
            std.debug.print("Email: NULL (type: {})\n", .{email_type});
        } else {
            const email = c.sqlite3_column_text(stmt, 2);
            std.debug.print("Email: {s} (type: {})\n", .{ email, email_type });
        }

        // Read age (INTEGER or NULL)
        const age_type = c.sqlite3_column_type(stmt, 3);
        if (age_type == c.SQLITE_NULL) {
            std.debug.print("Age: NULL (type: {})\n", .{age_type});
        } else {
            const age = c.sqlite3_column_int64(stmt, 3);
            std.debug.print("Age: {} (type: {})\n", .{ age, age_type });
        }

        // Read salary (REAL/DOUBLE or NULL)
        const salary_type = c.sqlite3_column_type(stmt, 4);
        if (salary_type == c.SQLITE_NULL) {
            std.debug.print("Salary: NULL (type: {})\n", .{salary_type});
        } else {
            const salary = c.sqlite3_column_double(stmt, 4);
            std.debug.print("Salary: {d:.2} (type: {})\n", .{ salary, salary_type });
        }

        // Read is_active (INTEGER/BOOLEAN or NULL)
        const active_type = c.sqlite3_column_type(stmt, 5);
        if (active_type == c.SQLITE_NULL) {
            std.debug.print("Active: NULL (type: {})\n", .{active_type});
        } else {
            const is_active = c.sqlite3_column_int(stmt, 5);
            std.debug.print("Active: {} (type: {})\n", .{ is_active == 1, active_type });
        }

        // Read profile_picture (BLOB or NULL)
        const pic_type = c.sqlite3_column_type(stmt, 6);
        if (pic_type == c.SQLITE_NULL) {
            std.debug.print("Profile Picture: NULL (type: {})\n", .{pic_type});
        } else {
            const pic_data = c.sqlite3_column_blob(stmt, 6);
            const pic_size = c.sqlite3_column_bytes(stmt, 6);
            std.debug.print("Profile Picture: {} bytes of data (type: {})\n", .{ pic_size, pic_type });

            // Print first few bytes as hex
            if (pic_size > 0) {
                const bytes = @as([*c]const u8, @ptrCast(pic_data));
                std.debug.print("  First bytes: ", .{});
                var j: i32 = 0;
                while (j < @min(pic_size, 8)) : (j += 1) {
                    std.debug.print("{x:0>2} ", .{bytes[@intCast(j)]});
                }
                std.debug.print("\n", .{});
            }
        }

        // Read notes (TEXT or NULL)
        const notes_type = c.sqlite3_column_type(stmt, 7);
        if (notes_type == c.SQLITE_NULL) {
            std.debug.print("Notes: NULL (type: {})\n", .{notes_type});
        } else {
            const notes = c.sqlite3_column_text(stmt, 7);
            std.debug.print("Notes: {s} (type: {})\n", .{ notes, notes_type });
        }

        // Read metadata (BLOB - zeroblob)
        const meta_type = c.sqlite3_column_type(stmt, 8);
        const meta_size = c.sqlite3_column_bytes(stmt, 8);
        std.debug.print("Metadata: {} bytes of zero-blob (type: {})\n", .{ meta_size, meta_type });

        std.debug.print("\n", .{});
        row_num += 1;
    }
    std.debug.print("=========================\n\n", .{});
}

pub fn main() !void {
    std.debug.print("zsqlite Phase 2 Demo - Complete Data Types\n", .{});
    std.debug.print("==========================================\n\n", .{});

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
    std.debug.print("Creating comprehensive test table...\n", .{});
    try createTable(db);
    std.debug.print("✓ Table created\n\n", .{});

    // Insert comprehensive test data demonstrating all data types
    std.debug.print("Inserting test data with all SQLite data types...\n", .{});

    // Sample binary data for blob
    const profile_pic = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }; // PNG header

    // Test with full data
    try insertTestData(db, "Alice Johnson", "alice@example.com", 28, 75000.50, true, &profile_pic, "Senior developer with 5 years experience");

    // Test with some null values
    try insertTestData(db, "Bob Smith", "bob@example.com", 35, null, false, null, null);

    // Test with more null values
    try insertTestData(db, "Charlie Brown", null, null, 45000.75, null, &profile_pic, "Entry level position");

    // Test with all nulls except required name
    try insertTestData(db, "Dana White", null, null, null, null, null, null);

    std.debug.print("✓ Test data inserted\n\n", .{});

    // Query and display comprehensive data analysis
    std.debug.print("Querying and analyzing all data types...\n", .{});
    try queryTestData(db);

    // Demonstrate error handling with duplicate email
    std.debug.print("Testing constraint violation...\n", .{});
    insertTestData(db, "Alice Clone", "alice@example.com", 30, 60000.0, true, null, "This should fail") catch |err| {
        std.debug.print("✓ Caught expected error: {}\n\n", .{err});
    };

    std.debug.print("Phase 2 Demo completed successfully!\n", .{});
    std.debug.print("All SQLite data types and binding functions demonstrated:\n", .{});
    std.debug.print("✓ sqlite3_bind_text(), sqlite3_bind_int64(), sqlite3_bind_double()\n", .{});
    std.debug.print("✓ sqlite3_bind_blob(), sqlite3_bind_null(), sqlite3_bind_zeroblob()\n", .{});
    std.debug.print("✓ sqlite3_column_text(), sqlite3_column_int64(), sqlite3_column_double()\n", .{});
    std.debug.print("✓ sqlite3_column_blob(), sqlite3_column_bytes(), sqlite3_column_type()\n", .{});
    std.debug.print("✓ sqlite3_column_name(), sqlite3_column_count()\n", .{});
}
