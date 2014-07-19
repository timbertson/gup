open Batteries
open Std

include Zeroinstall_utils

let int_time (time:float) : Big_int.t = Big_int.of_float (floor (time *. 1000.0))
let get_mtime (path:string) : Big_int.t option Lwt.t =
	lwt stats = try_lwt
		lwt rv = Lwt_unix.lstat path in
		Lwt.return @@ Some rv
	with Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return None
	in
	Lwt.return @@ Option.map (fun st -> int_time (st.Lwt_unix.st_mtime)) stats

let isfile path =
	try_lwt
		lwt stat = Lwt_unix.lstat path in
		Lwt.return (stat.Unix.st_kind <> Unix.S_DIR)
	with Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return false

let join_if_relative ~base path =
	if Filename.is_relative path
		then Filename.concat base path
		else path

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

let relpath ~from path =
	(* TODO: windows *)
	let to_list p = List.filter (not $ String.is_empty) @@
		String.nsplit (Zeroinstall_utils.abspath p) Filename.dir_sep
	in
	let start_list = to_list from in
	let path_list = to_list path in

	let zipped = Enum.combine (List.enum path_list, List.enum start_list) in
	let common = Enum.count @@ Enum.take_while (fun (a,b) -> a = b) zipped in

	let rel_list =
		List.of_enum (Enum.repeat ~times:(List.length start_list - common) "..")
		@ (List.drop common path_list)
	in
	if List.length rel_list = 0
		then "."
		else String.join Filename.dir_sep rel_list

let isdir path =
	try Sys.is_directory path
	with Sys_error _ -> false
