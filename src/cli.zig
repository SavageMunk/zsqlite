const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});
const test_module = @import("test.zig");

const print = std.debug.print;
const allocator = std.heap.page_allocator;

// CLI Configuration
const CLI_CONFIG = struct {
    prompt: []const u8 = "zsl> ",
    continuation_prompt: []const u8 = "...> ",
    max_line_length: usize = 4096,
    history_file: []const u8 = ".zsl_history",
};

// Command types
const CommandType = enum {
    sql,
    meta,
    exit,
    help,
    invalid,
};

// Command structure
const Command = struct {
    type: CommandType,
    content: []const u8,
};

// Database connection state
const CLIState = struct {
    db: ?*c.sqlite3 = null,
    current_file: ?[]const u8 = null,
    in_transaction: bool = false,
    last_error: ?[]const u8 = null,

    // Multiple database support
    databases: std.HashMap([]const u8, *c.sqlite3, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    current_db_name: ?[]const u8 = null,

    // CLI enhancement features
    syntax_highlighting: bool = true,
    show_query_time: bool = true,
    result_format: ResultFormat = .table,

    fn init() CLIState {
        return CLIState{
            .databases = std.HashMap([]const u8, *c.sqlite3, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    fn deinit(self: *CLIState) void {
        if (self.db != null) {
            _ = c.sqlite3_close(self.db);
        }

        // Close all databases
        var iterator = self.databases.iterator();
        while (iterator.next()) |entry| {
            _ = c.sqlite3_close(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        self.databases.deinit();
    }
};

// Result formatting options
const ResultFormat = enum {
    table,
    csv,
    json,
    vertical,
};

// Helper function to create null-terminated C string
fn createCString(buf: []u8, str: []const u8) [*c]const u8 {
    std.mem.copyForwards(u8, buf[0..str.len], str);
    buf[str.len] = 0;
    return @ptrCast(buf.ptr);
}

// Parse command line input
fn parseCommand(input: []const u8) Command {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");

    if (trimmed.len == 0) {
        return Command{ .type = .invalid, .content = "" };
    }

    // Check for meta commands (start with \)
    if (trimmed[0] == '\\') {
        if (std.mem.eql(u8, trimmed, "\\q") or std.mem.eql(u8, trimmed, "\\quit")) {
            return Command{ .type = .exit, .content = "" };
        } else if (std.mem.eql(u8, trimmed, "\\h") or std.mem.eql(u8, trimmed, "\\help")) {
            return Command{ .type = .help, .content = "" };
        } else {
            return Command{ .type = .meta, .content = trimmed };
        }
    }

    // Check for exit commands
    if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
        return Command{ .type = .exit, .content = "" };
    }

    // Everything else is treated as SQL
    return Command{ .type = .sql, .content = trimmed };
}

// MySQL to SQLite command translation
fn translateMySQLCommand(alloc: std.mem.Allocator, sql: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, sql, " \t\n\r;");
    const upper = try std.ascii.allocUpperString(alloc, trimmed);
    defer alloc.free(upper);

    // SHOW TABLES -> SELECT name FROM sqlite_master WHERE type='table'
    if (std.mem.eql(u8, upper, "SHOW TABLES")) {
        return try alloc.dupe(u8, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
    }

    // SHOW DATABASES -> Not applicable in SQLite, but we can show attached databases
    if (std.mem.eql(u8, upper, "SHOW DATABASES")) {
        return try alloc.dupe(u8, "PRAGMA database_list");
    }

    // DESCRIBE table_name -> PRAGMA table_info(table_name)
    if (std.mem.startsWith(u8, upper, "DESCRIBE ")) {
        const table_name = std.mem.trim(u8, trimmed[9..], " \t\n\r;");
        return try std.fmt.allocPrint(alloc, "PRAGMA table_info({s})", .{table_name});
    }
    if (std.mem.startsWith(u8, upper, "DESC ")) {
        const table_name = std.mem.trim(u8, trimmed[5..], " \t\n\r;");
        return try std.fmt.allocPrint(alloc, "PRAGMA table_info({s})", .{table_name});
    }

    // SHOW COLUMNS FROM table_name -> PRAGMA table_info(table_name)
    if (std.mem.startsWith(u8, upper, "SHOW COLUMNS FROM ")) {
        const table_name = std.mem.trim(u8, trimmed[18..], " \t\n\r;");
        return try std.fmt.allocPrint(alloc, "PRAGMA table_info({s})", .{table_name});
    }

    // SHOW INDEX FROM table_name -> PRAGMA index_list(table_name)
    if (std.mem.startsWith(u8, upper, "SHOW INDEX FROM ")) {
        const table_name = std.mem.trim(u8, trimmed[16..], " \t\n\r;");
        return try std.fmt.allocPrint(alloc, "PRAGMA index_list({s})", .{table_name});
    }
    if (std.mem.startsWith(u8, upper, "SHOW INDEXES FROM ")) {
        const table_name = std.mem.trim(u8, trimmed[18..], " \t\n\r;");
        return try std.fmt.allocPrint(alloc, "PRAGMA index_list({s})", .{table_name});
    }

    // SHOW CREATE TABLE table_name -> SELECT sql FROM sqlite_master WHERE name='table_name'
    if (std.mem.startsWith(u8, upper, "SHOW CREATE TABLE ")) {
        const table_name = std.mem.trim(u8, trimmed[18..], " \t\n\r;");
        return try std.fmt.allocPrint(alloc, "SELECT sql FROM sqlite_master WHERE name='{s}' AND type='table'", .{table_name});
    }

    // SHOW VARIABLES -> PRAGMA compile_options (closest equivalent)
    if (std.mem.eql(u8, upper, "SHOW VARIABLES")) {
        return try alloc.dupe(u8, "PRAGMA compile_options");
    }

    // SHOW STATUS -> Show various SQLite status information
    if (std.mem.eql(u8, upper, "SHOW STATUS")) {
        return try alloc.dupe(u8, "SELECT 'database_size' as Variable_name, page_count * page_size as Value FROM pragma_page_count(), pragma_page_size() UNION ALL SELECT 'page_size', page_size FROM pragma_page_size() UNION ALL SELECT 'page_count', page_count FROM pragma_page_count()");
    }

    // SHOW PROCESSLIST -> Not applicable in SQLite
    if (std.mem.eql(u8, upper, "SHOW PROCESSLIST")) {
        return try alloc.dupe(u8, "SELECT 'SQLite does not support process lists' as message");
    }

    // No translation needed - return original
    return try alloc.dupe(u8, sql);
}

// Execute SQL command
fn executeSQL(state: *CLIState, sql: []const u8) !void {
    if (state.db == null) {
        print("Error: No database connection. Use \\o <filename> to open a database.\n", .{});
        return;
    }

    // Translate MySQL commands to SQLite equivalents
    const translated_sql = translateMySQLCommand(allocator, sql) catch sql;
    defer if (translated_sql.ptr != sql.ptr) allocator.free(translated_sql);

    // Use the translated SQL for the rest of the function
    const actual_sql = translated_sql;

    // Show highlighted SQL if enabled
    if (state.syntax_highlighting) {
        print("Executing: ", .{});
        if (highlightSQL(allocator, actual_sql)) |highlighted| {
            defer allocator.free(highlighted);
            print("{s}\n", .{highlighted});
        } else |_| {
            print("{s}\n", .{actual_sql});
        }
    }

    var buf: [4096]u8 = undefined;
    const sql_cstr = createCString(&buf, actual_sql);

    // Reset the callback state for each query
    callback_first_row = true;

    // Time the query if enabled
    const start_time = if (state.show_query_time) std.time.milliTimestamp() else 0;

    var errmsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(state.db, sql_cstr, sqliteCallback, null, &errmsg);

    const end_time = if (state.show_query_time) std.time.milliTimestamp() else 0;

    if (rc != c.SQLITE_OK) {
        defer if (errmsg != null) c.sqlite3_free(errmsg);
        if (errmsg != null) {
            print("SQL Error: {s}\n", .{std.mem.span(errmsg.?)});
        } else {
            print("SQL Error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(state.db))});
        }
        return;
    }

    // Show query time if enabled
    if (state.show_query_time) {
        const duration = end_time - start_time;
        print("Query executed in {d}ms\n", .{duration});
    }

    // Update transaction state
    state.in_transaction = c.sqlite3_get_autocommit(state.db) == 0;
}

// SQLite callback for result display
var callback_first_row = true;

fn sqliteCallback(data: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, azColName: [*c][*c]u8) callconv(.c) c_int {
    _ = data;

    // Print column headers (only on first row)
    if (callback_first_row) {
        for (0..@intCast(argc)) |i| {
            if (i > 0) print(" | ", .{});
            print("{s}", .{azColName[i]});
        }
        print("\n", .{});

        // Print separator
        for (0..@intCast(argc)) |i| {
            if (i > 0) print("-+-", .{});
            const col_name = std.mem.span(azColName[i]);
            for (0..col_name.len) |_| {
                print("-", .{});
            }
        }
        print("\n", .{});
        callback_first_row = false;
    }

    // Print row data
    for (0..@intCast(argc)) |i| {
        if (i > 0) print(" | ", .{});
        if (argv[i] != null) {
            print("{s}", .{argv[i]});
        } else {
            print("NULL", .{});
        }
    }
    print("\n", .{});

    return 0;
}

// Execute meta command
fn executeMetaCommand(state: *CLIState, command: []const u8) !void {
    if (std.mem.startsWith(u8, command, "\\o ")) {
        // Open database
        const filename = std.mem.trim(u8, command[3..], " ");
        try openDatabase(state, filename);
    } else if (std.mem.eql(u8, command, "\\c")) {
        // Close database
        closeDatabase(state);
    } else if (std.mem.eql(u8, command, "\\l")) {
        // List tables
        try listTables(state);
    } else if (std.mem.startsWith(u8, command, "\\d ")) {
        // Describe table
        const table_name = std.mem.trim(u8, command[3..], " ");
        try describeTable(state, table_name);
    } else if (std.mem.eql(u8, command, "\\s")) {
        // Show status
        showStatus(state);
    } else if (std.mem.eql(u8, command, "\\schema")) {
        // Show schema visualization
        try showSchemaVisualization(state);
    } else if (std.mem.startsWith(u8, command, "\\export ")) {
        // Export database to SQL file
        const filename = std.mem.trim(u8, command[8..], " ");
        try exportDatabase(state, filename);
    } else if (std.mem.startsWith(u8, command, "\\import ")) {
        // Import SQL file into database
        const filename = std.mem.trim(u8, command[8..], " ");
        try importSQLFile(state, filename);
    } else if (std.mem.eql(u8, command, "\\config")) {
        // Show current configuration
        showConfig();
    } else if (std.mem.startsWith(u8, command, "\\set ")) {
        // Set configuration option
        const setting = std.mem.trim(u8, command[5..], " ");
        try setConfig(setting);
    } else if (std.mem.startsWith(u8, command, "\\format ")) {
        // Set result format
        const format = std.mem.trim(u8, command[8..], " ");
        try setResultFormat(state, format);
    } else if (std.mem.startsWith(u8, command, "\\use ")) {
        // Switch database connection (for multiple DB support)
        const db_name = std.mem.trim(u8, command[5..], " ");
        try useDatabase(state, db_name);
    } else if (std.mem.eql(u8, command, "\\healthcheck") or std.mem.eql(u8, command, "\\health")) {
        // Run database health check
        try runHealthCheckCommand(state);
    } else if (std.mem.startsWith(u8, command, "\\createhealthy ")) {
        // Create a sample healthy database
        const db_path = std.mem.trim(u8, command[14..], " ");
        try createHealthyDatabaseCommand(db_path);
    } else if (std.mem.eql(u8, command, "\\createhealthy")) {
        print("Usage: \\createhealthy <database_path>\n", .{});
        print("Creates a sample database that will always pass health checks.\n", .{});
    } else {
        print("Unknown meta command: {s}\n", .{command});
        print("Use \\h for help.\n", .{});
    }
}

// Open database connection
fn openDatabase(state: *CLIState, filename: []const u8) !void {
    // Close existing connection
    if (state.db != null) {
        _ = c.sqlite3_close(state.db);
    }

    var buf: [512]u8 = undefined;
    const filename_cstr = createCString(&buf, filename);

    const rc = c.sqlite3_open(filename_cstr, &state.db);
    if (rc != c.SQLITE_OK) {
        print("Error opening database '{s}': {s}\n", .{ filename, std.mem.span(c.sqlite3_errmsg(state.db)) });
        _ = c.sqlite3_close(state.db);
        state.db = null;
        return;
    }

    // Store current filename
    state.current_file = try allocator.dupe(u8, filename);
    state.in_transaction = false;

    print("Opened database: {s}\n", .{filename});
}

// Close database connection
fn closeDatabase(state: *CLIState) void {
    if (state.db != null) {
        _ = c.sqlite3_close(state.db);
        state.db = null;

        if (state.current_file != null) {
            allocator.free(state.current_file.?);
            state.current_file = null;
        }

        state.in_transaction = false;
        print("Database connection closed.\n", .{});
    } else {
        print("No database connection to close.\n", .{});
    }
}

// List all tables in the database
fn listTables(state: *CLIState) !void {
    if (state.db == null) {
        print("Error: No database connection.\n", .{});
        return;
    }

    const sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name";
    try executeSQL(state, sql);
}

// Describe table structure
fn describeTable(state: *CLIState, table_name: []const u8) !void {
    if (state.db == null) {
        print("Error: No database connection.\n", .{});
        return;
    }

    const sql = try std.fmt.allocPrint(allocator, "PRAGMA table_info({s})", .{table_name});
    defer allocator.free(sql);
    try executeSQL(state, sql);
}

// Show current status
fn showStatus(state: *CLIState) void {
    print("=== ZSQLite CLI Status ===\n", .{});
    if (state.current_file) |file| {
        print("Database: {s}\n", .{file});
        print("Connection: Open\n", .{});
        print("Transaction: {s}\n", .{if (state.in_transaction) "Active" else "None"});
    } else {
        print("Database: None\n", .{});
        print("Connection: Closed\n", .{});
    }
    print("========================\n", .{});
}

// Show schema visualization
fn showSchemaVisualization(state: *CLIState) !void {
    if (state.db == null) {
        print("Error: No database connection.\n", .{});
        return;
    }

    print("=== Database Schema ===\n", .{});

    // Get all tables and views
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY type, name";

    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);

    const rc = c.sqlite3_prepare_v2(state.db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) {
        print("Error preparing statement: {s}\n", .{std.mem.span(c.sqlite3_errmsg(state.db))});
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var current_type: ?[]const u8 = null;

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const obj_type = std.mem.span(c.sqlite3_column_text(stmt, 1));
        _ = c.sqlite3_column_text(stmt, 2); // SQL definition (unused for visualization)

        // Print type header
        if (current_type == null or !std.mem.eql(u8, current_type.?, obj_type)) {
            current_type = obj_type;
            const type_upper = try allocator.alloc(u8, obj_type.len);
            defer allocator.free(type_upper);
            _ = std.ascii.upperString(type_upper, obj_type);
            print("\n{s}S:\n", .{type_upper});
        }

        print("  └─ {s}\n", .{name});

        // Show table columns
        if (std.mem.eql(u8, obj_type, "table")) {
            try showTableColumns(state, name);
        }
    }

    // Show relationships (foreign keys)
    print("\nRELATIONSHIPS:\n", .{});
    try showForeignKeys(state);

    print("=====================\n", .{});
}

// Show table columns for schema visualization
fn showTableColumns(state: *CLIState, table_name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const pragma_sql = try std.fmt.bufPrint(buf[0..], "PRAGMA table_info({s})", .{table_name});
    const pragma_cstr = createCString(&buf, pragma_sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(state.db, pragma_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const col_name = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const col_type = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const not_null = c.sqlite3_column_int(stmt, 3) == 1;
        const pk = c.sqlite3_column_int(stmt, 5) > 0;

        var flags = std.ArrayList(u8).init(allocator);
        defer flags.deinit();

        if (pk) try flags.appendSlice("PK");
        if (not_null) {
            if (flags.items.len > 0) try flags.appendSlice(", ");
            try flags.appendSlice("NOT NULL");
        }

        if (flags.items.len > 0) {
            print("     ├─ {s}: {s} ({s})\n", .{ col_name, col_type, flags.items });
        } else {
            print("     ├─ {s}: {s}\n", .{ col_name, col_type });
        }
    }
}

// Show foreign keys for schema visualization
fn showForeignKeys(state: *CLIState) !void {
    // Get all tables first
    var tables = std.ArrayList([]const u8).init(allocator);
    defer {
        for (tables.items) |table| {
            allocator.free(table);
        }
        tables.deinit();
    }

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name";
    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);

    var rc = c.sqlite3_prepare_v2(state.db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name = std.mem.span(c.sqlite3_column_text(stmt, 0));
        try tables.append(try allocator.dupe(u8, name));
    }

    // Check foreign keys for each table
    var found_relationships = false;
    for (tables.items) |table| {
        var fk_stmt: ?*c.sqlite3_stmt = null;
        const pragma_sql = try std.fmt.bufPrint(buf[0..], "PRAGMA foreign_key_list({s})", .{table});
        const pragma_cstr = createCString(&buf, pragma_sql);

        rc = c.sqlite3_prepare_v2(state.db, pragma_cstr, -1, &fk_stmt, null);
        if (rc != c.SQLITE_OK) continue;
        defer _ = c.sqlite3_finalize(fk_stmt);

        while (c.sqlite3_step(fk_stmt) == c.SQLITE_ROW) {
            const from_col = std.mem.span(c.sqlite3_column_text(fk_stmt, 3));
            const to_table = std.mem.span(c.sqlite3_column_text(fk_stmt, 2));
            const to_col = std.mem.span(c.sqlite3_column_text(fk_stmt, 4));

            print("  {s}.{s} -> {s}.{s}\n", .{ table, from_col, to_table, to_col });
            found_relationships = true;
        }
    }

    if (!found_relationships) {
        print("  (No foreign key relationships found)\n", .{});
    }
}

// Export database to SQL file
fn exportDatabase(state: *CLIState, filename: []const u8) !void {
    if (state.db == null) {
        print("Error: No database connection.\n", .{});
        return;
    }

    const file = std.fs.cwd().createFile(filename, .{}) catch |err| {
        print("Error creating file '{s}': {}\n", .{ filename, err });
        return;
    };
    defer file.close();

    var writer = file.writer();

    try writer.print("-- SQLite database export\n", .{});
    try writer.print("-- Generated by ZSQLite CLI\n", .{});
    try writer.print("-- Database: {s}\n\n", .{state.current_file orelse "unknown"});

    // Export schema
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type DESC, name";
    var buf: [512]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);

    var rc = c.sqlite3_prepare_v2(state.db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) {
        print("Error preparing schema export: {s}\n", .{std.mem.span(c.sqlite3_errmsg(state.db))});
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);

    try writer.print("-- Schema\n", .{});
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const sql_text = std.mem.span(c.sqlite3_column_text(stmt, 0));
        try writer.print("{s};\n", .{sql_text});
    }

    // Export data
    try writer.print("\n-- Data\n", .{});

    // Get all tables
    var table_stmt: ?*c.sqlite3_stmt = null;
    const table_sql = "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name";
    const table_cstr = createCString(&buf, table_sql);

    rc = c.sqlite3_prepare_v2(state.db, table_cstr, -1, &table_stmt, null);
    if (rc != c.SQLITE_OK) {
        print("Error getting tables: {s}\n", .{std.mem.span(c.sqlite3_errmsg(state.db))});
        return;
    }
    defer _ = c.sqlite3_finalize(table_stmt);

    while (c.sqlite3_step(table_stmt) == c.SQLITE_ROW) {
        const table_name = std.mem.span(c.sqlite3_column_text(table_stmt, 0));
        try exportTableData(state, writer, table_name);
    }

    print("Database exported to '{s}'\n", .{filename});
}

// Export table data as INSERT statements
fn exportTableData(state: *CLIState, writer: anytype, table_name: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const sql = try std.fmt.bufPrint(buf[0..], "SELECT * FROM {s}", .{table_name});
    const sql_cstr = createCString(&buf, sql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(state.db, sql_cstr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt);

    const col_count = c.sqlite3_column_count(stmt);
    if (col_count == 0) return;

    // Write table header
    try writer.print("\n-- Table: {s}\n", .{table_name});

    // Get column names
    var col_names = try allocator.alloc([]const u8, @intCast(col_count));
    defer allocator.free(col_names);

    for (0..@intCast(col_count)) |i| {
        const col_name = std.mem.span(c.sqlite3_column_name(stmt, @intCast(i)));
        col_names[i] = try allocator.dupe(u8, col_name);
    }
    defer {
        for (col_names) |name| {
            allocator.free(name);
        }
    }

    // Export rows
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        try writer.print("INSERT INTO {s} (", .{table_name});

        // Column names
        for (col_names, 0..) |name, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("{s}", .{name});
        }

        try writer.print(") VALUES (", .{});

        // Values
        for (0..@intCast(col_count)) |i| {
            if (i > 0) try writer.print(", ", .{});

            const col_type = c.sqlite3_column_type(stmt, @intCast(i));
            switch (col_type) {
                c.SQLITE_NULL => try writer.print("NULL", .{}),
                c.SQLITE_INTEGER => try writer.print("{}", .{c.sqlite3_column_int64(stmt, @intCast(i))}),
                c.SQLITE_FLOAT => try writer.print("{d}", .{c.sqlite3_column_double(stmt, @intCast(i))}),
                c.SQLITE_TEXT => {
                    const text = std.mem.span(c.sqlite3_column_text(stmt, @intCast(i)));
                    // Basic quote escaping
                    if (std.mem.containsAtLeast(u8, text, 1, "'")) {
                        try writer.print("'{s}'", .{text}); // TODO: Proper quote escaping
                    } else {
                        try writer.print("'{s}'", .{text});
                    }
                },
                c.SQLITE_BLOB => try writer.print("X'<blob>'", .{}), // Simplified blob representation
                else => try writer.print("NULL", .{}),
            }
        }

        try writer.print(");\n", .{});
    }
}

// Import SQL file into database
fn importSQLFile(state: *CLIState, filename: []const u8) !void {
    if (state.db == null) {
        print("Error: No database connection.\n", .{});
        return;
    }

    const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        print("Error opening file '{s}': {}\n", .{ filename, err });
        return;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > 10 * 1024 * 1024) { // 10MB limit
        print("Error: File too large (max 10MB)\n", .{});
        return;
    }

    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);

    _ = try file.readAll(content);

    print("Importing SQL from '{s}'...\n", .{filename});

    // Split by semicolons and execute each statement
    var lines = std.mem.splitSequence(u8, content, ";");
    var count: u32 = 0;
    var errors: u32 = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\n\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "--")) continue; // Skip comments

        // Add semicolon back
        var stmt_buf: [4096]u8 = undefined;
        const statement = try std.fmt.bufPrint(stmt_buf[0..], "{s};", .{trimmed});

        executeSQL(state, statement) catch {
            errors += 1;
            print("Error executing: {s}\n", .{trimmed[0..@min(trimmed.len, 50)]});
        };
        count += 1;
    }

    print("Import complete: {d} statements processed, {d} errors\n", .{ count, errors });
}

