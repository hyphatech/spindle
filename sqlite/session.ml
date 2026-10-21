module S = Rowtype

let default_table = "spindle_sessions"

(* Written into each statement, so it must be one plain identifier, and is
   written quoted, since one may be a word SQL reserves: [user], [order]. It
   holds no quote to double, and is lowercase, so quoted it names the table
   it names unquoted. *)
let quoted name = "\"" ^ name ^ "\""

let checked_table_name table =
  let ok =
    String.length table > 0
    && (match table.[0] with 'a' .. 'z' | '_' -> true | _ -> false)
    && String.for_all
         (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
         table
  in
  if ok then table
  else
    invalid_arg
      (Printf.sprintf "Spindle_sqlite.Session: %S is not a table's name" table)

(* An instant is UTC text, which sorts as time does, so the index orders
   the sweep. STRICT, so a column holds the kind of value it says. *)
let schema ~table =
  let table = checked_table_name table in
  let t = quoted table and index = quoted (table ^ "_expires_at") in
  Printf.sprintf
    {|-- Sessions: a visit's data, by the digest of the id its cookie holds.
-- digest: the SHA-256 of the session's id, never the id itself.
-- seen_at: when the session was last used, moved on at most once a tenth of its idle limit.
-- expires_at: when the first of its idle and absolute limits ends it.
create table %s (
  digest text primary key,
  data text not null,
  created_at text not null,
  seen_at text not null,
  expires_at text not null
) strict;

create index %s on %s (expires_at);
|}
    t index t

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
    (* The soonest ended first, by the index on expires_at; SQLite's one
       writer runs two servers' sweeps one after the other. *)
    sweep =
      S.exec_count
        ~params:S.(t2 instant int)
        (Printf.sprintf
           "delete from %s where digest in (select digest from %s where \
            expires_at <= $1 order by expires_at limit $2)"
           t t);
  }

let statements ?(table = default_table) () =
  let s = statements_for ~table in
  S.[ Any s.find; Any s.save; Any s.delete; Any s.sweep ]

let error_to_string e = Rowtype_sqlite.error_to_string e

(* The table is checked, and its statements written, once where the store
   is made: a request is handed the store over the pool it reads. *)
let store ?(table = default_table) db =
  let s = statements_for ~table in
  Spindle.Dep.map
    (fun pool ->
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
      })
    db
