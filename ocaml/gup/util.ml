open Batteries
open Std

include Zeroinstall_utils

let int_time (time:float) : Big_int.t = Big_int.of_float (floor (time *. 1000.0))
let get_mtime (path:string) : Big_int.t option Lwt.t =
	let%lwt stats = try%lwt
		let%lwt rv = Lwt_unix.lstat path in
		Lwt.return @@ Some rv
	with Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return None
	in
	Lwt.return @@ Option.map (fun st -> int_time (st.Lwt_unix.st_mtime)) stats

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

let print_mtime : (unit IO.output -> Big_int.t Option.t -> unit) = Option.print Big_int.print

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
	try Some (
		String.nsplit (Unix.getenv "PATH") ":"
			|> List.enum
			|> Enum.filter ((<>) "")
			|> Enum.map (fun p -> Filename.concat p exe)
			|> Enum.find Sys.file_exists
	) with Not_found -> None