// Configuration management
const Config = struct {
    syntax_highlighting: bool = true,
    show_query_time: bool = true,
    result_format: ResultFormat = .table,
    prompt: []const u8 = "zsl> ",
    continuation_prompt: []const u8 = "...> ",
    max_history: usize = 1000,

    const CONFIG_FILE = ".zslrc";

    fn load() Config {
        var config = Config{};

        const file = std.fs.cwd().openFile(CONFIG_FILE, .{}) catch {
            // Create default config file if it doesn't exist
            config.save() catch {};
            return config;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024) catch return config;
        defer allocator.free(content);

        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                if (std.mem.eql(u8, key, "syntax_highlighting")) {
                    config.syntax_highlighting = std.mem.eql(u8, value, "true");
                } else if (std.mem.eql(u8, key, "show_query_time")) {
                    config.show_query_time = std.mem.eql(u8, value, "true");
                } else if (std.mem.eql(u8, key, "result_format")) {
                    if (std.mem.eql(u8, value, "csv")) config.result_format = .csv else if (std.mem.eql(u8, value, "json")) config.result_format = .json else if (std.mem.eql(u8, value, "vertical")) config.result_format = .vertical else config.result_format = .table;
                } else if (std.mem.eql(u8, key, "prompt")) {
                    config.prompt = allocator.dupe(u8, value) catch "zsl> ";
                }
            }
        }

        return config;
    }

    fn save(self: *const Config) !void {
        const file = std.fs.cwd().createFile(CONFIG_FILE, .{}) catch return;
        defer file.close();

        const writer = file.writer();
        try writer.print("# ZSQLite CLI Configuration\n", .{});
        try writer.print("# Boolean values: true/false\n", .{});
        try writer.print("# Result formats: table, csv, json, vertical\n\n", .{});
        try writer.print("syntax_highlighting={s}\n", .{if (self.syntax_highlighting) "true" else "false"});
        try writer.print("show_query_time={s}\n", .{if (self.show_query_time) "true" else "false"});
        try writer.print("result_format={s}\n", .{@tagName(self.result_format)});
        try writer.print("prompt={s}\n", .{self.prompt});
    }
};

