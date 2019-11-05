open Std
open Path
open Error
module Log = (val Var.log_module "gup.builder")

let _guess_executable path =
	Lwt_io.with_file ~mode:Lwt_io.input path (fun file ->
		Lwt_io.read ~count:255 file |> Lwt.map (fun initial ->
			if CCString.prefix ~pre:"#!" initial then (
				let initial = CCString.drop 2 initial in
				let (line, _) =
					CCString.Split.left ~by:"\n" initial |> CCOpt.get_or ~default:(initial,"")
				in
				let args = Str.split (Str.regexp "[ \t]+") line in
				match args with
					| bin :: rest ->
						let bin = if CCString.prefix ~pre:"." bin
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
	)

let in_dir wd action =
	let initial_wd = Lazy.force Var_global.cwd in
	Unix.chdir wd;
	Util.finally_do (fun _ -> Unix.chdir initial_wd) () action

let perform_build ~lease ~var ~toplevel (buildable: Buildable.t) = (
	(* actually perform a build *)
	let path = Buildable.target_path buildable in
	let state = new State.target_state ~var path in
	let exe_path = Buildable.script buildable in
	if not (Absolute.exists exe_path) then
		Error.raise_safe "Build script does not exist: %s" (Absolute.to_string exe_path);

	state#perform_build buildable (fun deps ->
		let path_str = ConcreteBase.to_string path in
		let target = Buildable.target buildable in
		let basedir = target |> RelativeFrom.base in
		let basedir_str = Concrete.to_string basedir in
		Util.makedirs basedir_str;

		let env = Unix.environment_map ()
			|> EnvironmentMap.add "GUP_TARGET" path_str
			|> Parallel.Jobpool.extend_env ~lease
			|> Var.extend_env var
			|> EnvironmentMap.array
		in

		let relative_to_root_cwd : ConcreteBase.t -> string = fun path ->
			ConcreteBase.rebase_to Var.root_cwd path
			|> RelativeFrom.relative |> Relative.to_string
		in

		let target_relstr = relative_to_root_cwd path in

		let output_file = Concrete.resolve_abs (state#meta_path "out") |> Concrete.to_string in
		Util.try_remove output_file;
		let cleanup_output_file = ref true in
		let cleanup () =
			if !cleanup_output_file then
				Util.try_remove output_file
		in

		let do_build () =
			Log.info var (fun m->m"%s" target_relstr);
			let exe_path_str = Absolute.to_string exe_path in
			let%lwt (mtime, executable) = Util.lwt_zip
				(Util.get_mtime path_str)
				(_guess_executable exe_path_str) in
			let args = List.concat
				[
					executable;
					[ exe_path_str; output_file;
						target |> RelativeFrom.relative |> Relative.to_string
					]
				]
			in

			if !Var_global.trace then begin
				Log.info var (fun m->m " # %s" basedir_str);
				Log.info var (fun m->m " + %a" PP.(list string) args)
			end else begin
				Log.trace var (fun m->m " from cwd: %s" basedir_str);
				Log.trace var (fun m->m "executing: %a" PP.(list string) args)
			end;

			let%lwt ret = try%lwt in_dir basedir_str (fun () -> Lwt_process.exec
					~env:env
					((List.hd args), (Array.of_list args))
				)
				with ex -> begin
					Log.err var (fun m -> m"%s is not executable and has no shebang line" exe_path_str);
					raise ex
				end
			in
			let%lwt new_mtime = Util.get_mtime path_str in
			let target_changed = neq (CCOpt.compare Big_int.compare_big_int) mtime new_mtime in
			let%lwt () = if target_changed then (
				let p = CCOpt.pp Util.big_int_pp in
				Log.trace var (fun m->m "old_mtime=%a, new_mtime=%a" p mtime p new_mtime);
				if (Util.lisdir path_str) then Lwt.return_unit else (
					(* directories often need to be created directly *)
					let expect_clobber = match deps with None -> false | Some d -> d#clobbers in
					if (toplevel || (not expect_clobber)) then (
						Log.warn var (fun m->m "%s modified %s directly"
							(relative_to_root_cwd (ConcreteBase.resolve_abs exe_path))
							target_relstr)
					);
					state#mark_clobbers
				)
			) else Lwt.return_unit in

			match ret with
				| Unix.WEXITED 0 -> begin
					let%lwt () = if Util.lexists output_file then (
						(* If both old and new exist, and either is a directory,
						 * remove the old dir before renaming *)
						if (Util.lexists path_str &&
							(Util.lisdir path_str || Util.lisdir output_file)
						) then (
							Log.trace var (fun m->m "removing previous %s" path_str);
							Util.rmtree path_str
						);
						Log.trace var (fun m->m "renaming %s -> %s" output_file path_str);
						Lwt_unix.rename output_file path_str
					) else (
						Log.trace var (fun m->m "output file %s did not get created" output_file);
						if (not target_changed) && (Util.lexists path_str) && (not (Util.islink path_str)) then (
							if Util.lexists path_str; then (
								Log.warn var (fun m->m "Removing stale target: %s" target_relstr)
							);
							(* TODO make this an lwt.t *)
							Util.try_remove path_str;
							Lwt.return_unit
						) else Lwt.return_unit
					) in
					cleanup_output_file := false; (* not needed *)
					Lwt.return true
				end
				| Unix.WEXITED code -> begin
					Log.trace var (fun m->m "builder exited with status %d" code);
					let temp_file = if Var_global.keep_failed_outputs () && Util.lexists output_file
						then (
							cleanup_output_file := false; (* not wanted *)
							Some (relative_to_root_cwd (ConcreteBase.resolve ~cwd:var.Var.cwd output_file))
						)
						else None
					in
					raise @@ Target_failed (target_relstr, Some code, temp_file)
				end
				| _ -> begin
					Log.trace var (fun m->m "builder was terminated");
					raise @@ Target_failed (target_relstr, None, None)
				end
		in
		(
			try%lwt do_build ()
			with e -> raise e
		) [%lwt.finally
			Lwt.return (cleanup ())
		]
	)
)

let _build_if_dirty ~lease ~var ~cache ~dry = (
	(*
	* Returns whether the dependency was built.
	* If `dry` is true, does not build but returns
	* whether any target would be built.
	*
	* Awkwardly, there are two different forms of recursion in targets:
	* - buildscript recursion, e.g. when target `foo` is built by
	*   `foo-builder`, but `foo-builder` is itself built by
	*   `foo-builder-builder`, etc.
	*   The entire chain of buildscript recursion is returned by
	*   the search for the initial buildscript for a target.
	*
	* - runtime dependencies, e.g. anything you call `gup -u` on
	*   during the build process. These are stored in the deps file
	*   within the gup directory, so they aren't known up front.
	*
	* `build_target_if_dirty` handles the core building logic, and
	* that's invoked via either `build_recursive_if_dirty` (for buildscript
	* recursion) or `build_path_if_dirty` (for runtime dependencies)
	*)
	let perform_build = if dry
		then (fun _ -> Lwt.return_true)
		else perform_build ~lease ~var ~toplevel:false in

	(* builds a single buildable if its state is dirty *)
	let rec build_target_if_dirty buildable = (
		let target_path = Buildable.target_path buildable in
		PathMap.cached cache target_path (fun () ->
			Log.debug var (fun m->m "%s [check]"
				(ConcreteBase.rebase_to Var.root_cwd target_path
				|> RelativeFrom.relative |> Relative.to_string)
			);
			let state = new State.target_state ~var target_path in
			Log.trace var (fun m->m "checking whether %s is dirty" state#path_repr);
			let%lwt deps = state#deps in
			match deps with
				| None -> (
					Log.debug var (fun m->m "DIRTY: %s (is buildable but has no stored deps)" state#path_repr);
					perform_build buildable
				)
				| Some deps -> (
					if deps#already_built then (
						Log.trace var (fun m->m "CLEAN: %s has already been built in this invocation" state#path_repr);
						Lwt.return_false
					) else (
						if dry then (
							(* In order to determine whether this file _may_ be dirty,
							 * we inject a fake build function which just sets a flag
							 * if any possibly-dirty dependency needs a build. *)
							let open Lwt in
							let child_dirty = ref false in
							let%lwt dirty = deps#is_dirty ~var buildable (fun path ->
								let%lwt child_built = build_path_if_dirty path in
								if child_built then child_dirty := true;
								return_false (* short-circuit any further checking *)
							) in
							return (dirty || !child_dirty)
						)
						else (
							Lwt.bind (deps#is_dirty ~var buildable build_path_if_dirty) (function
								| true -> perform_build buildable
								| false -> Lwt.return_false
							)
						)
					)
				)
			)
	)

	(* builds a single _path_ if dirty (used by deps#is_dirty) *)
	and build_path_if_dirty path = (
		let path = ConcreteBase.resolve_relfrom path in
		let%lwt builder = Gupfile.find_builder ~var path in
		match builder with
			| None ->
				Log.trace var (fun m->m "CLEAN: %s (not a target)" (ConcreteBase.to_string path));
				Lwt.return_false
			| Some buildable -> build_recursive_if_dirty buildable
	)

	and build_recursive_if_dirty (buildable: Buildable.t Recursive.t) = (
		Log.trace var (fun m->m "checking if %a needs to be built" (Recursive.print Buildable.print) buildable);
		match buildable with
			| Recursive.Recurse { parent; child = self } ->
				Lwt.bind (build_recursive_if_dirty parent) (function
					| true -> perform_build self
					| false -> build_target_if_dirty self
				)
			| Recursive.Terminal self ->
				build_target_if_dirty self
	) in

	build_recursive_if_dirty
)

let is_dirty ~var buildable : bool Lwt.t =
	_build_if_dirty ~lease:None ~var ~cache:(ref PathMap.empty) ~dry:true buildable

let _build_cache = ref PathMap.empty

let rec build ~lease ~var ~update (buildable: Buildable.t Recursive.t) : bool Lwt.t =
	if update then (
		_build_if_dirty ~lease ~var ~cache:_build_cache ~dry:false buildable
	) else (
		match buildable with
			| Recursive.Recurse { parent; child } ->
				Lwt.bind (build ~lease ~var ~update:true parent) (fun (_:bool) ->
					perform_build ~lease ~var ~toplevel:true child
				)
			| Recursive.Terminal child -> perform_build ~lease ~var ~toplevel:true child
	)

type prepared_build = [
	| `Target of Buildable.t Recursive.t
	| `Symlink_to of RelativeFrom.t
]

let prepare_build ~var (path: ConcreteBase.t) : prepared_build option Lwt.t =
	Gupfile.find_builder ~var path |> Lwt.map (function
		| Some buildable -> Some (`Target buildable)
		| None -> (match ConcreteBase.readlink path with
			(* # this target isn't buildable, but its symlink destination might be *)
			| `concrete _ -> None
			| `link dest -> Some (`Symlink_to dest)
		)
	)
