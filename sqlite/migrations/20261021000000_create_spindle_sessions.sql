-- create_spindle_sessions: spindle-sqlite's sessions table, written from
-- Session.schema ~table:"spindle_sessions", which test_spindle_sqlite holds it to.

-- Sessions: a visit's data, by the digest of the id its cookie holds.
-- digest: the SHA-256 of the session's id, never the id itself.
-- seen_at: when the session was last used, moved on at most once a tenth of its idle limit.
-- expires_at: when the first of its idle and absolute limits ends it.
create table "spindle_sessions" (
  digest text primary key,
  data text not null,
  created_at text not null,
  seen_at text not null,
  expires_at text not null
) strict;

create index "spindle_sessions_expires_at" on "spindle_sessions" (expires_at);