// SQL Syntax highlighting
const SQLKeyword = struct {
    pub fn isKeyword(word: []const u8) bool {
        const keywords = [_][]const u8{ "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "BEGIN", "COMMIT", "ROLLBACK", "FROM", "WHERE", "GROUP", "ORDER", "BY", "HAVING", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "IS", "NULL", "AS", "DISTINCT", "LIMIT", "OFFSET", "TABLE", "VIEW", "INDEX", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT", "UNIQUE", "INTEGER", "TEXT", "REAL", "BLOB", "VARCHAR", "CHAR", "BOOLEAN", "DATE", "DATETIME", "TIME", "IF", "EXISTS", "CASCADE", "RESTRICT" };

        const upper_word = std.ascii.allocUpperString(allocator, word) catch return false;
        defer allocator.free(upper_word);

        for (keywords) |keyword| {
            if (std.mem.eql(u8, upper_word, keyword)) {
                return true;
            }
        }
        return false;
    }
};

// ANSI color codes for syntax highlighting
const Colors = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
    const white = "\x1b[37m";
    const gray = "\x1b[90m";
};

// Highlight SQL syntax with colors
fn highlightSQL(allocator_param: std.mem.Allocator, sql: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator_param);
    defer result.deinit();

    var i: usize = 0;
    while (i < sql.len) {
        if (std.ascii.isAlphabetic(sql[i])) {
            // Find word boundary
            const start = i;
            while (i < sql.len and (std.ascii.isAlphanumeric(sql[i]) or sql[i] == '_')) {
                i += 1;
            }
            const word = sql[start..i];

            // Check if it's a keyword
            if (SQLKeyword.isKeyword(word)) {
                try result.appendSlice(Colors.blue);
                try result.appendSlice(Colors.bold);
                try result.appendSlice(word);
                try result.appendSlice(Colors.reset);
            } else {
                try result.appendSlice(word);
            }
        } else if (sql[i] == '\'' or sql[i] == '"') {
            // String literal
            const quote = sql[i];
            try result.append(sql[i]);
            i += 1;

            try result.appendSlice(Colors.green);
            while (i < sql.len and sql[i] != quote) {
                if (sql[i] == '\\' and i + 1 < sql.len) {
                    try result.append(sql[i]);
                    i += 1;
                    if (i < sql.len) {
                        try result.append(sql[i]);
                        i += 1;
                    }
                } else {
                    try result.append(sql[i]);
                    i += 1;
                }
            }
            try result.appendSlice(Colors.reset);

            if (i < sql.len) {
                try result.append(sql[i]);
                i += 1;
            }
        } else if (std.ascii.isDigit(sql[i])) {
            // Numeric literal
            try result.appendSlice(Colors.yellow);
            while (i < sql.len and (std.ascii.isDigit(sql[i]) or sql[i] == '.')) {
                try result.append(sql[i]);
                i += 1;
            }
            try result.appendSlice(Colors.reset);
        } else if (sql[i] == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            // Comment
            try result.appendSlice(Colors.gray);
            while (i < sql.len and sql[i] != '\n') {
                try result.append(sql[i]);
                i += 1;
            }
            try result.appendSlice(Colors.reset);
        } else {
            try result.append(sql[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

// Command history storage
var command_history: std.ArrayList([]const u8) = undefined;
var history_index: usize = 0;
var history_initialized = false;

// Terminal state management
var original_termios: c.termios = undefined;
var raw_mode_enabled = false;

fn enableRawMode() !void {
    if (raw_mode_enabled) return;

    // Get current terminal attributes
    if (c.tcgetattr(c.STDIN_FILENO, &original_termios) != 0) {
        return error.TermiosError;
    }

    // Configure raw mode
    var raw = original_termios;
    raw.c_lflag &= ~(@as(c_uint, c.ECHO | c.ICANON | c.ISIG | c.IEXTEN));
    raw.c_iflag &= ~(@as(c_uint, c.IXON | c.ICRNL));
    raw.c_oflag &= ~@as(c_uint, c.OPOST);
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;

    // Apply raw mode
    if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw) != 0) {
        return error.TermiosError;
    }

    raw_mode_enabled = true;
}

fn disableRawMode() void {
    if (!raw_mode_enabled) return;

    // Restore original terminal attributes
    _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &original_termios);
    raw_mode_enabled = false;
}

// Initialize command history
fn initHistory(allocator_param: std.mem.Allocator) void {
    if (!history_initialized) {
        command_history = std.ArrayList([]const u8).init(allocator_param);
        history_initialized = true;
    }
}

// Add command to history
fn addToHistory(allocator_param: std.mem.Allocator, command: []const u8) !void {
    if (command.len == 0) return;

    // Don't add duplicate consecutive commands
    if (command_history.items.len > 0) {
        if (std.mem.eql(u8, command_history.items[command_history.items.len - 1], command)) {
            return;
        }
    }

    const cmd_copy = try allocator_param.dupe(u8, command);
    try command_history.append(cmd_copy);

    // Limit history to 100 commands
    if (command_history.items.len > 100) {
        allocator_param.free(command_history.orderedRemove(0));
    }

    history_index = command_history.items.len;
}

// Read input from stdin with advanced history support
fn readInput(allocator_param: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    // Enable raw mode for proper escape sequence handling
    enableRawMode() catch {
        // Fall back to simple input if raw mode fails
        return readInputSimple(allocator_param, prompt);
    };
    defer disableRawMode();

    print("{s}", .{prompt});

    const stdin = std.io.getStdIn().reader();
    var input_buffer: [4096]u8 = undefined;
    var pos: usize = 0;
    var current_history_index = history_index;

    while (true) {
        const byte = stdin.readByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        switch (byte) {
            '\n', '\r' => {
                print("\r\n", .{});
                const trimmed = std.mem.trim(u8, input_buffer[0..pos], " \t\r\n");
                if (trimmed.len == 0) return try allocator_param.dupe(u8, "");

                const result = try allocator_param.dupe(u8, trimmed);
                try addToHistory(allocator_param, result);
                return result;
            },
            '\x7f', '\x08' => { // Backspace/Delete
                if (pos > 0) {
                    pos -= 1;
                    print("\x08 \x08", .{}); // Move back, space, move back
                }
            },
            '\x1b' => { // Escape sequence start
                const next1 = stdin.readByte() catch continue;
                if (next1 == '[') {
                    const next2 = stdin.readByte() catch continue;
                    switch (next2) {
                        'A' => { // Up arrow
                            if (command_history.items.len > 0 and current_history_index > 0) {
                                current_history_index -= 1;
                                // Clear current line
                                print("\r{s}", .{prompt});
                                for (0..pos) |_| print(" ", .{});
                                print("\r{s}", .{prompt});

                                // Show history command
                                const hist_cmd = command_history.items[current_history_index];
                                print("{s}", .{hist_cmd});
                                @memcpy(input_buffer[0..hist_cmd.len], hist_cmd);
                                pos = hist_cmd.len;
                            }
                        },
                        'B' => { // Down arrow
                            if (command_history.items.len > 0) {
                                if (current_history_index < command_history.items.len - 1) {
                                    current_history_index += 1;
                                    // Clear current line
                                    print("\r{s}", .{prompt});
                                    for (0..pos) |_| print(" ", .{});
                                    print("\r{s}", .{prompt});

                                    // Show history command
                                    const hist_cmd = command_history.items[current_history_index];
                                    print("{s}", .{hist_cmd});
                                    @memcpy(input_buffer[0..hist_cmd.len], hist_cmd);
                                    pos = hist_cmd.len;
                                } else if (current_history_index == command_history.items.len - 1) {
                                    // Move beyond history (clear line)
                                    current_history_index = command_history.items.len;
                                    print("\r{s}", .{prompt});
                                    for (0..pos) |_| print(" ", .{});
                                    print("\r{s}", .{prompt});
                                    pos = 0;
                                }
                            }
                        },
                        'C', 'D' => {
                            // Right/Left arrows - ignore for now
                        },
                        else => {
                            // Other escape sequences - ignore
                        },
                    }
                } else {
                    // Not a CSI sequence, ignore
                }
            },
            '\x03' => { // Ctrl+C
                print("\r\n", .{});
                return null;
            },
            else => { // Regular character
                if (pos < input_buffer.len - 1 and byte >= 32 and byte <= 126) {
                    input_buffer[pos] = byte;
                    pos += 1;
                    print("{c}", .{byte});
                }
            },
        }
    }
}

// Fallback simple input reader (no raw mode)
fn readInputSimple(allocator_param: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    print("{s}", .{prompt});

    const stdin = std.io.getStdIn().reader();
    if (try stdin.readUntilDelimiterOrEofAlloc(allocator_param, '\n', 4096)) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) {
            allocator_param.free(line);
            return try allocator_param.dupe(u8, "");
        }

        const result = try allocator_param.dupe(u8, trimmed);
        allocator_param.free(line);
        try addToHistory(allocator_param, result);
        return result;
    }

    return null;
}

