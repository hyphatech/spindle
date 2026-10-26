let optional name description = Input.optional Input.query name description
let required name description = Input.required Input.query name description

let default name description value =
  Input.default Input.query name description value

let list name description = Input.list Input.query name description
