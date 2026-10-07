(* A second implementation of gzip -- decompress's decoder -- to read back
   what the server wrote, shared by the suites that compress. *)

(* gzip decoded by decompress's own decoder, a piece at a time: what could be
   read after each piece arrived. *)
let gunzip_pieces pieces =
  let o = De.bigstring_create 65536 in
  let out = Buffer.create 256 in
  (* The output buffer is given back only after a [`Flush]; before one, what
     is new in it since the last look is copied, and the buffer kept. *)
  let copied = ref 0 in
  let take d =
    let n = Bigarray.Array1.dim o - Gz.Inf.dst_rem d in
    for i = !copied to n - 1 do
      Buffer.add_char out (Bigarray.Array1.get o i)
    done;
    copied := n
  in
  let rec go d =
    match Gz.Inf.decode d with
    | `Await d ->
        take d;
        Ok d
    | `Flush d ->
        take d;
        copied := 0;
        go (Gz.Inf.flush d)
    | `End d ->
        take d;
        Ok d
    | `Malformed m -> Error m
  in
  let feed (d, seen) piece =
    let bs = De.bigstring_create (String.length piece) in
    String.iteri (fun i c -> Bigarray.Array1.set bs i c) piece;
    match go (Gz.Inf.src d bs 0 (String.length piece)) with
    | Ok d -> (d, Buffer.contents out :: seen)
    | Error m -> failwith ("not gzip: " ^ m)
  in
  List.rev (snd (List.fold_left feed (Gz.Inf.decoder `Manual ~o, []) pieces))

let gunzip s =
  match List.rev (gunzip_pieces [ s ]) with d :: _ -> d | [] -> ""