// Show help
fn showHelp() void {
    print(
        \\=== ZSQLite CLI Help ===
        \\
        \\Meta Commands:
        \\  \\o <file>        Open database file
        \\  \\c               Close current database
        \\  \\l               List tables and views
        \\  \\d <table>       Describe table structure
        \\  \\s               Show connection status
        \\  \\schema          Show visual schema diagram
        \\  \\export <file>   Export database to SQL file
        \\  \\import <file>   Import SQL file into database
        \\  \\healthcheck     Run comprehensive database health check
        \\  \\createhealthy <file> Create sample database that passes health checks
        \\  \\config          Show current configuration
        \\  \\set <key=value> Set configuration option
        \\  \\format <type>   Set result format (table/csv/json/vertical)
        \\  \\h               Show this help
        \\  \\q               Quit the CLI
        \\
        \\SQL Commands:
        \\  Any valid SQLite SQL statement
        \\  Examples:
        \\    CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
        \\    INSERT INTO users (name) VALUES ('Alice');
        \\    SELECT * FROM users;
        \\    UPDATE users SET name = 'Bob' WHERE id = 1;
        \\    DELETE FROM users WHERE id = 1;
        \\
        \\Transaction Commands:
        \\    BEGIN;
        \\    COMMIT;
        \\    ROLLBACK;
        \\
        \\Export/Import Examples:
        \\    \\export backup.sql     -- Export current database
        \\    \\import data.sql       -- Import SQL statements
        \\
        \\Configuration Examples:
        \\    \\set syntax_highlighting=false
        \\    \\set show_query_time=true
        \\    \\format csv            -- Change output to CSV
        \\    \\format table          -- Change output to table (default)
        \\
        \\Notes:
        \\  - Commands can span multiple lines
        \\  - Use semicolon to end SQL statements
        \\  - Type 'exit' or 'quit' to exit
        \\  - Configuration is saved in .zslrc
        \\========================
        \\
    , .{});
}

