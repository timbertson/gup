open Std

include Zeroinstall_utils

let big_int_of_float f =
	try Big_int.big_int_of_string (Printf.sprintf "%.0f" f)
	with Failure _ -> invalid_arg "Big_int.of_float"

let int_time (time:float) : Big_int.big_int = big_int_of_float (floor (time *. 1000.0))
let get_mtime (path:string) : Big_int.big_int option Lwt.t =
	let%lwt stats = try%lwt
		let%lwt rv = Lwt_unix.lstat path in
		Lwt.return @@ Some rv
	with Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return None
	in
	Lwt.return @@ CCOpt.map (fun st -> int_time (st.Lwt_unix.st_mtime)) stats

let isfile path =
	try%lwt
		let%lwt stat = Lwt_unix.lstat path in
		Lwt.return (stat.Unix.st_kind <> Unix.S_DIR)
	with Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return false

let lexists (path:string) : bool =
	try
		let (_:Unix.stats) = Unix.lstat path in
		true
	with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let try_remove (path:string) =
	(* Remove a file. Ignore if it doesn't exist *)
	try
		Unix.unlink path
	with
		| Unix.Unix_error (Unix.EISDIR, _, _) -> rmtree path
		| Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let big_int_pp = Std.ppf Big_int.string_of_big_int

let samefile a b =
	assert (Zeroinstall_utils.is_absolute a);
	assert (Zeroinstall_utils.is_absolute b);
	(* TODO: windows case-insensitivity *)
	Zeroinstall_utils.normpath a = Zeroinstall_utils.normpath b

let isdir path =
	try Sys.is_directory path
	with Sys_error _ -> false

let islink path =
	try (Unix.lstat path).Unix.st_kind = Unix.S_LNK
	with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let lisdir path =
	try (Unix.lstat path).Unix.st_kind = Unix.S_DIR
	with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let which exe =
	let rec find thunk = match thunk () with
		| `Nil -> None
		| `Cons (p, tail) ->
			let p = Filename.concat p exe in
			if Sys.file_exists p
				then (Some p)
				else find tail
	in
	CCString.Split.klist_cpy ~by:":" (Unix.getenv "PATH") |> find
