open Batteries
open Std

let int_time (time:float) : int = int_of_float (time *. 1000.0)
let get_mtime (path:string) : int option =
	let stats = try
		(*XXX stop using `core` just for this...*)
		(* Some (Unix.lstat path) *)
		Some (Core.Core_unix.stat path)
	with Unix.Unix_error (Unix.ENOENT, _, _) -> None
	in
	(* Option.map (fun st -> int_time (st.Unix.st_mtime)) stats *)
	Option.map (fun st -> int_time (st.Core.Core_unix.st_mtime)) stats

let try_remove (path:string) =
	(* Remove a file. Ignore if it doesn't exist *)
	try
		Unix.unlink path
	with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let print_mtime : (unit IO.output -> int Option.t -> unit) = Option.print Int.print

let pathsep = ":" (* TODO: ";" on windows *)
let samefile a b =
	assert (Utils.is_absolute a);
	assert (Utils.is_absolute b);
	(* TODO: windows case-insensitivity *)
	Utils.normpath a = Utils.normpath b

let relpath ~from path =
	(* TODO: windows *)
	let to_list p = List.filter (not $ String.is_empty) @@
		String.nsplit (Utils.abspath p) Filename.dir_sep
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