// Show current configuration
fn showConfig() void {
    const config = Config.load();
    print("=== ZSQLite CLI Configuration ===\n", .{});
    print("Syntax highlighting: {s}\n", .{if (config.syntax_highlighting) "enabled" else "disabled"});
    print("Show query time: {s}\n", .{if (config.show_query_time) "enabled" else "disabled"});
    print("Result format: {s}\n", .{@tagName(config.result_format)});
    print("Prompt: {s}\n", .{config.prompt});
    print("Max history: {d}\n", .{config.max_history});
    print("Config file: {s}\n", .{Config.CONFIG_FILE});
    print("===============================\n", .{});
}

// Set configuration option
fn setConfig(setting: []const u8) !void {
    if (std.mem.indexOf(u8, setting, "=")) |eq_pos| {
        const key = std.mem.trim(u8, setting[0..eq_pos], " \t");
        const value = std.mem.trim(u8, setting[eq_pos + 1 ..], " \t");

        var config = Config.load();

        if (std.mem.eql(u8, key, "syntax_highlighting")) {
            config.syntax_highlighting = std.mem.eql(u8, value, "true");
            print("Syntax highlighting: {s}\n", .{if (config.syntax_highlighting) "enabled" else "disabled"});
        } else if (std.mem.eql(u8, key, "show_query_time")) {
            config.show_query_time = std.mem.eql(u8, value, "true");
            print("Show query time: {s}\n", .{if (config.show_query_time) "enabled" else "disabled"});
        } else if (std.mem.eql(u8, key, "prompt")) {
            // Free old prompt if it was allocated
            config.prompt = try allocator.dupe(u8, value);
            print("Prompt set to: {s}\n", .{config.prompt});
        } else {
            print("Unknown configuration key: {s}\n", .{key});
            print("Available keys: syntax_highlighting, show_query_time, prompt\n", .{});
            return;
        }

        try config.save();
        print("Configuration saved to {s}\n", .{Config.CONFIG_FILE});
    } else {
        print("Invalid setting format. Use: \\set key=value\n", .{});
        print("Example: \\set syntax_highlighting=true\n", .{});
    }
}

