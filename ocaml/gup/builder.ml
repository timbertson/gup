module StringMap = Map.Make(String)
open Batteries
open Std

let log = Logging.get_logger "gup.builder"

exception Target_failed of string * int option * string option

let _prepare_build : 'c. (Gupfile.buildscript -> 'c) -> string -> 'c option = fun cons path ->
	let buildscript = Gupfile.find_buildscript path in
	log#trace "Prepare_build %a -> %a"
		String.print_quoted path
		(Option.print print_repr) buildscript;
	Option.map cons buildscript

let _guess_executable path =
	File.with_file_in path (fun file ->
		let initial = IO.nread file 255 in
		if String.starts_with initial "#!" then (
			let initial = String.lchop ~n:2 initial in
			let (line, _) = try
				String.split ~by:"\n" initial with Not_found -> (initial,"")
			in
			let args = Str.split (Str.regexp "[ \t]+") line in
			match args with
				| bin :: rest ->
					let bin = if String.starts_with bin "."
						then Filename.concat (Filename.dirname path) bin
						else bin
					in
					if Util.is_absolute bin && not (Sys.file_exists bin) then (
						(* special-case: we ignore /path/to/<env> for compatibility with plain shell scripts on weird platforms *)
						if Filename.basename bin = "env" then rest
						else Error.raise_safe "No such interpreter: %s" bin;
					) else bin :: rest
				| [] -> []
		) else []
	)

let in_dir wd action =
	let initial_wd = Sys.getcwd () in
	Unix.chdir wd;
	Util.finally_do (fun _ -> Unix.chdir initial_wd) () action

let rec _is_dirty ?perform_build = (
	(*
	* Returns whether the dependency is dirty.
	* Builds any targets required to check dirtiness
	*)
	let allow_build, perform_build = match perform_build with
		| Some action -> true, action
		| None -> false, fun _ -> assert false
	in

	let rec _is_dirty = fun (state:State.target_state) (buildscript:Gupfile.buildscript) -> (
		let built : unit Lwt.t StringMap.t ref = ref StringMap.empty in
		let build_child_if_dirty : string -> bool Lwt.t = fun path -> (
			let open Lwt in
			try
				lwt () = StringMap.find path !built in
				return_false
			with Not_found -> (
				let result : bool Lwt.t = (
					log#trace "Recursing over dependency: %s -> %s" buildscript#target_path path;
					match Gupfile.find_buildscript path with
						| None ->
							log#trace "CLEAN: %s (not a target)" path;
							return_false
						| Some buildscript ->
							let child_state = new State.target_state path in
							lwt child_dirty = _is_dirty child_state buildscript in
							if child_dirty then (
								log#trace "_is_dirty(%s) -> True" path;
								if allow_build
									then perform_build buildscript
									else return_true
							) else (
								log#trace "_is_dirty(%s) -> False" path;
								return_false
							)
				) in
				built := StringMap.add path (result |> (Lwt.map ignore)) !built;
				result
			)
		) in

		lwt deps = state#deps in
		match deps with
			| None -> (
				log#debug "DIRTY: %s (is buildable but has no stored deps)" state#path;
				Lwt.return true
			)
			| Some deps -> (
				if deps#already_built then (
					log#trace "CLEAN: %s has already been built in this invocation" state#path;
					Lwt.return false
				) else (
					if allow_build then
						deps#is_dirty buildscript build_child_if_dirty
					else (
						(* This is a bit weird. Either the file is straight-up
						 * dirty, or we faked building of a child dep because it
						 * may have been dirty *)
						let open Lwt in
						let child_dirty = ref false in
						lwt dirty = deps#is_dirty buildscript (fun path ->
							lwt child_built = build_child_if_dirty path in
							if child_built then child_dirty := true;
							return_false
						) in
						return (dirty || !child_dirty)
					)
				)
			)
	) in
	_is_dirty
)


