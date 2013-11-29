open Batteries

class disallowed = object end
let (==) (a:disallowed) (b:disallowed) = assert false
let (!=) (a:disallowed) (b:disallowed) = assert false

let ($) a b c = a (b c)

let eq cmp a b = (cmp a b) = 0
let neq cmp a b = (cmp a b) <> 0

let print_repr out r = String.print out r#repr

module Option = struct
	include Option
	let or_else default opt = match opt with Some x -> x | None -> default
end
