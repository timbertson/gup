open Batteries

class disallowed = object end
let (==) (a:disallowed) (b:disallowed) = assert false
let (!=) (a:disallowed) (b:disallowed) = assert false

let ($) a b c = a (b c)

let eq cmp a b = (cmp a b) = 0
let neq cmp a b = (cmp a b) <> 0

let print_repr out r = String.print out r#repr
let print_obj out r = r#print out

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

(* make an alias for those functions where
 * we could do more integration with Lwt
 * (but we're not bothering yet)
 *)
let stub_lwt = Lwt.return

module Lwt = struct
	include Lwt
	let lift : 'a 'b. ('a -> 'b) -> 'a -> 'b Lwt.t = fun f x -> Lwt.return (f x)
end

module Lwt_option = struct
	let bind f v =
		match v with
		| None -> Lwt.return None
		| Some v -> Lwt.bind (f v) (fun r -> match r with
			| Some r -> Lwt.return (Some r)
			| None -> Lwt.return None
		)

	let map f v =
		match v with
		| None -> Lwt.return None
		| Some v -> f v

	let may f v =
		match v with
		| None -> Lwt.return_unit
		| Some v -> Lwt.(>>=) (f v) (fun _ -> Lwt.return_unit)
end

module List = struct
	include Batteries.List
	let headOpt l = try Some (List.hd l) with Failure _ -> None
end
