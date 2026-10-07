# Compression

`App.make ~compress:Spindle.Compress.default` writes answers with gzip where
a client takes it, off unless given, because it is CPU the process pays and
a proxy in front often compresses already. `Compress.make ?min_bytes ?level
?types ()` -- 1 KiB, level 6, and text, JSON, XML, JavaScript, SVG and event
streams -- says what is worth it. A buffered answer of a listed type and
size, or a stream of one of no known length, is compressed to a client whose
`Accept-Encoding` takes gzip, unless it names a coding of its own, says
`Cache-Control: no-transform`, is part of a range, or is on a route that
says `~meta:Meta.(empty |> add Compress.never ())` -- the route that answers
a secret beside what a request sent, where a compressed length lets an
observer guess it. Every answer of a listed type says `Vary:
Accept-Encoding`, and a compressed one's entity tag carries the coding.

**A stream is compressed as it goes**: each `send` is its own deflate block
ending in a sync flush -- decompress's LZ77 holds back its lookahead until
more input or the end, so each is a pass of its own -- and what was sent is
decodable when it arrives; a keep-alive's filler goes through the same
stream. **A file is not compressed as it is read**: `Static` and `Files`
serve its `.br`, `.zst` or `.gz` sibling where the build wrote one and the
request takes it, typed as the file, preferring them in that order where the
client's weights tie.