// Set result format
fn setResultFormat(state: *CLIState, format: []const u8) !void {
    if (std.mem.eql(u8, format, "table")) {
        state.result_format = .table;
    } else if (std.mem.eql(u8, format, "csv")) {
        state.result_format = .csv;
    } else if (std.mem.eql(u8, format, "json")) {
        state.result_format = .json;
    } else if (std.mem.eql(u8, format, "vertical")) {
        state.result_format = .vertical;
    } else {
        print("Invalid format: {s}\n", .{format});
        print("Available formats: table, csv, json, vertical\n", .{});
        return;
    }

    print("Result format set to: {s}\n", .{format});

    // Save to config
    var config = Config.load();
    config.result_format = state.result_format;
    try config.save();
}

// Use/switch database (multiple database support)
fn useDatabase(state: *CLIState, db_name: []const u8) !void {
    if (state.databases.get(db_name)) |db| {
        state.db = db;
        state.current_db_name = db_name;
        print("Switched to database: {s}\n", .{db_name});
    } else {
        print("Database '{s}' not found. Use \\o <file> to open a database first.\n", .{db_name});
        print("Available databases:\n", .{});
        var iterator = state.databases.iterator();
        var count: u32 = 0;
        while (iterator.next()) |entry| {
            print("  - {s}\n", .{entry.key_ptr.*});
            count += 1;
        }
        if (count == 0) {
            print("  (none)\n", .{});
        }
    }
}

