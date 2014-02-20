open Batteries
open Std

let log = Logging.get_logger "gup.builder"

exception Target_failed of string
let assert_exists bin = if Util.is_absolute bin && not (Sys.file_exists bin) then
	Error.raise_safe "No such interpreter: %s" bin;
	bin

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
				| bin_arg :: rest -> let bin = assert_exists (
					if String.starts_with bin_arg "."
						then Filename.concat (Filename.dirname path) bin_arg
						else bin_arg
					) in
					bin :: rest
				| [] -> []
		) else []
	)

let in_dir wd action =
	let initial_wd = Sys.getcwd () in
	Unix.chdir wd;
	Util.finally_do (fun _ -> Unix.chdir initial_wd) () action

class target (buildscript:Gupfile.buildscript) =
	let path = buildscript#target_path in
	let state = new State.target_state path in

	let rec _is_dirty (state:State.target_state) (buildscript:Gupfile.buildscript) =
		(*
		* Returns whether the dependency is dirty.
		* Builds any targets required to check dirtiness
		*)
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
					let rec deps_dirty built : bool Lwt.t =
						lwt dirty = deps#is_dirty buildscript built in
						(* log#trace "deps.is_dirty(%r) -> %r" state.path, dirty *)
						match dirty with
						| State.Known true -> (Lwt.return_true)
						| State.Known false ->
							(
								(* not directly dirty - recurse children
								* and return `true` for the first dirty one, otherwise `false`
								*)
								try_lwt
									deps#children |> Lwt_list.exists_p (fun path ->
										log#trace "Recursing over dependency: %s" path;
										match Gupfile.find_buildscript path with
											| None ->
												log#trace "CLEAN: not a target";
												Lwt.return_false
											| Some buildscript ->
												let child_state = new State.target_state path in
												lwt child_dirty = _is_dirty child_state buildscript in
												if child_dirty then (
													log#trace "_is_dirty(%s) -> True" child_state#path;
													Lwt.return true
												) else Lwt.return_false
									)
								with Not_found -> Lwt.return_false
							)
						| State.Unknown deps ->
							(
								if built then
									Error.raise_safe "after building unknown targets, deps.is_dirty(TODO) -> TODO"
								;
								(* build undecided deps first, then retry: *)
								lwt () = deps |> Lwt_list.iter_s (fun dep ->
									log#trace "MAYBE_DIRTY: %s (unknown state - building it to find out)" dep#path;
									match _prepare_build (new target) dep#path with
										| None ->
												log#trace "%s turned out not to be a target - skipping" dep#path;
												Lwt.return_unit
										| Some target ->
												lwt (_:bool) = (target#build true) in
												Lwt.return_unit
								) in
								deps_dirty true
							)
					in
					deps_dirty false
				)
			)
	in

	object (self)
		method path = path
		method repr = "Target(" ^ buildscript#repr ^ ")"
		method state = state

		method build update : bool Lwt.t = self#_perform_build buildscript#path update

		method private _perform_build (exe_path:string) (update: bool) : bool Lwt.t =
			let exe_path = buildscript#path in
			if not (Sys.file_exists exe_path) then
				Error.raise_safe "Build script does not exist: %s" exe_path;

			lwt needs_build = if update then (_is_dirty state buildscript) else Lwt.return_true in
			if not needs_build then (
				log#trace("no build needed");
				Lwt.return false
			) else (
				state#perform_build exe_path (fun exe ->

					let basedir = buildscript#basedir in
					Util.makedirs basedir;

					let env = Unix.environment_map ()
						|> EnvironmentMap.add "GUP_TARGET" (Util.abspath self#path)
						|> Parallel.Jobserver.extend_env
						|> EnvironmentMap.array
					in

					let target_relative_to_cwd = Util.relpath ~from:Var.root_cwd self#path in
					let output_file = Util.abspath (state#meta_path "out") in
					let moved = ref false in
					let cleanup () =
						if not !moved then
							Util.try_remove output_file
					in

					let do_build () =
						log#infos target_relative_to_cwd;
						lwt mtime = Util.get_mtime self#path in
						let args = List.concat
							[
								_guess_executable exe_path;
								[ Util.abspath exe_path; output_file; buildscript#target ]
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
						if neq (Option.compare ~cmp:Big_int.compare) mtime new_mtime then (
							let p = Option.print Big_int.print in
							log#trace "old_mtime=%a, new_mtime=%a" p mtime p new_mtime;
							if not (Sys.is_directory self#path) then (
								(* directories often need to be created directly *)
								log#warn "%s modified %s directly" exe_path self#path
							)
						);

						match ret with
							| Unix.WEXITED 0 -> begin
								if Util.lexists output_file then (
									if (try Sys.is_directory self#path with Sys_error _ -> false) then (
										log#trace "calling rmtree() on previous %s" self#path;
										Util.rmtree self#path
									);
									log#trace "renaming %s -> %s" output_file self#path;
									Unix.rename output_file self#path
								) else
									log#trace "output file %s did not get created" output_file;
								moved := true;
								Lwt.return true
							end
							| Unix.WEXITED code -> begin
								log#trace "builder exited with status %d" code;
								raise @@ Target_failed (target_relative_to_cwd)
							end
							| _ -> begin
								log#trace "builder was terminated";
								raise @@ Target_failed (target_relative_to_cwd)
							end
					in
					try_lwt
						do_build ()
					finally
						Lwt.return (cleanup ())
				)
			)
	end

let prepare_build : string -> target option = _prepare_build (new target)
