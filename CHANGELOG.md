# Changelog

## 0.1.1

- Move to `github.com/gossamer-lang/pgsql-gos`. Both the dependency key and the
  `use` path take the new id; the module name stays `pgsql_gos`.

## 0.1.0 - first release

- Speak the PostgreSQL frontend/backend protocol (version 3.0) in Gossamer
  alone: framing, startup, authentication, the simple and extended query
  protocols, COPY, and LISTEN/NOTIFY, over a TCP or Unix socket.
- Take connection parameters as a libpq keyword string or a `postgres://`
  URI, falling back to the `PG*` environment variables and then to libpq's
  defaults. Multiple hosts are tried in order, and `target_session_attrs`
  decides whether the server that answered is acceptable.
- Negotiate TLS at every `sslmode` (`disable`, `prefer`, `require`,
  `verify-ca`, `verify-full`), with `sslrootcert` naming a PEM file for a
  private root, as it does in libpq.
- Authenticate by trust, cleartext password, MD5, SCRAM-SHA-256, or
  SCRAM-SHA-256-PLUS, checking the server's SCRAM signature before treating
  the session as authenticated. Channel binding is chosen whenever the server
  offers it and the connection presented a certificate, so an exchange
  relayed to a different connection fails rather than succeeding elsewhere.
- Bound the three things worth bounding, each with its own parameter:
  `connect_timeout` (seconds) covers establishing the session and nothing
  after it, including the dial itself, so reaching a routed but silent host
  costs the deadline rather than however long the OS takes to give up on the
  address; `socket_timeout` (seconds) covers one socket read or write once
  the session is up, which is what catches a peer that stopped answering
  without closing; `statement_timeout` (milliseconds) travels in the startup
  message, so it is the session's own default and survives a `RESET ALL`.
- Prepare, bind, and execute with a per-connection statement cache; describe
  a statement's parameter types and result columns; pin parameter types with
  `prepare_typed`. The cache holds 256 statements, evicts the least recently
  used, and deallocates what it evicts on the server, so a program generating
  unbounded SQL text keeps a bounded number of plans on both sides.
- Answer a schema change under a cached statement rather than reporting it. A
  migration invalidates the plan the server built, which it reports as `0A000`
  or `26000`; the statement is prepared again against the current schema and
  the call runs once more, so a migration costs no failed queries.
- Stream a result set row by row, fetch a server-side portal in batches, and
  pipeline several statements into one round trip.
- Encode and decode both wire formats, including arrays with nulls, quoting,
  and nesting; composites; ranges and multiranges; `bytea` in hex and escape
  form; and `numeric` as the exact digits the server sent.
- Read `timestamp`, `timestamptz`, `date`, `time`, `timetz`, `interval`, and
  `uuid` as typed values in either wire format, at the resolution the server
  keeps them, and bind one directly. `infinity` and `-infinity` carry through
  `timestamp` and `date` both ways. Ordering is by the instant a value names
  rather than by its fields, so two zoned instants compare correctly and
  either infinity sorts at the end.
- Read `json` and `jsonb` as `Value::Json`, and bind one with `pgsql::json`.
- Render a row or a result set as JSON typed by each column's own OID:
  `pgsql::row_json`, `rows_json`, `db.query_json`, and `db.query_one_json`.
  `pgsql::insert_sql`, `select_sql`, `update_sql`, and `placeholders` build
  the statements a mapping needs.
- Run transactions with isolation levels, `READ ONLY`, `DEFERRABLE`, and
  savepoints.
- Move rows with COPY in both directions, streamed a chunk at a time so
  neither direction has to fit in memory, escaping COPY's text format.
  `copy_in_abort` leaves a failed load uncommitted.
- Subscribe with LISTEN, deliver with NOTIFY, and poll with a timeout;
  notifications that arrive during another exchange are queued.
- Cancel a running query through a token another goroutine can carry.
- Report a failure as `[SQLSTATE] message` with the server's detail and hint,
  and carry the SQLSTATE as a field on the error as well, so a caller that
  wraps a failure in context of its own still classifies it. Read one with
  `sqlstate_of`, `unique_violation`, `foreign_key_violation`,
  `not_null_violation`, `retryable`, and `in_error_class`. Notices are
  collected rather than raised, each with every field the protocol defines.
- Pool connections for one goroutine, reusing them and capping how many
  exist. A connection coming back is put back to what a freshly opened one
  is, so nothing a borrower set reaches the next one, and
  `set_max_lifetime` retires one that has been open long enough for a
  failover or a rolling restart to reach the pool.
- Cap connections across goroutines with `pgsql::limit_open`. Each goroutine
  opens and owns its own connection and what crosses the goroutine boundary
  is a permit, which a channel carries safely.
- Ship six examples under `examples/`, each depending on the driver by path
  and each run rather than only compiled in CI: the main surface, the two
  concurrency shapes, three ways to read a result too large to hold, a
  LISTEN/NOTIFY work queue, a JSON HTTP service, and the failures a correct
  program still has to handle. `examples/run-all.sh` runs them all.
- Need Gossamer v0.55.3, which carries two reference-counting fixes this
  driver's tier-parity suite found: a map insert freed the caller's own copy
  of a `String` key, and a struct stored in a container kept no share of its
  heap fields. Both hit only the compiled tiers, so a program built with `gos
  build` failed roughly a third of the statements it prepared while `gos
  test` stayed green.
- Check tier agreement in CI. `tests/parity` runs one program on the bytecode
  VM, the Cranelift JIT, and LLVM AOT against a real server and compares the
  transcripts byte for byte, which `gos test` cannot do because it runs on
  the VM. It runs 400 statements with distinct SQL and reads and evicts the
  statement cache after a bulk load, which is what found the two toolchain
  defects above. CI also runs both suites and every example against
  PostgreSQL 14 through 17, over a Unix socket as well as TCP, and builds
  every example the way a deployment ships it.
