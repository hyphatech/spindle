(** [multipart/form-data], as RFC 7578 writes it over RFC 2046's boundaries:
    what a browser posts from a form with a file in it, read a part at a time as
    it arrives.

    {[
    let parts = Multipart.create ~boundary ~max_head:8192 pull in
    match Multipart.next parts with
    | Ok (Some part) -> (* part.name, part.filename; then Multipart.read *)
    | Ok None -> (* every part has been read *)
    | Error e -> ...
    ]}

    It holds no socket: [pull] is where its bytes come from, a piece at a time,
    and whatever a piece's size, the boundary is found across it. It holds a
    part's head, bounded by [max_head], and of a part's content only what may
    yet turn out to be the start of a boundary. [filename*] is not read, since
    RFC 7578 §4.2 has a sender not write one. *)

type part = {
  name : string;
      (** the [name] of its [Content-Disposition: form-data], which RFC 7578
          §4.2 has every part carry *)
  filename : string option;
      (** the [filename] there: text a person chose, and never a path *)
  content_type : Media_type.t;
      (** its [Content-Type]: [text/plain] where it sent none (RFC 7578 §4.4),
          and [application/octet-stream] where it sent one no reader can read *)
  headers : (string * string) list;
      (** every field of its head, in order, names lower-cased *)
}

type 'e error =
  | Malformed of string  (** in words for the log: what was wrong where *)
  | Head_too_large  (** a part's head past [max_head] *)
  | Source of 'e  (** [pull] failed *)

type 'e t

val boundary : Media_type.t -> string option
(** The boundary a [multipart/*] media type names: one to seventy of RFC 2046's
    [bchars], not ending in a space. [None] for any other media type, or a
    boundary that is none. *)

val create :
  ?max_head:int ->
  boundary:string ->
  (unit -> (string option, 'e) result) ->
  'e t
(** A reader of the body [pull] hands over, a piece at a time, [None] at its
    end. A part's head longer than [max_head] (16 KiB, as a server bounds a
    request's) is [Head_too_large]. *)

val next : 'e t -> (part option, 'e error) result
(** The next part's head, what is left of the current part passed over; [None]
    once the last boundary has been read. A body that ends before it is
    [Malformed], as is one whose boundary is followed by anything but [--],
    spaces and a line's end, and a part with no [Content-Disposition: form-data]
    and its [name]. *)

val read : 'e t -> ([ `Data of string | `End ], 'e error) result
(** The current part's content as it arrives, [`End] where it ends -- and before
    {!next} has been asked, or after the last part. *)

val to_string : boundary:string -> (part * string) list -> string
(** A body of these parts and their contents, as a browser writes one: each
    part's [Content-Disposition] from its [name] and [filename], each a quoted
    string -- its quotes and backslashes escaped, and a CR or an LF, which no
    quoted string holds, written [%0D] and [%0A] as the HTML standard has a
    browser write them -- and its [Content-Type] unless it is [text/plain],
    which a part with none is, or is one {!Media_type.to_string} refuses.
    [create] reads it back as itself, a CR or an LF in a name or a filename
    aside. *)
