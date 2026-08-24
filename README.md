# pgsql-gos

[![CI](https://github.com/gossamer-lang/pgsql-gos/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gossamer-lang/pgsql-gos/actions/workflows/ci.yml)

A PostgreSQL driver written entirely in Gossamer.

The driver speaks the PostgreSQL frontend/backend protocol (version 3.0)
directly over a TCP or Unix socket. There is no libpq, no Rust binding, and
nothing outside the Gossamer standard library: the wire framing, SASL
authentication, the extended query protocol, COPY, LISTEN/NOTIFY, and the
type codec are all Gossamer source in `src/`.

```gossamer
use std::errors
use "github.com/gossamer-lang/pgsql-gos" as pgsql

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
"github.com/gossamer-lang/pgsql-gos" = { git = "https://github.com/gossamer-lang/pgsql-gos" tag="v0.1.1" }
```

The whole surface is reached through the imported module; the driver's
submodules (`value`, `temporal`, `conn`, `client`, `config`, `oid`, `rowmap`,
`pool`) are reachable under it when you need a type by name
(`pgsql::value::Value`, `pgsql::temporal::Timestamp`, `pgsql::conn::Row`).

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
`target_session_attrs`, `connect_timeout`, `socket_timeout`,
`statement_timeout`, `options`. Anything else is sent as a session setting in
the startup message, so `search_path=app,public` reaches the server as one.

`pgsql::parse_config` answers the parsed parameters when you want to adjust
them before connecting.

### Deadlines

Three parameters bound three different things, and a program that wants a
query to fail rather than hang usually wants the last two:

| Parameter | Unit | Bounds |
|---|---|---|
| `connect_timeout` | seconds | opening the session: the dial, the TLS handshake, and authentication. Nothing after it. |
| `socket_timeout` | seconds | one socket read or write once the session is up, which is what catches a peer that stopped answering without closing. |
| `statement_timeout` | milliseconds | the server's own `statement_timeout`, so a long query is cancelled by the server and reports `57014`. |

```gossamer
pgsql::connect(&"host=db.example.com dbname=app \
                connect_timeout=5 socket_timeout=30 statement_timeout=10000")?
```

`connect_timeout` is libpq's parameter and means what libpq means by it: a
query that outlasts it still runs. It bounds each host in a multi-host list
separately, so a dead first host costs that deadline rather than however long
the OS takes to give up on the address.

`socket_timeout` is this driver's own, in seconds beside `connect_timeout`.
libpq reaches the same end through `tcp_user_timeout` and the keepalive
settings, which need socket options `std::net` does not expose; a read
deadline is what it does expose. A connection that hits it is not reusable -
the exchange was abandoned part-way - so it reports and closes. It has no
effect on a Unix-socket connection, which carries no read deadline; a local
peer that dies closes the socket rather than going silent.

`statement_timeout` travels in the startup message rather than as a `SET`
after it, so it is the session's own default and survives a `RESET ALL`.

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

SCRAM channel binding (`SCRAM-SHA-256-PLUS`) binds the exchange to the TLS
connection it runs over, so an exchange relayed to a different connection
fails rather than succeeding elsewhere. It is chosen whenever both ends can:
the server offers it and the connection presented a certificate to bind to.
`tls-server-end-point` is the binding type, hashing the server's certificate
with SHA-256. `channel_binding=require` refuses to authenticate without it
and says why - a plain connection has no certificate to bind to. GSSAPI and
SSPI are reported as unsupported. See [what the driver does not
do](#what-the-driver-does-not-do).

## Values

A parameter is a `value::Value`, built with the constructors on the package:

```gossamer
pgsql::null()            pgsql::boolean(true)     pgsql::int(42)
pgsql::float(1.5)        pgsql::numeric("12.50")  pgsql::text("Ada")
pgsql::bytes(#[0, 255])  pgsql::int_array(#[1,2])  pgsql::text_array(#["a","b"])
pgsql::array(items)      pgsql::record(fields)
pgsql::opt_int(maybe)    pgsql::opt_text(maybe)
pgsql::timestamp(at)     pgsql::date(day)         pgsql::time(clock)
pgsql::interval(span)    pgsql::uuid(id)          pgsql::json("{\"a\": 1}")
```

`numeric` takes the digits themselves, so an exact decimal is never rounded
through a float. `text` binds any type whose text form you already have - an
`inet`, a range, a geometric type - which is exactly what the server reads
for those.

A column reads back through the accessors on `Row`, by index (`_at`) or by
name (`_of`):

```gossamer
row.i64_of("id")?         row.f64_of("ratio")?      row.bool_of("active")?
row.text_of("name")?      row.bytes_of("blob")?     row.json_of("doc")?
row.array_of("tags")?     row.record_of("addr")?    row.range_of("span")?
row.multirange_of("gaps")?
row.timestamp_of("at")?   row.date_of("day")?       row.time_of("clock")?
row.interval_of("span")?  row.uuid_of("id")?        row.system_time_of("at")?
row.opt_i64_of("score")?  row.opt_text_of("note")?  row.is_null_of("note")
```

Every non-NULL value has a text form, so `text_of` always answers something
faithful: `numeric` keeps every digit, and a type the driver has no more
specific reading for arrives exactly as the server wrote it.

### Dates, times, intervals, and UUIDs

`timestamp`, `timestamptz`, `date`, `time`, `timetz`, `interval`, and `uuid`
decode to types of their own, in either wire format, at the resolution the
server keeps them:

```gossamer
let at = row.timestamp_of("created_at")?
at.year  at.month  at.day  at.hour  at.minute  at.second  at.micros
at.offset_minutes            // None for a `timestamp without time zone`
at.to_unix_micros()          // microseconds, not milliseconds
at.to_rfc3339()              // "2026-08-16T12:34:56.789012Z"
at.to_utc()  at.date()  at.time()
```

An `interval` keeps the three components PostgreSQL stores separately,
because no fixed conversion between them exists: a month is not a fixed
number of days, and a day is not a fixed number of hours across a DST
boundary.

```gossamer
let span = row.interval_of("age")?
span.months  span.days  span.micros
span.to_approximate_micros()   // a month as 30 days, when you have decided to
```

`infinity` and `-infinity` are values `timestamp` and `date` admit, and they
survive both directions in both wire formats (`at.bound`).

Ordering is by the instant a value names, not by its fields: two timestamps
in different zones name their instants with different civil fields, and
either infinity belongs at the end of the order rather than at year zero.
Read it with `a.is_before(&b)` / `a.is_after(&b)`, and sort a sequence by the
epoch reading:

```gossamer
let at = row.timestamp_of("created_at")?
at.is_before(&deadline)      at.is_after(&start)
rows.sort_by_key(|row| row.timestamp_of("created_at")?.to_unix_micros())
```

A `uuid` is its sixteen bytes, rendered canonically by `to_string`.
`std::time` counts milliseconds, so `row.system_time_of` is there when you
need that type - it drops the microsecond digits `timestamp_of` keeps.

### Rows as JSON

A row renders as a JSON object keyed by column name, with each value typed by
its column's own OID - integers and floats as numbers, `numeric` as a string
so every digit survives, `json` and `jsonb` spliced as the documents they
are, `bytea` as an array of bytes, an array column as a JSON array:

```gossamer
db.query_json(&"SELECT id, name FROM people", &#[])?      // [{"id":1,...},...]
db.query_one_json(&"SELECT ... WHERE id = $1", &#[id])?   // {"id":1,...}
pgsql::row_json(&row)   pgsql::rows_json(&rows)
```

That is also how a row reaches a struct of your own, since Gossamer derives
nothing for a user type:

```gossamer
use std::encoding::json

struct Person { id: i64, name: String }

let row = db.query_one(&"SELECT id, name FROM people WHERE id = $1", &#[id])?
let person = json::decode::<Person>(&pgsql::row_json(&row))
```

The decode has to live in your own program rather than in the driver:
`typeInfo::<T>()` reflects only in the entry file of the program that names
`T`, so a mapper written in this package could not see the fields it maps.
A NULL column reaches an `Option` field as `None`; a present value reaching
one does not currently arrive wrapped in `Some`, which is `json::decode`'s
own reading, so read a nullable column through `row.opt_text_of` and its
siblings until that settles.
For the other direction, `pgsql::insert_sql`, `select_sql`, `update_sql`, and
`placeholders` build the statement from a column list, leaving your mapping
function the parameter list alone:

```gossamer
let columns: Vec<String> = #["id", "name"]
db.execute(
    &pgsql::insert_sql(&"people", &columns)
    &#[pgsql::int(person.id), pgsql::text(person.name)]
)?
```

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
text, so a repeated query costs one round trip. The cache holds 256
statements, evicts the least recently used, and deallocates what it evicts on
the server, so a program generating unbounded SQL text keeps a bounded number
of plans on both sides:

```gossamer
db.set_statement_cache_capacity(1_000)   // or 0 to prepare every call
db.statement_cache_len()                 // what it holds now
db.clear_statement_cache()               // drop them all, on both sides
db.set_statement_cache(false)            // off entirely
```

A schema change under a cached statement is answered rather than reported. A
migration moves the result shape out from under a plan the server built, and
it says so with `0A000`, or with `26000` once it has dropped the statement
outright; either way the driver forgets what it cached, prepares the
statement against the schema as it now stands, and runs the call once more.
Without that, every migration costs one failed query per connection per
cached statement. A failure of any other kind is reported as it stands, and
inside a transaction so is this one - the block is already in its aborted
state there, where the server accepts only a rollback, so the recovery is the
caller's.

`db.prepare` / `db.prepare_typed` hand you the statement (with its parameter
OIDs and column descriptions) when you want to hold it yourself.

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
let mut options = pgsql::client::TxOptions::defaults()
options.isolation = pgsql::client::Isolation::Serializable
options.read_only = false
options.deferrable = false
```

Built from `defaults()` rather than written as a literal: a struct literal of
a type from another module does not currently lower to LLVM, so a program
that spells it out compiles under `gos run` and fails under `gos build
--release`. `examples/resilience` uses this form.

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
newlines, backslashes, and NULL, and sends in batches rather than assembling
one payload.

A load too large to hold at once streams a chunk at a time. A chunk needs no
relation to a row boundary - the server reassembles the stream:

```gossamer
let mut copy = db.copy_in_begin(&"COPY people (name, age) FROM STDIN")?
for batch in batches {
    db.copy_in_write_rows(&mut copy, &batch)?     // or copy_in_write for bytes
}
let rows = db.copy_in_end(&mut copy)?
```

`db.copy_in_abort(&mut copy, &reason)` gives up part-way, and the server
commits none of it.

A result too large to hold reads the same way, by chunk or by line:

```gossamer
let mut copy = db.copy_out_begin(&"COPY people TO STDOUT")?
while let Some(line) = db.copy_out_line(&mut copy)? {
    consume(line)
}
```

Reaching the end leaves the connection ready; `db.copy_out_end(&mut copy)`
abandons one early and drains whatever the server was still sending.

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

The SQLSTATE travels as a field on the error as well as in its text, and
wrapping keeps that link, so a failure classified several layers above the
call still reads the code the server sent:

```gossamer
let wrapped = errors::wrap(e, "saving the person")
pgsql::unique_violation(&wrapped)     // still true
pgsql::sqlstate_of(&wrapped)          // still "23505"
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
connections and caps how many exist.

```gossamer
let mut pool = pgsql::pool_open(&url, 8)?
pool.warm(2)?                        // open some before the first caller
pool.set_test_on_acquire(true)       // a round trip before lending, so a
                                     // restarted server reconnects rather
                                     // than failing a caller's first query
pool.set_max_lifetime(30 * 60_000)   // retire a connection after half an hour
pool.set_reset_on_release(false)     // keep what a borrower set (see below)

let mut db = pool.acquire()?
let outcome = work(&mut db)
pool.release(db)
```

A connection coming back is put back to what a freshly opened one is before
it is lent again: an open transaction is rolled back, and `RESET ALL; CLOSE
ALL; UNLISTEN *; DISCARD TEMP; DISCARD SEQUENCES` undoes the rest. A
`SET search_path` or `SET statement_timeout` one borrower ran would otherwise
decide what the next one's queries mean, and a temporary table or a LISTEN
registration would still be there. It costs one round trip per release, and
`set_reset_on_release(false)` turns it off for a pool whose borrowers all
leave the session alone. `db.reset_session()` is the same call on a
connection held directly.

The reset is `DISCARD ALL` less the `DEALLOCATE ALL` in it, so the
prepared-statement cache survives being returned to the pool. Anything the
connection string set at startup survives too, `statement_timeout` included,
because those are the session's own defaults rather than a later `SET`.

`set_max_lifetime` bounds how long a connection stays in the pool: without
one, a pool pins its sessions to the server they first reached, so a
failover, a rolling restart, or a changed address only reaches the pool as
connections happen to fail. The age is checked when a connection would be
lent and when one comes back, so a connection in use is never taken from its
borrower. `db.age_ms()` reports it.

A pool belongs to the goroutine that owns it: a connection is an aggregate with nested growable storage, which the
compiled concurrency ABI has no ownership descriptor for, so it can neither
be captured by a spawned goroutine nor sent through a channel. The compiler
says so - capturing a pool in a `spawn` is a check-time error, and
`sync::Shared` guards a single word rather than an aggregate - so this is a
diagnostic rather than something that reaches a running program.

For work spread across goroutines, a limiter caps how many connections exist
at once while each goroutine opens and owns its own. What crosses the
goroutine boundary is a permit, which a channel carries safely:

```gossamer
let limiter = pgsql::limit_open(&url, 8)?
cohort {
    for shard in shards {
        spawn(|| work(&limiter, shard))
    }
}?

fn work(limiter: &pgsql::pool::Limiter, shard: i64) -> Result<(), errors::Error> {
    let mut db = limiter.acquire()?      // waits for a permit, then connects
    let outcome = run(&mut db, shard)
    limiter.release(db)                  // closes it and gives the permit back
    outcome
}
```

`acquire` waits rather than reporting, because a limiter has other goroutines
to wait for; a connection that fails to open gives its permit back, so a
server refusing connections does not drain the limiter.

A limiter bounds how many connections exist; it does not reuse them. Until a
connection can cross a goroutine boundary, a request handler that runs in its
own goroutine pays a handshake per request, and the limiter is what keeps
that from opening more connections than the server allows.

## Examples

Six programs under `examples/`, each depending on the driver by path so it
exercises the working copy. Every one owns its tables and drops them, and
every one runs in CI: an example that does not run is documentation that has
stopped being true.

| Example | What it is about |
|---|---|
| `crud` | The main surface: connect, insert with parameters, read with typed accessors, map a row onto a struct, bulk load, roll back. |
| `concurrent` | The two concurrency shapes. A `Limiter` for work across goroutines, each owning its own connection; a `Pool` for one goroutine that stops paying the handshake. It counts its own sessions on the server to show the cap holding. |
| `streaming` | A quarter of a million rows read three ways - a row stream, a portal in batches, and COPY out by line - none of which ever holds the whole result. |
| `notify` | A work queue on LISTEN / NOTIFY: a worker that sleeps on the channel rather than polling, and reads the table when it wakes, because a notification is a wake-up rather than a delivery. |
| `service` | A JSON HTTP API. Handlers run in their own goroutines, so what they capture is a limiter rather than a pool, and the SQLSTATE is what decides the status code. |
| `resilience` | The failures a correct program still meets: a serialization conflict retried, a constraint violation classified, a savepoint containing a step that was allowed to fail, and a migration under a cached statement. |

Run one:

```
cd examples/streaming
GOS_PGSQL_URL='host=/var/run/postgresql dbname=gos_pgsql_test' gos run .
```

Or all of them, which is what CI does:

```
GOS_PGSQL_URL='host=/var/run/postgresql dbname=gos_pgsql_test' examples/run-all.sh
```

`examples/service` serves forever unless it is asked to check itself, which
binds a port, drives every route against itself, and shuts down:

```
cd examples/service
GOS_PGSQL_URL='...' gos run .              # serves on 8080
GOS_PGSQL_URL='...' gos run . --selftest   # checks every route and exits
```

Each example's `project.toml` points at the working copy. To depend on the
published repository instead, swap the path for the git URL the comment above
it names.

## Tests

Unit tests live beside the code they cover and need no server. They cover the
codec in both wire formats, the calendar arithmetic under the typed temporal
values, connection-string parsing, error classification, and the JSON
rendering:

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

`gos test .` at the repository root runs both suites together. Each test owns
its own tables and drops them, so a run leaves nothing behind.

Set `GOS_PGSQL_TCP_URL` as well to reach a server over TCP. Some tests need
one and skip without it: SCRAM-SHA-256, channel binding, and `socket_timeout`,
which is a read deadline only a TCP socket carries.

Two of the suite's tests are worth naming, because they check a property
rather than a spelling. One reads every value in both wire formats and
compares the two readings against each other, so a codec that decodes a type
one way in text and another in binary fails rather than waiting for a caller
to switch formats. The other reads every column by index and by name and
compares those, so the index-addressed half of `Row` is checked against the
named half rather than against expectations written in the test.

`gos test` runs on the bytecode VM by design, so tier agreement is not
something either suite can establish. `tests/parity` is one program that
walks the codec in both wire formats, the calendar arithmetic behind it,
streamed COPY, the statement cache, the JSON rendering, and a run of
statements each with SQL text the session has not seen; it prints a
transcript with no clock, PID, or server version in it. Its runner builds and
runs that program on all three tiers and compares the transcripts byte for
byte:

```
GOS_PGSQL_TEST_URL='host=/var/run/postgresql dbname=gos_pgsql_test' \
    tests/parity/run.sh
```

It currently reports a disagreement, which is a toolchain defect rather than
a driver one - see [the toolchain section](#known-defect-preparing-statements-on-a-compiled-tier).

### What CI runs

- `gos fmt --check`, `gos check`, and `gos lint` over the driver, and a
  `gos check` over every example.
- The unit and integration suites against PostgreSQL 14, 15, 16, and 17. The
  protocol is stable across them but the type catalogue is not, so a codec
  change that assumed a newer server shows up here.
- Every example, run rather than only compiled, against each of those.
- Every example built with `gos build --release`, which is what a deployment
  ships.
- The tier-parity program on all three tiers.
- The whole of the above a second time over a Unix socket rather than TCP,
  which is a different socket family, skips the TLS upgrade, and carries no
  read deadline.

## What the driver does not do

- **GSSAPI and SSPI** authentication are reported as unsupported.
- **A channel binding other than `tls-server-end-point`.** `tls-exporter`
  needs a TLS keying-material exporter, which `std::net` does not expose; a
  certificate signed with a digest other than SHA-256 is bound with SHA-256
  rather than its own, which is what PostgreSQL itself does.
- **A pool or a connection shared between goroutines**, and so no connection
  reuse for a handler that runs in its own goroutine. A connection is an
  aggregate with nested growable storage, which the compiled concurrency ABI
  has no ownership descriptor for: it cannot be captured by a `spawn`, sent
  through a channel, or guarded by `sync::Shared`, which holds one word. Each
  of those is a check-time error rather than a surprise at run time.
  `pgsql::limit_open` bounds how many connections exist across goroutines,
  which is the part that can be solved here - see
  [Concurrency](#concurrency).
- **A derived row-to-struct mapping.** `typeInfo::<T>()` reflects only in the
  entry file of the program that names `T`, so the decode lives in your
  program rather than here - see [Rows as JSON](#rows-as-json).
- **A client certificate** (`sslcert` / `sslkey`). The TLS upgrade
  `std::net` exposes presents no certificate of its own.
- **`~/.pgpass` and `PGPASSFILE`.** libpq refuses a password file that other
  users can read, and `fs::Metadata` reports no permission mode, so the file
  could be read but that refusal could not be honoured. Reading a secret
  libpq would have declined is not a convenience worth having; pass the
  password, or set `PGPASSWORD`.
- **A chain-only `verify-ca`.** libpq's `verify-ca` checks the chain and not
  the host name, and `verify-full` checks both. The TLS upgrade here verifies
  the host name whenever it verifies the chain, so `verify-ca` behaves as
  `verify-full`. It refuses connections libpq would accept - a certificate
  whose name does not match the host - rather than accepting any libpq would
  refuse.

## What the driver does not do

- **GSSAPI and SSPI** authentication are reported as unsupported.
- **A channel binding other than `tls-server-end-point`.** `tls-exporter`
  needs a TLS keying-material exporter, which `std::net` does not expose; a
  certificate signed with a digest other than SHA-256 is bound with SHA-256
  rather than its own, which is what PostgreSQL itself does.
- **A pool or a connection shared between goroutines**, and so no connection
  reuse for a handler that runs in its own goroutine. A connection is an
  aggregate with nested growable storage, which the compiled concurrency ABI
  has no ownership descriptor for: it cannot be captured by a `spawn`, sent
  through a channel, or guarded by `sync::Shared`, which holds one word. Each
  of those is a check-time error rather than a surprise at run time.
  `pgsql::limit_open` bounds how many connections exist across goroutines,
  which is the part that can be solved here - see
  [Concurrency](#concurrency).
- **A derived row-to-struct mapping.** `typeInfo::<T>()` reflects only in the
  entry file of the program that names `T`, so the decode lives in your
  program rather than here - see [Rows as JSON](#rows-as-json).
- **A client certificate** (`sslcert` / `sslkey`). The TLS upgrade
  `std::net` exposes presents no certificate of its own.
- **`~/.pgpass` and `PGPASSFILE`.** libpq refuses a password file that other
  users can read, and `fs::Metadata` reports no permission mode, so the file
  could be read but that refusal could not be honoured. Reading a secret
  libpq would have declined is not a convenience worth having; pass the
  password, or set `PGPASSWORD`.
- **A chain-only `verify-ca`.** libpq's `verify-ca` checks the chain and not
  the host name, and `verify-full` checks both. The TLS upgrade here verifies
  the host name whenever it verifies the chain, so `verify-ca` behaves as
  `verify-full`. It refuses connections libpq would accept - a certificate
  whose name does not match the host - rather than accepting any libpq would
  refuse.

## Toolchain

The driver needs Gossamer v0.55.3 or newer. An earlier toolchain builds it and
the bytecode VM runs it correctly, but two reference-counting defects fixed in
v0.55.3 make a compiled program unreliable - see below.

`tests/parity/run.sh` runs one program on the bytecode VM (`gos run`,
`gos test`), the Cranelift JIT (`gos build`), and LLVM AOT (`gos build
--release`) and compares the transcripts byte for byte, on every CI run. The
three tiers agree.

### The two defects this driver found

Both were in the toolchain's reference counting, both hit only the compiled
tiers, and both are fixed in v0.55.3. They are recorded here because the
shapes that found them are now part of `tests/parity`, and because a project
pinned to an older toolchain still meets them.

**A map insert freed the caller's copy of the key.** A consuming insert copies
the key's bytes and gives up the one reference the call handed it, but it was
clamping the count to one and then releasing - so `m.insert(k.clone(), v)`
freed `k` while the caller still held it. The next allocation of the same size
took the block, and `k` silently became some later string. The driver keys its
prepared-statement cache by SQL text, so a compiled program failed roughly a
third of the statements it prepared, reporting `42601 syntax error at or near
"gos_pgsql_sNN"` or `22021 invalid byte sequence` as the connection
desynchronized.

**A struct stored in a container kept no share of its heap fields.** The
compiled tiers count a struct's `String` and `Vec` fields per binding rather
than through the aggregate, and a consuming container call retained only a
scalar or `Vec` argument, so a struct argument left the entry with no share of
any field. The map that owns its values also took no share of the value word
itself, though reading one back hands a share out. The driver's cached
`Statement` carries a `String`, so evicting one after enough other allocation
read freed memory and faulted.

The bytecode VM was unaffected by both, which is why `gos test` stayed green
throughout and only a tier comparison found them. `tests/parity` now runs 400
statements with distinct SQL and prints how many failed, which is zero, and
reads and evicts the statement cache after a bulk load and prints what it
summed and held. Either defect returns as a differing transcript rather than
as an intermittent failure in a deployed program.
