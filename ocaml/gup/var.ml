open Batteries
open Std

let indent = Logging.indent

let get k = try (Some (Sys.getenv k)) with Not_found -> None
let get_or k default = try (Sys.getenv k) with Not_found -> default
let has_env k = match get k with Some _ -> true | None -> false

let is_test_mode = has_env "GUP_IN_TESTS"
let is_root = not @@ has_env "GUP_ROOT"

let (run_id, root_cwd) =
	let open Path in
	if is_root then
		begin
			let runid = Big_int.to_string (Util.int_time (Unix.gettimeofday ()))
			and root = Sys.getcwd () in
			Unix.putenv "GUP_RUNID" runid;
			Unix.putenv "GUP_ROOT" root;
			(runid, Concrete.of_string root)
		end
	else
		(
			Unix.getenv "GUP_RUNID",
			Unix.getenv "GUP_ROOT" |> Concrete.of_string
		)

let default_verbosity = Option.default 0 (Option.map int_of_string (get "GUP_VERBOSE"))
let set_verbosity v = Unix.putenv "GUP_VERBOSE" (string_of_int v)

let trace = ref (get_or "GUP_XTRACE" "0" = "1")

let set_trace t =
	(* Note: we ignore set_trace if trace is already true -
	 * you cannot turn trace off *)
	if (!trace) = false then (
		trace := t;
		Unix.putenv "GUP_XTRACE" (if t then "1" else "0")
	)

let set_keep_failed_outputs () = Unix.putenv "GUP_KEEP_FAILED" "1"
let keep_failed_outputs () = (get_or "GUP_KEEP_FAILED" "0") = "1"
