# pgsql-gos

[![CI](https://github.com/danpozmanter/pgsql-gos/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/danpozmanter/pgsql-gos/actions/workflows/ci.yml)

A PostgreSQL driver written entirely in Gossamer.

The driver speaks the PostgreSQL frontend/backend protocol (version 3.0)
directly over a TCP or Unix socket. There is no libpq, no Rust binding, and
nothing outside the Gossamer standard library: the wire framing, SASL
authentication, the extended query protocol, COPY, LISTEN/NOTIFY, and the
type codec are all Gossamer source in `src/`.

```gossamer
use std::errors
use "github.com/danpozmanter/pgsql-gos" as pgsql

fn main() -> Result<(), errors::Error> {
    let mut db = pgsql::connect(&"host=/var/run/postgresql dbname=app")?
    defer db.close()

    let _ = db.execute(
        &"INSERT INTO people (name, age) VALUES ($1, $2)",
        &#[pgsql::text("Ada"), pgsql::int(36)],
    )?

    for row in db.query(&"SELECT name, age FROM people ORDER BY name", &#[])? {
        println!("{} is {}", row.text_of("name")?, row.i64_of("age")?)
    }
    Ok(())
}
```

## Installing

```toml
# project.toml
[dependencies]
"github.com/danpozmanter/pgsql-gos" = { git = "https://github.com/danpozmanter/pgsql-gos" tag="v0.1.0" }
```

The whole surface is reached through the imported module; the driver's
submodules (`value`, `conn`, `client`, `config`, `oid`, `pool`) are reachable
under it when you need a type by name (`pgsql::value::Value`,
`pgsql::conn::Row`).

## Connecting

Both spellings libpq accepts work, and anything a parameter does not name
falls back to the standard `PG*` environment variable and then to libpq's own
default:

```gossamer
pgsql::connect(&"host=localhost port=5432 user=me password=secret dbname=app")?
pgsql::connect(&"postgres://me:secret@localhost/app?sslmode=require")?
pgsql::connect(&"host=/var/run/postgresql dbname=app")?           // Unix socket
pgsql::connect(&"host=a.example.com,b.example.com dbname=app \
                target_session_attrs=read-write")?               // failover
```

Recognized parameters: `host`, `port`, `user`, `password`, `dbname`,
`sslmode`, `sslrootcert`, `channel_binding`, `application_name`,
`target_session_attrs`, `connect_timeout`, `statement_timeout`, `options`.
Anything else is sent as a session setting in the startup message, so
`search_path=app,public` reaches the server as one.

`pgsql::parse_config` answers the parsed parameters when you want to adjust
them before connecting.

### TLS

`sslmode` behaves as libpq documents it: `disable`, `prefer` (the default),
`require`, `verify-ca`, and `verify-full`. `require` encrypts without
vouching for the certificate; `verify-ca` and `verify-full` check the chain,
and `sslrootcert` supplies a PEM root when the system store is not the right
one. A Unix-socket connection is local and is not upgraded.

### Authentication

Trust, cleartext password, MD5, and SCRAM-SHA-256 all work. The SCRAM
exchange verifies the server's signature before the session is treated as
authenticated, so a server that cannot prove it holds the stored verifier is
rejected.

SCRAM channel binding (`SCRAM-SHA-256-PLUS`) needs the TLS server
certificate to hash, which `std::net` does not expose, so the driver never
claims support for it. `channel_binding=require` reports that plainly rather
than authenticating without the protection you asked for. GSSAPI and SSPI are
reported as unsupported.

## Values

A parameter is a `value::Value`, built with the constructors on the package:

```gossamer
pgsql::null()            pgsql::boolean(true)     pgsql::int(42)
pgsql::float(1.5)        pgsql::numeric("12.50")  pgsql::text("Ada")
pgsql::bytes(#[0, 255])  pgsql::int_array(#[1,2])  pgsql::text_array(#["a","b"])
pgsql::array(items)      pgsql::record(fields)
pgsql::opt_int(maybe)    pgsql::opt_text(maybe)
```

`numeric` takes the digits themselves, so an exact decimal is never rounded
through a float. `text` is also how you bind any type whose text form you
already have - a timestamp, a UUID, JSON, an `inet`, a range - which is
exactly what the server reads for those.

A column reads back through the accessors on `Row`, by index (`_at`) or by
name (`_of`):

```gossamer
row.i64_of("id")?         row.f64_of("ratio")?      row.bool_of("active")?
row.text_of("name")?      row.bytes_of("blob")?     row.timestamp_of("at")?
row.array_of("tags")?     row.record_of("addr")?    row.range_of("span")?
row.opt_i64_of("score")?  row.opt_text_of("note")?  row.is_null_of("note")
```

Every non-NULL value has a text form, so `text_of` always answers something
faithful: `numeric` keeps every digit, and a type the driver has no more
specific reading for arrives exactly as the server wrote it.

### Wire formats

Results arrive in text format by default, which every PostgreSQL type has.
`db.set_result_format(pgsql::value::FORMAT_BINARY)` switches to binary for the
types that carry a binary reading here (integers, floats, `bool`, `bytea`,
character data, `json`/`jsonb`, `uuid`, `numeric`, and arrays of those).
Parameters go as text except a `bytea`, which goes as binary.

## Statements

```gossamer
db.execute(&sql, &params)?          // rows affected
db.query(&sql, &params)?            // every row
db.query_one(&sql, &params)?        // exactly one row, or an error
db.query_opt(&sql, &params)?        // at most one row
db.query_value(&sql, &params)?      // the single value of a 1x1 result
db.query_raw(&sql, &params)?        // a stream, pulled with next_row
db.batch_execute(&sql)?             // DDL or a script, no parameters
db.simple_query(&sql)?              // every result set of a multi-statement query
```

A parameterized call prepares its statement on first use and caches it by SQL
text, so a repeated query costs one round trip.
`db.set_statement_cache(false)` turns that off. `db.prepare` /
`db.prepare_typed` hand you the statement (with its parameter OIDs and column
descriptions) when you want to hold it yourself.

For a result too large to hold at once, stream it:

```gossamer
let mut rows = db.query_raw(&"SELECT id FROM big", &#[])?
loop {
    match db.next_row(&mut rows)? {
        Some(row) => consume(row.i64_at(0)?),
        None => break,
    }
}
```

Reaching the end leaves the connection ready. `db.close_stream(&mut rows)`
abandons one early and drains whatever the server was still sending.

A server-side portal fetches in batches inside a transaction:

```gossamer
let mut tx = db.transaction()?
let mut portal = db.open_portal(&"SELECT id FROM big", &#[])?
loop {
    let batch = db.fetch(&mut portal, 500)?
    if batch.len() == 0 { break }
    for row in batch { consume(row.i64_at(0)?) }
}
db.commit(&mut tx)?
```

`db.pipeline(&sql_list, &param_sets)` sends several statements before reading
any reply, for a batch of writes in one round trip.

## Transactions

```gossamer
let mut tx = db.transaction()?
let _ = db.execute(&"UPDATE accounts SET balance = balance - $1 WHERE id = $2", &#[...])?
let point = db.savepoint(&mut tx)?
match db.execute(&risky, &#[])? {
    ...
}
db.rollback_to(point)?      // the transaction stays usable
db.commit(&mut tx)?
```

`db.begin_with(&options)` sets the isolation level, `READ ONLY`, and
`DEFERRABLE`:

```gossamer
let options = pgsql::client::TxOptions {
    isolation: pgsql::client::Isolation::Serializable,
    read_only: false,
    deferrable: false,
}
```

A statement that fails inside a transaction poisons it until a rollback -
that is the server's rule, not the driver's - so pair a fallible step with a
savepoint when the transaction should survive it.

## COPY

```gossamer
db.copy_in_rows(&"COPY people (name, age) FROM STDIN", &rows)?   // escaped for you
db.copy_in(&"COPY people FROM STDIN WITH (FORMAT csv)", &bytes)? // your own payload
db.copy_out(&"COPY people TO STDOUT")?                           // raw bytes
db.copy_out_lines(&"COPY people TO STDOUT")?                     // split into lines
```

`copy_in_rows` renders each row in COPY's text format, escaping tabs,
newlines, backslashes, and NULL.

## LISTEN / NOTIFY

```gossamer
db.listen("orders")?
db.notify("orders", "order 42 shipped")?
match db.poll_notification(5_000)? {
    Some(n) => println!("{}: {}", n.channel, n.payload),
    None => println!("nothing within five seconds"),
}
```

A notification that arrives during any other exchange is queued rather than
lost; `db.take_notification()` drains the queue without touching the socket.
Channel names are quoted, so a name from outside the program cannot end the
statement.

## Cancelling a query

A cancel request travels on its own connection, because the one running the
query is busy:

```gossamer
let token = db.cancel_token()
let cancel = || {
    time::sleep(1_000)
    let _ = token.cancel()
}
go cancel()
let outcome = db.query(&"SELECT pg_sleep(60)", &#[])   // reports 57014
```

Capture the token in a closure rather than passing it as a `go` argument: the
compiled concurrency ABI moves no aggregate across that boundary.

## Errors

A failed call reports `[SQLSTATE] message`, with the server's detail and hint
appended when it sent them. The SQLSTATE is the part to branch on - it is
stable across server versions and locales:

```gossamer
match db.execute(&insert, &params) {
    Ok(n) => n,
    Err(e) if pgsql::unique_violation(&e) => 0,
    Err(e) if pgsql::retryable(&e) => retry(),
    Err(e) => return Err(e),
}
```

`pgsql::sqlstate_of`, `unique_violation`, `foreign_key_violation`,
`not_null_violation`, `retryable`, and `in_error_class` read a failure.
`db.take_notices()` collects the notices the server reported out of band,
each as a `dberror::DbError` carrying every field the protocol defines
(severity, code, detail, hint, position, schema, table, column, constraint,
and the server's own file, line, and routine).

## Concurrency

A connection is a request/response stream: two overlapping exchanges on one
connection would interleave their messages, so every call takes `&mut`.
Concurrent work takes a connection each.

```gossamer
cohort {
    for shard in shards {
        spawn(|| {
            let mut db = pgsql::connect(&url)?
            defer db.close()
            work(&mut db, shard)
        })
    }
}?
```

`pgsql::pool_open(&url, max)` gives one goroutine a pool that reuses
connections and caps how many exist. A pool belongs to the goroutine that
owns it: a connection is an aggregate with nested growable storage, and the
compiled concurrency ABI cannot move one between goroutines, so cap the total
with a channel of tokens rather than sharing a pool.

## Tests

Unit tests live beside the code they cover and need no server:

```
gos test src
```

The integration suite is a project under `tests/integration` that depends on
the driver by path, so it exercises the working copy, and it talks to a real
server:

```
cd tests/integration
GOS_PGSQL_TEST_URL='host=/var/run/postgresql dbname=gos_pgsql_test' gos test .
```

`gos test .` at the repository root runs both suites together.

Set `GOS_PGSQL_TCP_URL` as well to exercise TCP and SCRAM-SHA-256. Each test
owns its own tables and drops them, so a run leaves nothing behind.

`examples/crud` is a short program that walks the main surface, and depends
on the driver by its git URL, the way any program does. To run it against a
working copy rather than the published repository, point the dependency at
it:

```toml
"github.com/danpozmanter/pgsql-gos" = { path = "../.." }
```

## Toolchain

The driver needs Gossamer v0.52.2 or newer.

Every path the driver takes runs identically on all three tiers: the
bytecode VM (`gos run`, `gos test`), the Cranelift JIT, and LLVM AOT
(`gos build`, `gos build --release`). `gos test` runs on the VM by design, so
tier agreement is checked by running the same program against a real server
under `gos run`, `gos build`, and `gos build --release` and comparing the
output byte for byte.
