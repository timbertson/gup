open Batteries
open Std

let log = Logging.get_logger "gup.builder"

exception Target_failed of string
let assert_exists bin = if Utils.is_absolute bin && not (Sys.file_exists bin) then
	Common.raise_safe "No such interpreter: %s" bin;
	bin

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
	Utils.finally_do (fun _ -> Unix.chdir initial_wd) () action

class target (builder:Gupfile.builder) =
	let path = builder#target_path in
	let state = new State.target_state path in

	(* XXX DUPLICATED *)
	let create_target b : target = new target b in
	let prepare_build path : target option =
		let builder = Gupfile.for_target path in
		log#trace "Prepare_build %a -> %a"
			String.print_quoted path
			(Option.print print_repr) builder;
		Option.map create_target builder
	in
	(* XXX end duplication *)

	let rec _is_dirty (state:State.target_state) (builder:Gupfile.builder) =
		(*
		* Returns whether the dependency is dirty.
		* Builds any targets required to check dirtiness
		*)
		Return.label (fun result ->
			match state#deps with
				| None -> (
					log#debug "DIRTY: %s (is buildable but has no stored deps)" state#path;
					true
				)
				| Some deps -> (
					if deps#already_built then (
						log#trace "CLEAN: %s has already been built in this invocation" state#path;
						Return.return result false
					)
					;
					let rec deps_dirty built =
						let dirty = deps#is_dirty builder built in
						(* log#trace "deps.is_dirty(%r) -> %r" state.path, dirty *)
						match dirty with
						| State.Known true -> (Return.return result true)
						| State.Known false -> (
							(* not directly dirty - recurse children
							* and return `true` for the first dirty one, otherwise `false`
							*)
							List.enum deps#children |> Enum.iter (fun path ->
								log#trace "Recursing over dependency: %s" path;
								match Gupfile.for_target path with
									| None -> log#trace "CLEAN: not a target"
									| Some builder ->
										let child_state = new State.target_state path in
										if _is_dirty child_state builder then (
											log#trace "_is_dirty(%s) -> True" child_state#path;
											Return.return result true
										)
							)
							;
							false
						)
						| State.Unknown deps -> (
							if built then
								Common.raise_safe "after building unknown targets, deps.is_dirty(TODO) -> TODO"
							;
							(* build undecided deps first, then retry: *)
							List.enum deps |> Enum.iter (fun dep ->
								log#trace "MAYBE_DIRTY: %s (unknown state - building it to find out)" dep#path;
								match prepare_build dep#path with
									| None -> log#trace "%s turned out not to be a target - skipping" dep#path
									| Some target -> ignore (target#build true)
								;
							);
							deps_dirty true
						)
					in
					deps_dirty false
				)
		)
	in

	object (self)
		method path = path
		method repr = "Target(" ^ builder#repr ^ ")"
		method state = state

		method build update =
			state#perform_build
				builder#path
				(fun exe -> self#_perform_build exe update)

		method private _perform_build (exe_path:string) (update: bool) =
			let exe_path = builder#path in
			if not (Sys.file_exists exe_path) then
				Common.raise_safe "Builder does not exist: %s" exe_path;

			if not (_is_dirty state builder) then (
				log#trace("no build needed");
				false
			) else (
				let basedir = builder#basedir in
				Utils.makedirs basedir;

				let env = Unix.environment_map ()
					|> EnvironmentMap.add "GUP_TARGET" (Utils.abspath self#path)
					|> EnvironmentMap.array
				in

				let target_relative_to_cwd = Util.relpath ~from:Var.root_cwd self#path in
				let output_file = Utils.abspath (state#meta_path "out") in
				let moved = ref false in
				let cleanup () =
					if not !moved then
						Util.try_remove output_file
				in

				let do_build () =
					log#infos target_relative_to_cwd;
					let mtime = Util.get_mtime self#path in
					let args = List.concat
						[
							_guess_executable exe_path;
							[ Utils.abspath exe_path; output_file; builder#target ]
						]
					in

					if !Var.trace then begin
						log#info " # %s" (Utils.abspath basedir);
						log#info " + %a" (List.print String.print_quoted) args
					end else begin
						log#trace " from cwd: %s" (Utils.abspath basedir);
						log#trace "executing: %a" (List.print String.print_quoted) args
					end;

					let pid = try in_dir basedir (fun () -> Unix.create_process_env
							(List.first args) (* prog *)
							(Array.of_list args)
							env
							Unix.stdin Unix.stdout Unix.stderr)
						with ex -> begin
							log#error "%s is not executable and has no shebang line" exe_path;
							raise ex
						end
					in

					(* TODO: Lwt_process.exec *)
					let (_, ret) = Unix.waitpid [] pid in

					let new_mtime = Util.get_mtime self#path in
					if neq (Option.compare ~cmp:Int.compare) mtime new_mtime then (
						let p = Option.print Int.print in
						log#trace "old_mtime=%a, new_mtime=%a" p mtime p new_mtime;
						if not (Sys.is_directory self#path) then (
							(* directories often need to be created directly *)
							log#warn "%s modified %s directly" exe_path self#path
						)
					);

					match ret with
						| Unix.WEXITED 0 -> begin
							if Sys.file_exists output_file then (
								if (try Sys.is_directory self#path with Sys_error _ -> false) then (
									log#trace "calling rmtree() on previous %s" self#path;
									Utils.rmtree self#path
								);
								log#trace "renaming %s -> %s" output_file self#path;
								Unix.rename output_file self#path
							) else
								log#trace "output file %s did not get created" output_file;
							moved := true
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
				Utils.finally_do cleanup () do_build;
				true
			)
	end

let create_target b : target = new target b

let prepare_build path : target option =
	let builder = Gupfile.for_target path in
	log#trace "Prepare_build %a -> %a"
		String.print_quoted path
		(Option.print print_repr) builder;
	Option.map create_target builder

