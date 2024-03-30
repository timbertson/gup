class disallowed = object end
let (==) (_:disallowed) (_:disallowed) = assert false
let (!=) (_:disallowed) (_:disallowed) = assert false

let ($) a b c = a (b c)

let eq cmp a b = (cmp a b) = 0
let neq cmp a b = (cmp a b) <> 0

let print_repr (out: Format.formatter) r = CCFormat.string out r#repr
let print_obj (out: Format.formatter) r = r#print out

module EnvironmentMap = struct
	include StringMap
	let array env =
		let pairs = CCArray.of_list (StringMap.bindings env) in
		pairs |> CCArray.map (fun (k,v) -> k^"="^v)
end

module Unix = struct
	include Unix
	let environment_map () = (OSeq.of_array @@ Unix.environment ())
		|> OSeq.map (fun v -> CCString.Split.left ~by:"=" v)
		|> OSeq.filter_map CCFun.id
		|> EnvironmentMap.of_seq
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

let ppf to_s fmt obj = Format.pp_print_string fmt (to_s obj)
