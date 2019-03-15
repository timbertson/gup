open Batteries
open Std
open Extlib
open Path
open Error

module Log = (val Var.log_module "gup.cmd")
let exit_error () = exit 2

module CmdActions = struct
	open OptParse

	let ignore_hidden dirs =
		dirs |> List.filter (fun dir ->
			not @@ PathComponent.lift String.starts_with dir "."
		)
	
	let _assert_parent_target ~var action =
		match var.Var.parent_target with
			| None ->
				Log.warn var (fun m->m "%s was used outside of a gup target; ignoring" action);
				Pervasives.exit 0
			| Some p -> p

	let expect_no args =
		if List.length args > 0 then Error.raise_safe "no arguments expected"

	let _init_path ~var () =
		(* ensure `gup` is present on $PATH *)
		let progname = Array.get Sys.argv 0 in
		Log.trace var (fun m->m "run as: %s" progname);
		let existing_path = Var_global.get_or "PATH" "" in
		let gup_in_path = Var_global.get_or "GUP_IN_PATH" "0" in
		Unix.putenv "GUP_IN_PATH" "1";
		if String.exists progname Filename.dir_sep && (gup_in_path <> "1") then (
			(* TODO: (Windows) we should always perform this branch on Windows, regardless of
			 * whether Filename.dir_sep is in progname *)

			(* gup may have been run as a relative / absolute script - check *)
			(* whether our directory is in $PATH *)
			let path_to_prog = ConcreteBase.resolve ~cwd:var.Var.cwd progname in
			let bin_dir = ConcreteBase.dirname path_to_prog |> Concrete.to_string in
			let path_entries : string list = existing_path |> String.nsplit ~by: Util.path_sep in
			let already_in_path = List.enum path_entries
				|> Enum.exists ((=) bin_dir) in
			if already_in_path then
				Log.trace var (fun m->m("found `gup` in $PATH"))
			else (
				Log.trace var (fun m->m "`gup` not in $PATH - adding %s" bin_dir);
				Unix.putenv "PATH" @@ bin_dir ^ Util.path_sep ^ existing_path
			);
			Lwt.return_unit
		) else (
			Lwt.return_unit
		)
	
	let build ~var ~update ~jobs ~keep_failed posargs = (
		if Opt.get keep_failed then Var_global.set_keep_failed_outputs ();
		let update = Opt.get update in
		let posargs = match posargs with [] -> ["all"] | args -> args in

		let server = Var_global.rpc_server () in
		match server with
			| Some server -> Rpc.connect ~var ~server (fun state ->
					(* if GUP_RPC is defined, we must also have lease & parent *)
					let (lease, parent) = match (Var_global.parent_lease (), var.Var.parent_target) with
						| Some lease, Some parent -> (lease, parent)
						| lease, parent -> failwith (
								Printf.sprintf2 "Invalid environment: lease=%a, parent=%a"
									(Option.print Int.print) lease
									(Option.print String.print) (Option.map ConcreteBase.to_string parent)
							)
					in

					let%lwt built = Rpc.build ~lease ~state {
						update = true;
						parent = parent |> Path.ConcreteBase.to_string;
						cwd = var.Var.cwd |> Path.Concrete.to_string;
						targets = posargs;
						indent = var.Var.indent;
					} in
					if not built then raise BuildCancelled;
					Lwt.return_unit
				)
			| None -> (
				let%lwt () = _init_path ~var () in

				let jobs = Opt.get jobs in
				Rpc.Server.setup ~var jobs (fun job_info ->
					Action.build_all ~job_info ~var ~update posargs
				)
			)
	)
	
	let mark_ifcreate ~var args =
		if List.length args < 1 then Error.raise_safe "at least one file expected";
		let parent_target = _assert_parent_target ~var "--ifcreate" in
		let parent_state = new State.target_state ~var parent_target in
		args |> Lwt_list.iter_s (fun path_str ->
			let path = RelativeFrom.concat_from var.Var.cwd (PathString.parse path_str) in
			let traversed, final_path = Concrete.traverse_relfrom path in
			if Concrete.lexists final_path then
				Error.raise_safe "File already exists: %s" (path_str)
			;
			Lwt.join [
				parent_state#add_file_dependencies traversed;
				parent_state#add_file_dependency_with ~mtime:None ~checksum:None (ConcreteBase.make final_path `current);
			]
		)
	
	let mark_contents ~var targets =
		let parent_target = _assert_parent_target ~var "--contents" in
		let checksum =
			if List.length targets = 0 then (
				if (Unix.isatty Unix.stdin) then Error.raise_safe "stdin is a TTY";
				Checksum.from_stream ~var IO.stdin
			) else (
				Checksum.from_files ~var targets
			)
		in
		(new State.target_state ~var parent_target)#add_checksum checksum

	let mark_leave ~var args =
		expect_no args;
		let parent_target = _assert_parent_target ~var "--leave" |> ConcreteBase.to_string in
		let open Unix in
		let kind = try Some ((lstat parent_target).st_kind)
		with Unix_error(ENOENT, _, _) -> None in
		let () = match kind with
			| None | Some S_LNK -> ()
			| Some _ -> Unix.utimes parent_target 0.0 0.0
		in
		Lwt.return_unit

	let mark_always ~var args =
		expect_no args;
		let parent_target = _assert_parent_target ~var "--always" in
		(new State.target_state ~var parent_target)#mark_always_rebuild
	
	let clean
		~(force:bool Opt.t)
		~(dry_run:bool Opt.t)

		~(metadata:bool Opt.t)
		~(interactive:bool Opt.t)
		~var
		dests
	=
		let metadata = Opt.get metadata in
		let interactive = Opt.get interactive in
		let force = match (Opt.get force, Opt.get dry_run) with
			| (true, false) -> true
			| (false, true) -> false
			| _ -> Error.raise_safe "Exactly one of --force or --dry-run must be given"
		in
		let rm ?(isfile=false) path =
			Return.label (fun rv ->
				if not force then (
					Printf.printf "Would remove: %s\n" path;
					Return.return rv ()
				);

				Printf.eprintf "Removing: %s\n" path;
				if interactive then (
					Printf.eprintf "    [Y/n]: ";
					flush_all ();
					let response = String.trim (read_line ()) in
					if not @@ List.mem response ["y";"Y";""] then (
						Printf.eprintf "Skipped.\n";
						Return.return rv ()
					)
				);
				if isfile
					then Sys.remove path
					else Util.rmtree path
			)
		in
		let dests = if dests = [] then ["."] else dests in
		let meta_dir_name = State.meta_dir_name in
		List.enum dests |> Enum.iter (fun root ->
			PathString.walk root (fun base dirs files ->
				let removed_dirs = ref [] in
				if List.mem meta_dir_name dirs then (
					let gupdir = Filename.concat base (PathComponent.string_of_name meta_dir_name) in
					if not metadata then (
						(* remove any extant targets *)
						let built_targets = State.built_targets gupdir in
						built_targets |> List.iter (fun dep ->
							let dep_name = PathComponent.string_of_name dep in
							let path = (Filename.concat base dep_name) in
							let buildscript = Gupfile.find_builder ~var (ConcreteBase.resolve ~cwd:var.Var.cwd path) in
							buildscript |> Option.may (fun _ ->
								if List.mem dep files then
									rm ~isfile:true path
								else if List.mem dep dirs then (
									rm path;
									removed_dirs := dep :: !removed_dirs
								)
							)
						)
					);
					rm gupdir
				)
				;
				(* return all dirs that we should recurse into *)
				dirs |> ignore_hidden |> List.filter (fun dir -> not @@ List.mem dir !removed_dirs)
			)
		)
		;
		Lwt.return_unit

	let _list_targets ~var base =
		let basedir = (Option.default "." base) in
		let add_prefix = begin match base with
			| Some base -> fun file -> Filename.concat base file
			| None -> identity
		end in
		let resolved = Concrete.resolve ~cwd:var.Var.cwd basedir in
		Gupfile.buildable_files_in ~var resolved |> Enum.iter (fun f ->
			print_endline (add_prefix f)
		)

	let list_targets ~var dirs =
		if List.length dirs > 1 then
			raise_safe "Too many arguments"
		;
		let base = List.headOpt dirs in
		_list_targets ~var base;
		Lwt.return_unit

	let test_buildable ~var args =
		begin match args with
			| [target] ->
					let target = ConcreteBase.resolve ~cwd:var.Var.cwd target in
					let builder = Gupfile.find_builder ~var target in
					exit (if (Option.is_some builder) then 0 else 1)
			| _ -> raise_safe "Exactly one argument expected"
		end

	let test_dirty ~var args =
		begin match args with
			| [] -> raise_safe "At least one argument expected"
			| args ->
				let rec is_dirty path =
					let target = Builder.prepare_build ~var path in
					match target with
						| Some (`Target target) -> Builder.is_dirty ~var target
						| Some (`Symlink_to dest) -> is_dirty (ConcreteBase.resolve_relfrom dest)
						| None -> Lwt.return_false
				in
				let%lwt dirty =
					try%lwt
						let%lwt (_dirty:string) = args |> Lwt_list.find_s (fun path ->
							is_dirty (ConcreteBase.resolve ~cwd:var.Var.cwd path)
						) in
						Lwt.return_true
					with Not_found -> Lwt.return_false
				in
				exit (if dirty then 0 else 1)
		end

	let print_version ~var:_ args =
		expect_no args;
		print_endline Version.version;
		Lwt.return_unit

	let list_features ~var:_ args =
		expect_no args;
		let features = [
			"version " ^ Version.version;
			"list-targets";
			"command-completion";
		] in
		List.iter print_endline features;
		Lwt.return_unit

	let complete_args ~var args =
		let dir = List.headOpt args in

		let get_dir arg =
			try
				let (dir, _) = String.rsplit arg ~by:Filename.dir_sep in
				Some dir
			with Not_found -> None
		in

		let dir = Option.bind dir get_dir in
		_list_targets ~var dir;

		(* also add dirs, since they _may_ contain targets *)
		let root = Option.default "." dir in
		let subdirs =
			try
				let files = PathString.readdir root in
				let prefix = match dir with
					| Some p -> Filename.concat p
					| None -> identity
				in
				Array.to_list files
					|> ignore_hidden
					|> List.map PathComponent.string_of_name
					|> List.map prefix
					|> List.filter (Util.isdir)
			with Sys_error _ -> [] in
		subdirs |> List.iter (fun path -> print_endline (Filename.concat path ""));
		Lwt.return_unit

