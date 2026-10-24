(* The authorization server oauth's tokens come from, and the resource they
   are for. *)

let auth =
  Spindle.Bearer.make ~issuer:"https://id.example.com"
    ~resource:"https://notes.example.com"
