# EPG Migrator

[![Erlang/OTP](https://img.shields.io/badge/Erlang%2FOTP-24%2B-blue)](https://www.erlang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A lightweight, flexible PostgreSQL database migration library for Erlang/OTP applications, powered by [epgsql](https://github.com/epgsql/epgsql).

## Features

- **Multiple Migration Types**: Support for SQL, DTL templates, and Erlang code migrations
- **Transactional**: Each migration runs in its own transaction with automatic rollback on failure
- **Multi-Realm Support**: Manage migrations for different environments/tenants independently
- **Idempotent**: Safe to run multiple times - only executes pending migrations
- **Parameterized**: Pass runtime parameters to DTL and Erlang migrations

## Installation

Add `epg_migrator` to your `rebar.config`:

```erlang
{deps, [
    {epg_migrator, {git, "https://github.com/ttt161/epg_migrator.git", {branch, "main"}}}
]}.
```

## Quick Start

### 1. Create Migration Directory

```bash
mkdir -p priv/migrations
```

### 2. Create Your First Migration

Create `priv/migrations/001_create_users.sql`:

```sql
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_username ON users(username);
```

### 3. Run Migrations

```erlang
%% Database connection parameters
DbOpts = #{
    host => "localhost",
    port => 5432,
    database => "myapp",
    username => "postgres",
    password => "postgres"
},

%% Migration parameters (optional)
MigrationOpts = [],

%% Realm identifies the migration scope
Realm = "production",

%% Migrations directory
MigrationsDir = "priv/migrations",

%% Execute migrations
{ok, Executed} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir).
%% Returns: {ok, [<<"001_create_users.sql">>]}
```

## Migration Types

### SQL Migrations (`.sql`)

Pure SQL files executed directly via `epgsql:squery/2`.

**Example**: `001_create_posts.sql`

```sql
CREATE TABLE posts (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    title VARCHAR(500) NOT NULL,
    content TEXT,
    published BOOLEAN DEFAULT false,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);
```

### DTL Template Migrations (`.sql.dtl`)

SQL templates using [ErlyDTL](https://github.com/erlydtl/erlydtl) for parameterization.

**Example**: `002_create_tenant_tables.sql.dtl`

```sql
-- Create tenant-specific tables using realm parameter
CREATE TABLE {{ realm }}_orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    total_amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_{{ realm }}_orders_user_id ON {{ realm }}_orders(user_id);
```

**Usage**:

```erlang
MigrationOpts = [{realm, "tenant_a"}],
epg_migrator:perform("tenant_a", DbOpts, MigrationOpts, MigrationsDir).
%% Creates: tenant_a_orders table
```

### Erlang Migrations (`.erl`)

Erlang modules with `perform/2` function for complex migration logic.

**Example**: `003_migrate_data.erl`

```erlang
-module('003_migrate_data').
-export([perform/2]).

%% @doc Perform migration with full Erlang capabilities
perform(Conn, MigrationOpts) ->
    %% Get parameters
    TablePrefix = proplists:get_value(table_prefix, MigrationOpts, ""),

    %% Read existing data
    {ok, _Cols, Users} = epgsql:equery(Conn, "SELECT id, email FROM users", []),

    %% Transform and insert
    lists:foreach(fun({UserId, Email}) ->
        Domain = extract_domain(Email),
        SQL = io_lib:format(
            "INSERT INTO ~s_user_domains (user_id, domain) VALUES ($1, $2)",
            [TablePrefix]
        ),
        {ok, 1} = epgsql:equery(Conn, SQL, [UserId, Domain])
    end, Users),

    ok.

extract_domain(Email) when is_binary(Email) ->
    [_, Domain] = binary:split(Email, <<"@">>),
    Domain.
```

**Usage**:

```erlang
MigrationOpts = [{table_prefix, "app"}],
epg_migrator:perform("production", DbOpts, MigrationOpts, MigrationsDir).
```

## API Reference

### `perform/4`

Main function to execute database migrations.

```erlang
-spec perform(
    Realm :: string() | binary(),
    DbOpts :: #{
        host := string(),
        port := integer(),
        database := string(),
        username := string(),
        password := string()
    },
    MigrationOpts :: proplists:proplist(),
    MigrationsDir :: file:filename()
) -> {ok, [binary()]} | {error, term()}.
```

**Parameters**:
- `Realm` - Migration scope identifier (e.g., "production", "tenant_a")
- `DbOpts` - Database connection parameters
- `MigrationOpts` - Parameters passed to DTL and Erlang migrations
- `MigrationsDir` - Directory containing migration files

**Returns**:
- `{ok, ExecutedMigrations}` - List of executed migration filenames
- `{error, Reason}` - Error details

## Use Cases

### Multi-Tenant Applications

Use the same migrations for different tenants with parameterized table names:

```erlang
%% Tenant A
epg_migrator:perform("tenant_a", DbOpts, [{prefix, "tenant_a"}], MigrationsDir),
%% Creates: tenant_a_orders, tenant_a_payments, etc.

%% Tenant B
epg_migrator:perform("tenant_b", DbOpts, [{prefix, "tenant_b"}], MigrationsDir),
%% Creates: tenant_b_orders, tenant_b_payments, etc.
```

### Environment-Specific Migrations

Different realms for different environments:

```erlang
%% Development
epg_migrator:perform("development", DevDbOpts, [], MigrationsDir),

%% Staging
epg_migrator:perform("staging", StagingDbOpts, [], MigrationsDir),

%% Production
epg_migrator:perform("production", ProdDbOpts, [], MigrationsDir),
```

### Mixed Migration Types

Combine SQL, DTL, and Erlang migrations in one directory:

## Migration Execution Order

Migrations are executed in **lexicographical order** by filename:

```
001_first.sql
002_second.sql.dtl
003_third.erl
010_fourth.sql
100_fifth.sql
```

**Best Practice**: Use numeric prefixes with leading zeros (e.g., `001_`, `002_`) to ensure correct ordering.

## Migration Tracking

Executed migrations are stored in the `schema_migrations` table:

```sql
CREATE TABLE schema_migrations (
    realm VARCHAR(255) NOT NULL,
    migration_file_name VARCHAR(255) NOT NULL,
    executed_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (realm, migration_file_name)
);
```

This allows:
- Independent tracking per realm
- Idempotent execution (safe re-runs)
- Audit trail of migration history

## Error Handling

Each migration runs in a transaction with automatic rollback on failure:

```erlang
case epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir) of
    {ok, Executed} ->
        io:format("Successfully executed ~p migrations~n", [length(Executed)]);
    {error, {migration_execution_failed, FileName, Reason}} ->
        io:format("Migration ~s failed: ~p~n", [FileName, Reason]);
    {error, Reason} ->
        io:format("Migration process failed: ~p~n", [Reason])
end.
```

**Behavior**:
- ✅ Failed migration is rolled back
- ✅ Previously successful migrations remain committed
- ✅ Migration tracking reflects only successful migrations
- ✅ Process stops at first failure

## Testing

Run the test suite:

```bash
make wdeps-test
```

This will:
1. Start a PostgreSQL instance via Docker Compose
2. Run 39 comprehensive tests
3. Clean up resources

## Development

### Prerequisites

- Erlang/OTP 24+
- Docker & Docker Compose (for tests)
- rebar3

### Build

```bash
rebar3 compile
```

### Format Code

```bash
rebar3 fmt -w
```

### Run Tests Locally

```bash
# With PostgreSQL
make wdeps-test

# Code analysis
rebar3 xref
rebar3 dialyzer
```

## Advanced Examples

### Conditional Migration

```erlang
-module('010_add_column_if_missing').
-export([perform/2]).

perform(Conn, _Opts) ->
    %% Check if column exists
    {ok, _, Rows} = epgsql:equery(Conn,
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_name = 'users' AND column_name = 'status'",
        []
    ),

    case Rows of
        [] ->
            %% Column doesn't exist, add it
            {ok, [], []} = epgsql:squery(Conn,
                "ALTER TABLE users ADD COLUMN status VARCHAR(50) DEFAULT 'active'"
            ),
            ok;
        _ ->
            %% Column exists, skip
            ok
    end.
```

### Batch Processing

```erlang
-module('011_batch_update').
-export([perform/2]).

perform(Conn, Opts) ->
    BatchSize = proplists:get_value(batch_size, Opts, 1000),
    process_batches(Conn, 0, BatchSize).

process_batches(Conn, Offset, BatchSize) ->
    SQL = io_lib:format(
        "SELECT id, data FROM large_table ORDER BY id LIMIT ~p OFFSET ~p",
        [BatchSize, Offset]
    ),

    case epgsql:equery(Conn, SQL, []) of
        {ok, _, []} ->
            %% No more rows
            ok;
        {ok, _, Rows} ->
            %% Process batch
            lists:foreach(fun({Id, Data}) ->
                NewData = transform(Data),
                {ok, 1} = epgsql:equery(Conn,
                    "UPDATE large_table SET data = $1 WHERE id = $2",
                    [NewData, Id]
                )
            end, Rows),
            %% Next batch
            process_batches(Conn, Offset + BatchSize, BatchSize)
    end.

transform(Data) ->
    %% Your transformation logic
    Data.
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass (`make wdeps-test`)
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Credits

Built with:
- [epgsql](https://github.com/epgsql/epgsql) - PostgreSQL driver
- [erlydtl](https://github.com/erlydtl/erlydtl) - Django Template Language for Erlang