end

module Options =
struct
	open OptParse
	let update = StdOpt.store_true ()
	let jobs = StdOpt.int_option ~default:1 ()
	let trace = StdOpt.store_true ()
	let verbosity = ref Var_global.default_verbosity
	let quiet = StdOpt.decr_option   ~dest:verbosity ()
	let verbose = StdOpt.incr_option ~dest:verbosity ()
	let interactive = StdOpt.store_true ()
	let dry_run = StdOpt.store_true ()
	let keep_failed = StdOpt.store_true ()
	let force = StdOpt.store_true ()
	let metadata = StdOpt.store_true ()
	let action = ref (CmdActions.build ~update:update ~jobs:jobs ~keep_failed)
	let clean_mode () =
		match (Opt.get force, Opt.get dry_run) with
			| (true, false) -> `Force
			| (false, true) -> `DryRun
			| _ -> raise_safe "Exactly one of --force (-f) or --dry-run (-n) must be given"

	open OptParser

	let main () =
		let options = OptParser.make ~usage: (
			"Usage: gup [action] [OPTIONS] [target [...]]\n\n" ^
				"Actions: (if present, the action must be the first argument)\n" ^
				"  --clean        Clean any gup-built targets\n" ^
				"  --buildable    Check if the given file is buildable\n" ^
				"  --dirty        Check if one or more targets are out of date\n" ^
				"  --targets/-t   List buildable targets in a directory\n" ^
				"  --features     List the features of this gup version\n" ^
				"  --version      Print the gup version\n" ^
				"\n" ^
				"Actions which can only be called from a buildscript:\n" ^
				"  --always       Mark this target as always-dirty\n" ^
				"  --leave        Mark this target as fresh, preventing removal (even if the file is unchanged)\n" ^
				"  --ifcreate     Rebuild the current target if the given file(s) are created\n" ^
				"  --contents     Checksum the contents of stdin\n" ^
				"\n" ^
				"  (use gup <action> --help) for further details") () in

		add options ~short_name:'u' ~long_names:["update";"ifchange"] ~help:"Only rebuild stale targets" update;
		add options ~short_name:'j' ~long_name:"jobs" ~help:"Number of concurrent jobs to run" jobs;
		add options ~short_name:'x' ~long_name:"trace" ~help:"Trace build script invocations (also sets $GUP_XTRACE=1)" trace;
		add options ~short_name:'q' ~long_name:"quiet" ~help:"Decrease verbosity" quiet;
		add options ~short_name:'v' ~long_name:"verbose" ~help:"Increase verbosity" verbose;
		add options ~long_name:"keep-failed" ~help:"Keep temporary output files on failure" keep_failed;
		options
	;;

	let clean () =
		let options = OptParser.make ~usage: "Usage: gup --clean [OPTIONS] [dir [...]]" () in
		add options ~short_name:'i' ~long_name:"interactive" ~help:"Ask for confirmation before removing files" interactive;
		add options ~short_name:'n' ~long_name:"dry-run" ~help:"Just print files that would be removed" dry_run;
		add options ~short_name:'f' ~long_name:"force" ~help:"Actually remove files" force;
		add options ~short_name:'m' ~long_name:"metadata" ~help:"Remove .gup metadata directories, but leave targets" metadata;
		action := CmdActions.clean ~force:force ~dry_run:dry_run ~metadata:metadata ~interactive:interactive;
		options
	;;

	let ifcreate () =
		let options = OptParser.make ~usage: "Usage: gup --ifcreate [file [...]]" () in
		action := CmdActions.mark_ifcreate;
		options
	;;

	let contents () =
		let options = OptParser.make ~usage: "Usage: gup --contents [file [...]]" () in
		action := CmdActions.mark_contents;
		options
	;;

	let always () =
		let options = OptParser.make ~usage: "Usage: gup --always" () in
		action := CmdActions.mark_always;
		options
	;;

	let leave () =
		let options = OptParser.make ~usage: "Usage: gup --leave" () in
		action := CmdActions.mark_leave;
		options
	;;

	let list_targets () =
		let options = OptParser.make ~usage: "Usage: gup --targets [directory]" () in
		action := CmdActions.list_targets;
		options
	;;

	let test_buildable () =
		let options = OptParser.make ~usage: "Usage: gup --buildable <target>" () in
		action := CmdActions.test_buildable;
		options
	;;

	let test_dirty () =
		let options = OptParser.make ~usage: "Usage: gup --dirty [target [...]]" () in
		action := CmdActions.test_dirty;
		options
	;;

	let complete_args () =
		let options = OptParser.make ~usage: "Usage: gup --complete-command idx [args]" () in
		action := CmdActions.complete_args;
		options
	;;

	let list_features () =
		let options = OptParser.make ~usage: "Usage: gup --features" () in
		action := CmdActions.list_features;
		options
	;;

	let print_version () =
		let options = OptParser.make ~usage: "Usage: gup --version" () in
		action := CmdActions.print_version;
		options
	;;
