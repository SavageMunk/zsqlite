# ZSQLite Architecture Deep-Dive

## Overview

ZSQLite is designed as a minimal, direct wrapper around SQLite's C API for Zig. This document provides an in-depth look at the architecture, design decisions, and implementation details.

## Architecture Principles

### 1. Direct C API Binding
- **Zero abstraction penalty**: Direct function calls to SQLite C API
- **Transparent error handling**: SQLite error codes mapped to Zig errors
- **Memory management**: Leverages both SQLite's and Zig's memory management

### 2. Minimal Wrapper Philosophy
- **Preserve SQLite semantics**: Maintain SQLite's behavior and patterns
- **Zig-native error handling**: Use Zig's error system instead of return codes
- **Resource safety**: Use Zig's `defer` for automatic cleanup

### 3. Educational Focus
- **Clear documentation**: Every function documented with examples
- **Learning-oriented**: Code structure optimized for understanding
- **Best practices**: Demonstrates proper C interop patterns

## Core Components

### 1. Library Layer (`src/main.zig`)

The library implements 47 core SQLite functions across 7 functional categories:

#### Database Connection Management
```zig
// Connection lifecycle
sqlite3_open()       // Basic database opening
sqlite3_open_v2()    // Advanced opening with flags
sqlite3_close()      // Connection cleanup
```

#### Statement Preparation and Execution
```zig
// Prepared statement lifecycle
sqlite3_prepare_v2() // Statement compilation
sqlite3_step()       // Statement execution
sqlite3_finalize()   // Statement cleanup
sqlite3_reset()      // Statement reuse
```

#### Data Binding and Retrieval
```zig
// Parameter binding (input)
sqlite3_bind_text()
sqlite3_bind_int()
sqlite3_bind_double()
sqlite3_bind_blob()
sqlite3_bind_null()

// Result retrieval (output)
sqlite3_column_text()
sqlite3_column_int()
sqlite3_column_double()
sqlite3_column_blob()
sqlite3_column_type()
```

### 2. CLI Layer (`src/cli.zig`)

The CLI provides a user-friendly interface with advanced features:

#### Command Processing Pipeline
```
Input → Parsing → Command Type Detection → Execution → Output Formatting
```

#### Command Types
- **SQL Commands**: Direct SQLite SQL execution
- **Meta Commands**: CLI-specific operations (\\l, \\d, \\s, etc.)
- **Configuration Commands**: Settings management (\\set, \\config)

#### Advanced Features (Phase 9)
- **Syntax Highlighting**: ANSI color codes for SQL keywords
- **Multiple Databases**: Connection switching and management
- **Result Formatting**: Table, CSV, JSON, vertical output formats
- **Configuration Management**: Persistent settings via `.zslrc`

### 3. Build System (`build.zig`)

Multi-target build system supporting:
- **Library target**: For embedding in other projects
- **CLI target**: Standalone command-line tool
- **Demo target**: Usage examples and testing

## Memory Management Strategy

### 1. SQLite Memory
- **Automatic**: SQLite manages its internal memory
- **Cleanup**: Always call `sqlite3_finalize()` and `sqlite3_close()`
- **Error messages**: Use `sqlite3_free()` for `sqlite3_exec()` errors

### 2. Zig Memory
- **Allocator**: Page allocator for CLI state and temporary data
- **RAII**: Use `defer` for automatic cleanup
- **String handling**: Proper allocation/deallocation for C strings

### 3. C Interop Memory
- **Null termination**: Careful handling of C strings
- **Buffer management**: Stack-allocated buffers for C string conversion
- **Lifetime management**: Ensure C pointers remain valid

## Error Handling Architecture

### 1. Error Propagation
```zig
const DatabaseError = error{
    OpenFailed,
    PrepareFailed,
    ExecutionFailed,
    BindingFailed,
    InvalidType,
};
```

### 2. Error Context
- **SQLite errors**: Preserve original error messages
- **Zig errors**: Use descriptive error types
- **User errors**: Friendly error messages in CLI

### 3. Recovery Strategies
- **Graceful degradation**: Continue operation when possible
- **State preservation**: Maintain consistent CLI state
- **User feedback**: Clear error reporting and suggestions

