-- Test SQL commands for ZSQLite CLI
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE,
    age INTEGER
);

INSERT INTO users (name, email, age) VALUES ('Alice', 'alice@example.com', 30);
INSERT INTO users (name, email, age) VALUES ('Bob', 'bob@example.com', 25);
INSERT INTO users (name, email, age) VALUES ('Charlie', 'charlie@example.com', 35);

-- Test basic SELECT
SELECT * FROM users;

-- Test MySQL-like commands
SHOW TABLES;
DESC users;

-- Test WHERE clause
SELECT name, age FROM users WHERE age > 28;

-- Test transaction
BEGIN;
INSERT INTO users (name, email, age) VALUES ('Diana', 'diana@example.com', 28);
COMMIT;

-- Verify transaction
SELECT COUNT(*) as total_users FROM users;

-- Test meta commands
\l
\d users
\s

-- Exit
\q
