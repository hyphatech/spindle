-- create_spindle_sessions: spindle-postgres's sessions table, written from
-- Session.schema ~table:"spindle_sessions", which test_spindle_postgres holds it to.

create table "spindle_sessions" (
  digest text primary key,
  data text not null,
  created_at timestamptz not null,
  seen_at timestamptz not null,
  expires_at timestamptz not null
);

create index "spindle_sessions_expires_at" on "spindle_sessions" (expires_at);

comment on table "spindle_sessions" is 'Sessions: a visit''s data, by the digest of the id its cookie holds.';
comment on column "spindle_sessions".digest is 'The SHA-256 of the session''s id, never the id itself.';
comment on column "spindle_sessions".seen_at is 'When the session was last used, moved on at most once a tenth of its idle limit.';
comment on column "spindle_sessions".expires_at is 'When the first of its idle and absolute limits ends it.';