// Run database health check command
fn runHealthCheckCommand(state: *CLIState) !void {
    if (state.db == null) {
        print("No database connection. Use \\o <filename> to open a database first.\n", .{});
        return;
    }

    const db_path = if (state.current_file) |file| file else ":memory:";
    print("Running health check on: {s}\n\n", .{db_path});

    var result = test_module.performDatabaseHealthCheck(db_path, allocator) catch |err| {
        print("❌ Health check failed: {}\n", .{err});
        return;
    };
    defer result.deinit();

    // The health check function already prints detailed results
    // Just add a summary here for CLI users
    print("Health check completed. Database status: ", .{});
    switch (result.overall_status) {
        .healthy => print("🟢 HEALTHY\n", .{}),
        .warning => print("🟡 WARNING - Check warnings above\n", .{}),
        .critical => print("🔴 CRITICAL - Check errors above\n", .{}),
    }
}

// Create sample healthy database command
fn createHealthyDatabaseCommand(db_path: []const u8) !void {
    print("Creating sample healthy database: {s}\n\n", .{db_path});

    test_module.createSampleHealthyDatabase(db_path, allocator) catch |err| {
        print("❌ Failed to create healthy database: {}\n", .{err});
        return;
    };

    print("\n✅ Sample healthy database created successfully!\n", .{});
    print("You can now:\n", .{});
    print("  1. Open it with: \\o {s}\n", .{db_path});
    print("  2. Run health check: \\healthcheck\n", .{});
    print("  3. Explore the schema: \\d\n", .{});
    print("  4. Query the data: SELECT * FROM users;\n", .{});
}

