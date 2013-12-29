open Batteries

class disallowed = object end
let (==) (a:disallowed) (b:disallowed) = assert false
let (!=) (a:disallowed) (b:disallowed) = assert false

let ($) a b c = a (b c)

let eq cmp a b = (cmp a b) = 0
let neq cmp a b = (cmp a b) <> 0

let print_repr out r = String.print out r#repr
let print_obj out r = r#print out

module Option = struct
	include Option
	let or_else default opt = match opt with Some x -> x | None -> default
end

module EnvironmentMap = struct
	include Map.Make (String)
	let array env = enum env |> Enum.map (fun (k, v) -> k^"="^v) |> Array.of_enum
end

module Unix = struct
	include Batteries.Unix
	let environment_map () = (Array.enum @@ Unix.environment ()) |>
		Enum.map (fun v -> String.split v "=") |>
		EnvironmentMap.of_enum
end
