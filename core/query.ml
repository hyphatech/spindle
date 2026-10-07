let optional name codec = Input.optional Input.query name codec
let required name codec = Input.required Input.query name codec
let default name codec value = Input.default Input.query name codec value
let list name codec = Input.list Input.query name codec
