module S = Rowtype

(* Written into each statement, so it must be one plain identifier, and is
   written quoted, since one may be a word SQL reserves: [user], [order]. It
   holds no quote to double, and is lowercase, so quoted it names the table
   it names unquoted. *)
let quoted name = "\"" ^ name ^ "\""

let checked_table_name table =
  let ok =
    String.length table > 0
    && String.length table <= 63
    && (match table.[0] with 'a' .. 'z' | '_' -> true | _ -> false)
    && String.for_all
         (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
         table
  in
  if ok then table
  else
    invalid_arg
      (Printf.sprintf "Spindle_postgres.Session: %S is not a table's name" table)

(* Postgres keeps 63 bytes of a name, and cut there the index's name could
   be the table's own: past it, Postgres names the index, uniquely. *)
let create_index table =
  let name = table ^ "_expires_at" in
  if String.length name <= 63 then "create index " ^ quoted name ^ " on"
  else "create index on"

let schema ~table =
  let table = checked_table_name table in
  let t = quoted table and create_index = create_index table in
  Printf.sprintf
    {|create table %s (
  digest text primary key,
  data text not null,
  created_at timestamptz not null,
  seen_at timestamptz not null,
  expires_at timestamptz not null
);

%s %s (expires_at);

comment on table %s is 'Sessions: a visit''s data, by the digest of the id its cookie holds.';
comment on column %s.digest is 'The SHA-256 of the session''s id, never the id itself.';
comment on column %s.seen_at is 'When the session was last used, moved on at most once a tenth of its idle limit.';
comment on column %s.expires_at is 'When the first of its idle and absolute limits ends it.';
|}
    t create_index t t t t t

type statements = {
  find : (string, (string * Ptime.t * Ptime.t * Ptime.t) option) S.statement;
  save : (string * string * Ptime.t * Ptime.t * Ptime.t, unit) S.statement;
  delete : (string, unit) S.statement;
  sweep : (Ptime.t * int, int) S.statement;
}

let statements_for ~table =
  let t = quoted (checked_table_name table) in
  {
    find =
      S.find_opt ~params:S.text
        ~row:S.(t4 text instant instant instant)
        (Printf.sprintf
           "select data, created_at, seen_at, expires_at from %s where digest \
            = $1"
           t);
    save =
      S.exec
        ~params:S.(t5 text text instant instant instant)
        (Printf.sprintf
           "insert into %s (digest, data, created_at, seen_at, expires_at) \
            values ($1, $2, $3, $4, $5) on conflict (digest) do update set \
            data = excluded.data, seen_at = excluded.seen_at, expires_at = \
            excluded.expires_at"
           t);
    delete =
      S.exec ~params:S.text
        (Printf.sprintf "delete from %s where digest = $1" t);
    (* The soonest ended first, by the index on expires_at, and none another
       server's sweep holds: two servers sweeping at once share the work and
       never wait on each other. *)
    sweep =
      S.exec_count
        ~params:S.(t2 instant int)
        (Printf.sprintf
           "delete from %s where digest in (select digest from %s where \
            expires_at <= $1 order by expires_at limit $2 for update skip \
            locked)"
           t t);
  }

let statements ~table =
  let s = statements_for ~table in
  S.[ Any s.find; Any s.save; Any s.delete; Any s.sweep ]

let error_to_string e = Rowtype_postgres.error_to_string e

let store pool ~table =
  let s = statements_for ~table in
  let run statement params =
    Result.map_error error_to_string (Pool.exec pool statement params)
  in
  {
    Spindle.Session.find =
      (fun digest ->
        Result.map
          (Option.map (fun (data, created, seen, expires) ->
               { Spindle.Session.data; created; seen; expires }))
          (run s.find digest));
    save =
      (fun digest (e : Spindle.Session.entry) ->
        run s.save (digest, e.data, e.created, e.seen, e.expires));
    delete = (fun digest -> run s.delete digest);
    sweep = (fun ~now ~limit -> run s.sweep (now, limit));
  }
