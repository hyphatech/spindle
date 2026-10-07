let optional name codec = Input.optional Input.header name codec
let required name codec = Input.required Input.header name codec
let default name codec value = Input.default Input.header name codec value
