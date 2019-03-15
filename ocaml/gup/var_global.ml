open Batteries

module Key = struct
	let parent_target = "GUP_TARGET"
	let root = "GUP_ROOT"
	let parent_lease = "GUP_TOKEN"
	let run_id = "GUP_RUNID"
	let indent = "GUP_INDENT"
end

let indent =
	try String.length (Sys.getenv Key.indent)
	with Not_found -> 0

let get k = try (Some (Sys.getenv k)) with Not_found -> None
let get_or k default = try (Sys.getenv k) with Not_found -> default
let has_env k = match get k with Some _ -> true | None -> false

let is_test_mode = has_env "GUP_IN_TESTS"
let is_root = not @@ has_env Key.root
let parent_target () = get Key.parent_target
let rpc_server () = get "GUP_RPC"
let set_rpc_server addr = Unix.putenv "GUP_RPC" addr
let parent_lease () = get Key.parent_lease |> Option.map (fun s ->
	try int_of_string s with Failure _ -> failwith (Printf.sprintf "Invalid %s: %s" Key.parent_lease s)
)

let default_verbosity = Option.default 0 (Option.map int_of_string (get "GUP_VERBOSE"))
let set_verbosity v = Unix.putenv "GUP_VERBOSE" (string_of_int v)

let trace = ref (get_or "GUP_XTRACE" "0" = "1")

let runtime_dir () = get "XDG_RUNTIME_DIR" |> Option.default_delayed Filename.get_temp_dir_name

let set_trace t =
	(* Note: we ignore set_trace if trace is already true -
	 * you cannot turn trace off *)
	if (!trace) = false then (
		trace := t;
		Unix.putenv "GUP_XTRACE" (if t then "1" else "0")
	)

(* gup doesn't chdir, so this is safe to cache *)
let cwd = Lazy.from_fun Sys.getcwd

let set_keep_failed_outputs () = Unix.putenv "GUP_KEEP_FAILED" "1"
let keep_failed_outputs () = (get_or "GUP_KEEP_FAILED" "0") = "1"