// Main CLI loop
pub fn runCLI() !void {
    var state = CLIState.init();
    defer {
        state.deinit();
        disableRawMode(); // Ensure terminal is restored
    }

    // Initialize command history
    initHistory(allocator);

    print("ZSQLite CLI v0.9.2 - Direct SQLite3 bindings for Zig\n", .{});
    print("Type \\h for help, \\q to quit.\n\n", .{});

    // Try to open default database (in-memory)
    try openDatabase(&state, ":memory:");

    // Load configuration
    const config = Config.load();
    state.syntax_highlighting = config.syntax_highlighting;
    state.show_query_time = config.show_query_time;
    state.result_format = config.result_format;

    while (true) {
        const current_prompt = if (state.in_transaction) "zsl(tx)> " else config.prompt;

        if (try readInput(allocator, current_prompt)) |input| {
            defer allocator.free(input);

            if (input.len == 0) continue;

            const command = parseCommand(input);

            switch (command.type) {
                .exit => {
                    print("Goodbye!\n", .{});
                    break;
                },
                .help => {
                    showHelp();
                },
                .sql => {
                    // Translate MySQL command to SQLite if necessary
                    const translated_sql = translateMySQLCommand(allocator, command.content) catch |err| {
                        print("Error translating MySQL command: {}\n", .{err});
                        return;
                    };
                    defer allocator.free(translated_sql);

                    executeSQL(&state, translated_sql) catch |err| {
                        print("Error executing SQL: {}\n", .{err});
                    };
                },
                .meta => {
                    executeMetaCommand(&state, command.content) catch |err| {
                        print("Error executing meta command: {}\n", .{err});
                    };
                },
                .invalid => {
                    print("Invalid command. Type \\h for help.\n", .{});
                },
            }
        } else {
            // EOF encountered (Ctrl+D)
            print("\nGoodbye!\n", .{});
            break;
        }
    }
}

// Entry point for CLI mode
pub fn main() !void {
    try runCLI();
}
