# ZSQLite Examples

This directory contains examples demonstrating how to use ZSQLite CLI and library.

## CLI Examples

### Running the CLI
```bash
# Build and run the CLI
zig build cli

# Or run directly
./zig-out/bin/zsl
```

### Example Session
```bash
# The CLI starts with an in-memory database
zsl> CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);
Query OK (0.05 ms)

zsl> INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');
Query OK, 1 rows affected (0.12 ms)

zsl> SELECT * FROM users;
id | name  | email
---+-------+------------------
1  | Alice | alice@example.com

1 rows returned (0.08 ms)

zsl> SHOW TABLES;
name
-----
users

1 rows returned (0.03 ms)

zsl> DESC users;
cid | name  | type             | notnull | dflt_value | pk
----+-------+------------------+---------+------------+----
0   | id    | INTEGER          | 0       | NULL       | 1
1   | name  | TEXT             | 0       | NULL       | 0
2   | email | TEXT             | 0       | NULL       | 0

3 rows returned (0.02 ms)

zsl> \q
Goodbye!
```

## Files

- `test_cli.sql` - Comprehensive CLI test script
- More examples coming in Phase 9...

## Meta Commands

- `\o <file>` - Open database file
- `\c` - Close current database  
- `\l` - List tables and views
- `\d <table>` - Describe table structure
- `\s` - Show connection status
- `\h` - Show help
- `\q` - Quit the CLI

## MySQL-like Commands

- `SHOW TABLES` - List all tables
- `SHOW DATABASES` - List attached databases  
- `DESC table_name` - Describe table structure
- `DESCRIBE table_name` - Describe table structure
