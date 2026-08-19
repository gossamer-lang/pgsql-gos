# Changelog

## 0.1.0 - first release

- Speak the PostgreSQL frontend/backend protocol (version 3.0) in Gossamer
  alone: framing, startup, authentication, the simple and extended query
  protocols, COPY, and LISTEN/NOTIFY, over a TCP or Unix socket.
- Take connection parameters as a libpq keyword string or a `postgres://`
  URI, falling back to the `PG*` environment variables and then to libpq's
  defaults. Multiple hosts are tried in order, and `target_session_attrs`
  decides whether the server that answered is acceptable.
- Negotiate TLS at every `sslmode` (`disable`, `prefer`, `require`,
  `verify-ca`, `verify-full`), with `sslrootcert` for a private root.
- Authenticate by trust, cleartext password, MD5, or SCRAM-SHA-256, checking
  the server's SCRAM signature before treating the session as authenticated.
  `channel_binding=require` reports that binding needs a certificate the
  socket API does not expose, rather than proceeding without it.
- Prepare, bind, and execute with a per-connection statement cache; describe
  a statement's parameter types and result columns; pin parameter types with
  `prepare_typed`.
- Stream a result set row by row, fetch a server-side portal in batches, and
  pipeline several statements into one round trip.
- Encode and decode both wire formats, including arrays with nulls, quoting,
  and nesting; composites; ranges; `bytea` in hex and escape form; and
  `numeric` as the exact digits the server sent.
- Run transactions with isolation levels, `READ ONLY`, `DEFERRABLE`, and
  savepoints.
- Move rows with COPY in both directions, escaping COPY's text format.
- Subscribe with LISTEN, deliver with NOTIFY, and poll with a timeout;
  notifications that arrive during another exchange are queued.
- Cancel a running query through a token another goroutine can carry.
- Report a failure as `[SQLSTATE] message` with the server's detail and hint,
  and classify it by SQLSTATE (`unique_violation`, `foreign_key_violation`,
  `not_null_violation`, `retryable`, `in_error_class`). Notices are collected
  rather than raised, each with every field the protocol defines.
- Pool connections for one goroutine, reusing them and capping how many exist.
