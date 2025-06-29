const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

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

    fn init() CLIState {
        return CLIState{};
    }

    fn deinit(self: *CLIState) void {
        if (self.db != null) {
            _ = c.sqlite3_close(self.db);
        }
    }
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

// Execute SQL command
fn executeSQL(state: *CLIState, sql: []const u8) !void {
    if (state.db == null) {
        print("Error: No database connection. Use \\o <filename> to open a database.\n", .{});
        return;
    }

    var buf: [4096]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);

    // Reset the callback state for each query
    callback_first_row = true;

    var errmsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(state.db, sql_cstr, sqliteCallback, null, &errmsg);

    if (rc != c.SQLITE_OK) {
        defer if (errmsg != null) c.sqlite3_free(errmsg);
        if (errmsg != null) {
            print("SQL Error: {s}\n", .{std.mem.span(errmsg.?)});
        } else {
            print("SQL Error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(state.db))});
        }
        return;
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

// Show help
fn showHelp() void {
    print("=== ZSQLite CLI Help ===\n", .{});
    print("\n", .{});
    print("Meta Commands:\n", .{});
    print("  \\o <file>        Open database file\n", .{});
    print("  \\c               Close current database\n", .{});
    print("  \\l               List tables and views\n", .{});
    print("  \\d <table>       Describe table structure\n", .{});
    print("  \\s               Show connection status\n", .{});
    print("  \\schema          Show visual schema diagram\n", .{});
    print("  \\export <file>   Export database to SQL file\n", .{});
    print("  \\import <file>   Import SQL file into database\n", .{});
    print("  \\h               Show this help\n", .{});
    print("  \\q               Quit the CLI\n", .{});
    print("\n", .{});
    print("SQL Commands:\n", .{});
    print("  Any valid SQLite SQL statement\n", .{});
    print("  Examples:\n", .{});
    print("    CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);\n", .{});
    print("    INSERT INTO users (name) VALUES ('Alice');\n", .{});
    print("    SELECT * FROM users;\n", .{});
    print("    UPDATE users SET name = 'Bob' WHERE id = 1;\n", .{});
    print("    DELETE FROM users WHERE id = 1;\n", .{});
    print("\n", .{});
    print("Transaction Commands:\n", .{});
    print("    BEGIN;\n", .{});
    print("    COMMIT;\n", .{});
    print("    ROLLBACK;\n", .{});
    print("\n", .{});
    print("Export/Import Examples:\n", .{});
    print("    \\export backup.sql     -- Export current database\n", .{});
    print("    \\import data.sql       -- Import SQL statements\n", .{});
    print("\n", .{});
    print("Notes:\n", .{});
    print("  - Commands can span multiple lines\n", .{});
    print("  - Use semicolon to end SQL statements\n", .{});
    print("  - Type 'exit' or 'quit' to exit\n", .{});
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

// Read input from stdin
fn readInput(allocator_param: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    print("{s}", .{prompt});

    const stdin = std.io.getStdIn().reader();

    if (try stdin.readUntilDelimiterOrEofAlloc(allocator_param, '\n', 4096)) |input| {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        const result = try allocator_param.dupe(u8, trimmed);
        allocator_param.free(input);
        return result;
    } else {
        return null;
    }
}

// Main CLI loop
pub fn runCLI() !void {
    var state = CLIState.init();
    defer state.deinit();

    print("ZSQLite CLI v0.8.0 - Direct SQLite3 bindings for Zig\n", .{});
    print("Type \\h for help, \\q to quit.\n\n", .{});

    // Try to open default database (in-memory)
    try openDatabase(&state, ":memory:");

    while (true) {
        const prompt = if (state.in_transaction) "zsl(tx)> " else "zsl> ";

        if (try readInput(allocator, prompt)) |input| {
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
                    executeSQL(&state, command.content) catch |err| {
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