## Performance Considerations

### 1. Direct Binding Benefits
- **No overhead**: Direct C function calls
- **Memory efficiency**: Minimal wrapper allocation
- **Speed**: Native SQLite performance

### 2. CLI Optimizations
- **Prepared statements**: Reuse for repeated operations
- **Buffer reuse**: Stack-allocated buffers where possible
- **Lazy evaluation**: Load configuration only when needed

### 3. Scalability
- **Large results**: Streaming result processing
- **Memory limits**: Bounded allocations for safety
- **Connection pooling**: Multiple database support

## Security Architecture

### 1. Input Validation
- **SQL injection prevention**: Use prepared statements
- **Path validation**: Secure file operations
- **Buffer bounds**: Prevent buffer overflows

### 2. Resource Limits
- **File size limits**: Prevent excessive memory usage
- **Connection limits**: Bounded database connections
- **Query timeouts**: Prevent runaway queries

### 3. Safe Defaults
- **Read-only mode**: Default to safe operations
- **Minimal permissions**: Only required database access
- **Error disclosure**: Limit information leakage

## Extension Points

### 1. Custom Functions
- **Registration**: `sqlite3_create_function()` support
- **Type safety**: Zig wrappers for function arguments
- **Error handling**: Proper error propagation

### 2. Virtual Tables
- **Interface**: Support for custom table implementations
- **Memory management**: Proper cleanup of virtual table data
- **Performance**: Efficient virtual table operations

### 3. Backup and Recovery
- **Incremental backup**: `sqlite3_backup_*()` functions
- **Progress callbacks**: User feedback during operations
- **Error recovery**: Robust backup failure handling

## Testing Strategy

### 1. Unit Testing
- **Function coverage**: Test all 47 implemented functions
- **Error conditions**: Test error paths and edge cases
- **Memory safety**: Verify no leaks or double-frees

### 2. Integration Testing
- **CLI operations**: Test complete user workflows
- **Database operations**: Test real database scenarios
- **Performance testing**: Verify acceptable performance

### 3. Compatibility Testing
- **SQLite versions**: Test with different SQLite versions
- **Platform support**: Linux, macOS, Windows compatibility
- **Zig versions**: Support for recent Zig releases

## Future Architecture Considerations

### 1. Thread Safety
- **Connection-per-thread**: Isolate database connections
- **Shared resources**: Careful synchronization where needed
- **WAL mode**: Support for Write-Ahead Logging

### 2. Async Support
- **Non-blocking operations**: Async I/O for large operations
- **Progress callbacks**: User feedback for long operations
- **Cancellation**: Ability to interrupt operations

### 3. Plugin Architecture
- **Extension loading**: Dynamic plugin support
- **Hook system**: Extensible event handling
- **Custom formatters**: Pluggable output formats

## Lessons Learned

### 1. Critical Discovery: linkLibC() Requirement
The most important architectural finding is that `exe.linkLibC()` is required for SQLite to work properly with Zig. Without it:
- Programs compile and link successfully
- Runtime crashes with segmentation fault
- Error is not obvious from compiler output

### 2. C String Handling
Proper C string handling is crucial:
- Always null-terminate strings for C functions
- Use stack buffers for temporary conversions
- Be careful with string lifetime management

### 3. Error Message Handling
SQLite error messages can be used directly:
- No need for `std.mem.span()` conversion
- Use `{s}` format specifier directly
- Proper cleanup with `sqlite3_free()` when needed

## Design Trade-offs

### 1. Simplicity vs. Features
- **Chosen**: Direct bindings with minimal abstraction
- **Alternative**: High-level ORM-style interface
- **Rationale**: Educational value and performance

### 2. Memory Management
- **Chosen**: Mix of SQLite and Zig memory management
- **Alternative**: Unified memory management
- **Rationale**: Respect SQLite's internal memory handling

### 3. Error Handling
- **Chosen**: Zig errors with SQLite context
- **Alternative**: Direct SQLite error codes
- **Rationale**: Zig-native error handling while preserving context

This architecture provides a solid foundation for SQLite usage in Zig while maintaining the educational and performance goals of the project.