class target (buildscript:Gupfile.buildscript) =
	let path = buildscript#target_path in
	let state = new State.target_state path in

	object (self)
		method path = path
		method repr = "Target(" ^ buildscript#repr ^ ")"
		method state = state

		method build update : bool Lwt.t = self#_perform_build update

		method is_dirty : bool Lwt.t =
			_is_dirty ?perform_build:None state buildscript

		method private _perform_build (update: bool) : bool Lwt.t =
			let exe_path = Util.abspath buildscript#path in
			if not (Sys.file_exists exe_path) then
				Error.raise_safe "Build script does not exist: %s" exe_path;

			lwt needs_build = if update then (
				let perform_build buildscript = (new target buildscript)#build false in
				_is_dirty ~perform_build state buildscript
			) else Lwt.return_true in
			if not needs_build then (
				log#trace("no build needed");
				Lwt.return false
			) else (
				state#perform_build buildscript (fun exe deps ->

					let basedir = buildscript#basedir in
					Util.makedirs basedir;

					let env = Unix.environment_map ()
						|> EnvironmentMap.add "GUP_TARGET" (Util.abspath self#path)
						|> Parallel.Jobserver.extend_env
						|> EnvironmentMap.array
					in

					let target_relative_to_cwd = Util.relpath ~from:Var.root_cwd self#path in
					let output_file = Util.abspath (state#meta_path "out") in
					Util.try_remove output_file;
					let cleanup_output_file = ref true in
					let cleanup () =
						if !cleanup_output_file then
							Util.try_remove output_file
					in

					let do_build () =
						log#infos target_relative_to_cwd;
						lwt mtime = Util.get_mtime self#path in
						let args = List.concat
							[
								_guess_executable exe_path;
								[ exe_path; output_file; buildscript#target ]
							]
						in

						if !Var.trace then begin
							log#info " # %s" (Util.abspath basedir);
							log#info " + %a" (List.print String.print_quoted) args
						end else begin
							log#trace " from cwd: %s" (Util.abspath basedir);
							log#trace "executing: %a" (List.print String.print_quoted) args
						end;

						lwt ret = try_lwt in_dir basedir (fun () -> Lwt_process.exec
								~env:env
								((List.first args), (Array.of_list args))
							)
							with ex -> begin
								log#error "%s is not executable and has no shebang line" exe_path;
								raise ex
							end
						in
						lwt new_mtime = Util.get_mtime self#path in
						let target_changed = neq (Option.compare ~cmp:Big_int.compare) mtime new_mtime in
						lwt () = if target_changed then (
							let p = Option.print Big_int.print in
							log#trace "old_mtime=%a, new_mtime=%a" p mtime p new_mtime;
							if (Util.lisdir self#path) then Lwt.return_unit else (
								(* directories often need to be created directly *)
								let expect_clobber = match deps with None -> false | Some d -> d#clobbers in
								if (not (update && expect_clobber)) then (
									log#warn "%s modified %s directly"
										(Util.relpath ~from:Var.root_cwd exe_path)
										self#path
								);
								state#mark_clobbers
							)
						) else Lwt.return_unit in

						match ret with
							| Unix.WEXITED 0 -> begin
								lwt () = if Util.lexists output_file then (
									(* If both old and new exist, and either is a directory,
									 * remove the old dir before renaming *)
									if (Util.lexists self#path &&
										(Util.lisdir self#path || Util.lisdir output_file)
									) then (
										log#trace "removing previous %s" self#path;
										Util.rmtree self#path
									);
									log#trace "renaming %s -> %s" output_file self#path;
									Lwt_unix.rename output_file self#path
								) else (
									log#trace "output file %s did not get created" output_file;
									if (not target_changed) && (Util.lexists self#path) && (not (Util.islink self#path)) then (
										if Util.lexists self#path; then (
											log#warn "Removing stale target: %s" target_relative_to_cwd
										);
										(* TODO make this an lwt.t *)
										Util.try_remove self#path;
										Lwt.return_unit
									) else Lwt.return_unit
								) in
								cleanup_output_file := false; (* not needed *)
								Lwt.return true
							end
							| Unix.WEXITED code -> begin
								log#trace "builder exited with status %d" code;
								let temp_file = if Var.keep_failed_outputs () && Util.lexists output_file
									then (
										cleanup_output_file := false; (* not wanted *)
										Some (Util.relpath ~from:Var.root_cwd output_file)
									)
									else None
								in
								raise @@ Target_failed (target_relative_to_cwd, Some code, temp_file)
							end
							| _ -> begin
								log#trace "builder was terminated";
								raise @@ Target_failed (target_relative_to_cwd, None, None)
							end
					in
					try_lwt
						do_build ()
					finally
						Lwt.return (cleanup ())
				)
			)
	end

type prepared_build = [
	| `Target of target
	| `Symlink_to of string
]
let prepare_build  (path: string) : prepared_build option =
	match _prepare_build (new target) path with
		| Some target -> Some (`Target target)
		| None -> begin match Util.readlink path with
			(* # this target isn't buildable, but its symlink destination might be *)
			| Some dest ->
					let dest = if Util.is_absolute dest
						then dest
						else Filename.concat (Filename.dirname path) dest
					in
					Some (`Symlink_to dest)
			| None -> None
		end