end

let _init_logging verbosity =
	let lvl = ref Logging.Info in
	let fmt = ref Logging.info_formatter in

	if verbosity < 0 then
		lvl := Logging.Error
	else if verbosity = 1 then
		lvl := Logging.Debug
	else if verbosity > 1 then
		begin
			fmt := Logging.trace_formatter;
			lvl := Logging.Trace
		end;

	if Var_global.is_test_mode then
		begin
			lvl := Logging.Trace;
			fmt := Logging.test_formatter
		end;
	
	(* persist for child processes *)
	Var_global.set_verbosity verbosity;

	Logging.set_level !lvl;
	Logging.set_formatter !fmt

let main () =
	let cmd = try
		Some Sys.argv.(1)
	with Invalid_argument _ -> None in

	let firstarg = ref 2 in
	let p = match cmd with
		| Some "--clean" -> Options.clean ()
		| Some "--ifcreate" -> Options.ifcreate ()
		| Some "--contents" -> Options.contents ()
		| Some "--targets" | Some "-t" -> Options.list_targets ()
		| Some "--complete-command" -> Options.complete_args ()
		| Some "--always" -> Options.always ()
		| Some "--leave" -> Options.leave ()
		| Some "--buildable" -> Options.test_buildable ()
		| Some "--dirty" -> Options.test_dirty ()
		| Some "--features" -> Options.list_features ()
		| Some "--version" -> Options.print_version ()
		| _ -> firstarg := 1; Options.main ()
		in

	let var = Var.global () in
	try (
		let posargs = OptParse.OptParser.parse p ~first:!firstarg Sys.argv in
		_init_logging !Options.verbosity;
		Var_global.set_trace (OptParse.Opt.get Options.trace);
		Lwt_main.run (!Options.action ~var posargs)
	) with
		| Error.Unbuildable path -> (
				Log.err var (fun m -> m"Don't know how to build %s" path);
				exit_error ()
		)
		| Error.Target_failed _ -> (
				exit_error ()
		)
		| Error.Safe_exception (msg, _ctx) -> (
				(* TODO: context?*)
				Log.err var (fun m->m"%s" msg);
				exit_error ()
		)
;;
