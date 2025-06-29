//! ZSQLite - Complete SQLite3 wrapper for Zig
//!
//! This library provides direct access to SQLite's C API with zero overhead,
//! plus comprehensive error handling and Zig safety guarantees.
//!
//! Example usage:
//! ```zig
//! const std = @import("std");
//! const zsqlite = @import("zsqlite");
//!
//! pub fn main() !void {
//!     var db: ?*zsqlite.c.sqlite3 = null;
//!     const rc = zsqlite.c.sqlite3_open(":memory:", &db);
//!     defer _ = zsqlite.c.sqlite3_close(db);
//!
//!     // Use all SQLite functions through zsqlite.c.*
//! }
//! ```

const std = @import("std");

// Re-export the C API for library users
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

// Re-export core functionality
pub const sqlite = @import("sqlite.zig");

// Public API - Re-export commonly used functions and types
pub const open = sqlite.open;
pub const close = sqlite.close;
pub const exec = sqlite.exec;
pub const prepare = sqlite.prepare;
pub const step = sqlite.step;
pub const finalize = sqlite.finalize;
pub const bind_text = sqlite.bind_text;
pub const bind_int = sqlite.bind_int;
pub const bind_double = sqlite.bind_double;
pub const column_text = sqlite.column_text;
pub const column_int = sqlite.column_int;
pub const column_double = sqlite.column_double;

// Error types
pub const SQLiteError = error{
    SQLError,
    InvalidDatabase,
    PrepareError,
    BindError,
    StepError,
};

// Version information
pub const version = "0.9.1";
pub const description = "Complete SQLite3 wrapper for Zig with professional CLI";

// Test exports (for internal testing)
pub const testing = struct {
    pub const health_check = @import("test.zig").performDatabaseHealthCheck;
};

test {
    // Include all tests from other modules
    _ = @import("sqlite.zig");
    _ = @import("test.zig");
}
