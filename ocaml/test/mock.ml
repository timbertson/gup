open Batteries

type state = {
	links : (string * string) list;
	missing_paths: string list;
}

let _state : state option ref = ref None

let make_state ?links ?missing () =
	{
		links = links |> Option.default [];
		missing_paths = missing |> Option.default [];
	}

let get_state () =
	match !_state with
		| Some state -> state
		| None -> failwith "Mock.state not initialized"

let run ?state fn =
	_state := Some (state |> Option.default (make_state ()));
	let reset () = _state := None in
	let rv = try fn () with e -> (reset (); raise e) in
	reset ();
	rv

let try_find fn arg = try Some (fn arg) with Not_found -> None

module Fake_unix : Gup.Path.UNIX = struct
	let readlink : string -> string = fun path ->
		let open Unix in
		let state = get_state () in
		let link : string option = try_find (List.assoc path) state.links in
		let missing = try_find (List.find ((=) path)) state.missing_paths in
		match link, missing with
			| Some link, _ -> link
			| None, Some _missing -> raise (Unix_error (ENOENT, "readlink", path))
			| None, None -> raise (Unix_error (EINVAL, "readlink", path))
end
