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
        print("Error: No database connection. Use \\o <filename> to open a database.\n");
        return;
    }

    var buf: [4096]u8 = undefined;
    const sql_cstr = createCString(&buf, sql);

    var errmsg: [*c]u8 = null;
    const rc = c.sqlite3_exec(state.db, sql_cstr, sqliteCallback, null, &errmsg);

    if (rc != c.SQLITE_OK) {
        defer if (errmsg != null) c.sqlite3_free(errmsg);
        if (errmsg != null) {
            print("SQL Error: %s\n", errmsg);
        } else {
            print("SQL Error: %s\n", c.sqlite3_errmsg(state.db));
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
            if (i > 0) print(" | ");
            print("{s}", .{azColName[i]});
        }
        print("\n");

        // Print separator
        for (0..@intCast(argc)) |i| {
            if (i > 0) print("-+-");
            const col_name = std.mem.span(azColName[i]);
            for (0..col_name.len) |_| {
                print("-");
            }
        }
        print("\n");
        callback_first_row = false;
    }

    // Print row data
    for (0..@intCast(argc)) |i| {
        if (i > 0) print(" | ");
        if (argv[i] != null) {
            print("{s}", .{argv[i]});
        } else {
            print("NULL");
        }
    }
    print("\n");

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
    } else {
        print("Unknown meta command: {s}\n", .{command});
        print("Use \\h for help.\n");
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
        print("Error opening database '{s}': {s}\n", .{ filename, c.sqlite3_errmsg(state.db) });
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
        print("Database connection closed.\n");
    } else {
        print("No database connection to close.\n");
    }
}

// List all tables in the database
fn listTables(state: *CLIState) !void {
    if (state.db == null) {
        print("Error: No database connection.\n");
        return;
    }

    const sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name";
    try executeSQL(state, sql);
}

// Describe table structure
fn describeTable(state: *CLIState, table_name: []const u8) !void {
    if (state.db == null) {
        print("Error: No database connection.\n");
        return;
    }

    const sql = try std.fmt.allocPrint(allocator, "PRAGMA table_info({s})", .{table_name});
    defer allocator.free(sql);
    try executeSQL(state, sql);
}

// Show current status
fn showStatus(state: *CLIState) void {
    print("=== ZSQLite CLI Status ===\n");
    if (state.current_file) |file| {
        print("Database: {s}\n", .{file});
        print("Connection: Open\n");
        print("Transaction: {s}\n", .{if (state.in_transaction) "Active" else "None"});
    } else {
        print("Database: None\n");
        print("Connection: Closed\n");
    }
    print("========================\n");
}

// Show help
fn showHelp() void {
    print(
        \\=== ZSQLite CLI Help ===
        \\
        \\Meta Commands:
        \\  \\o <file>     Open database file
        \\  \\c            Close current database
        \\  \\l            List tables and views
        \\  \\d <table>    Describe table structure
        \\  \\s            Show connection status
        \\  \\h            Show this help
        \\  \\q            Quit the CLI
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
        \\Notes:
        \\  - Commands can span multiple lines
        \\  - Use semicolon to end SQL statements
        \\  - Type 'exit' or 'quit' to exit
        \\========================
        \\
    );
}

// Read input from stdin
fn readInput(allocator_param: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    print("{s}", .{prompt});

    const stdin = std.io.getStdIn().reader();

    if (try stdin.readUntilDelimiterOrEofAlloc(allocator_param, '\n', 4096)) |input| {
        return std.mem.trim(u8, input, " \t\r\n");
    } else {
        return null;
    }
}

// Main CLI loop
pub fn runCLI() !void {
    var state = CLIState.init();
    defer state.deinit();

    print("ZSQLite CLI v0.8.0 - Direct SQLite3 bindings for Zig\n");
    print("Type \\h for help, \\q to quit.\n\n");

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
                    print("Goodbye!\n");
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
                    print("Invalid command. Type \\h for help.\n");
                },
            }
        } else {
            // EOF encountered (Ctrl+D)
            print("\nGoodbye!\n");
            break;
        }
    }
}

// Entry point for CLI mode
pub fn main() !void {
    try runCLI();
}
