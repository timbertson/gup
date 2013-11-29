open Batteries
open Extlib

let log = Logging.get_logger "gup.cmd"

module Actions =
struct
	let _get_parent_target () =
		let target_var = Var.get("GUP_TARGET") in
		Option.map (fun p ->
			if not @@ Utils.is_absolute p then
				raise (Invalid_argument ("relative path in $GUP_TARGET: " ^ p))
			else
				p
		) target_var
	
	let _assert_parent_target action : string =
		match _get_parent_target () with
			| None -> Common.raise_safe "%s was used outside of a gup target" action
			| Some p -> p

	let _init_path () =
		(* ensure `gup` is present on $PATH *)
		let progname = Array.get Sys.argv 0 in
		log#trace "run as: %s" progname;
		let existing_path = Var.get_or "PATH" "" in
		if String.exists progname Filename.dir_sep &&
		   (Var.get_or "GUP_IN_PATH" "0") <> "1" then (
			(* gup may have been run as a relative / absolute script - check *)
			(* whether our directory is in $PATH *)
			let bin_path = Filename.dirname @@ Utils.abspath (progname) in
			let path_entries : string list = existing_path |> String.nsplit ~by: Util.pathsep in
			let already_in_path = List.enum path_entries |> Enum.exists (
				fun entry ->
					(not @@ String.is_empty entry) &&
					Util.samefile bin_path (Utils.abspath entry)) in
			if already_in_path then
				log#trace("found `gup` in $PATH")
			else (
				log#trace "`gup` not in $PATH - adding %s" bin_path;
				Unix.putenv "PATH" @@ bin_path ^ Util.pathsep ^ existing_path
			)
		);
		Unix.putenv "GUP_IN_PATH" "1"
	
	let _report_nobuild path =
		(if Var.is_root then log#info else log#trace) "%s: up to date" path

	let build update posargs =
		_init_path ();

		let parent_target = _get_parent_target () in
		let build_target (path:string) : unit =
			Option.may (fun parent ->
				if Util.samefile (Utils.abspath path) parent then
					raise (Invalid_argument ("Target "^path^" attempted to build itself"));
			) parent_target;

			let target : Builder.target option = (Builder.prepare_build path) in
			match target with
				| None -> (
					if OptParse.Opt.get update && (Sys.file_exists path) then
						_report_nobuild path
					else
						raise (Error.Unbuildable path)
				)
				| Some t -> ignore @@ t#build true
			;
			(* add dependency to parent *)
			parent_target |> Option.may (fun parent_path ->
				let mtime = Util.get_mtime path in
				let checksum = Option.bind target (fun target ->
					Option.bind (new State.target_state parent_path)#deps (fun deps -> deps#checksum)
				) in

				let parent_state = (new State.target_state parent_path) in
				parent_state#add_file_dependency ~checksum:checksum ~mtime:mtime path
			)
		in
		posargs |> List.iter build_target
	
	let clean posargs = failwith "TODO"

	let mark_ifcreate files =
		if List.length files < 1 then Common.raise_safe "at least one file expected";
		let parent_target = _assert_parent_target "--ifcreate" in
		let parent_state = new State.target_state parent_target in
		List.enum files |> Enum.iter (fun filename ->
			if Sys.file_exists filename then
				Common.raise_safe "File already exists: %s" filename
			;
			parent_state#add_file_dependency ~mtime:None ~checksum:None filename
		)
	
	let mark_contents targets =
		let parent_target = _assert_parent_target "--contents" in
		let checksum =
			if List.length targets = 0 then (
				if (Unix.isatty Unix.stdin) then Common.raise_safe "stdin is a TTY";
				Checksum.from_stream IO.stdin
			) else (
				Checksum.from_files targets
			)
		in
		(new State.target_state parent_target)#add_checksum checksum

	let mark_always args =
		if List.length args > 0 then Common.raise_safe "no arguments expected";
		let parent_target = _assert_parent_target "--always" in
		(new State.target_state parent_target)#mark_always_rebuild
end

module Options =
struct
	open OptParse
	let update = StdOpt.store_true ()
	let jobs = StdOpt.int_option ~default:1 ()
	let trace = StdOpt.store_true ()
	let verbosity = ref Var.default_verbosity
	let quiet = StdOpt.decr_option   ~dest:verbosity ()
	let verbose = StdOpt.incr_option ~dest:verbosity ()
	let interactive = StdOpt.store_true ()
	let dry_run = StdOpt.store_true ()
	let force = StdOpt.store_true ()
	let metadata = StdOpt.store_true ()
	let action = ref (Actions.build update)
	let clean_mode () =
		match (Opt.get force, Opt.get dry_run) with
			| (true, false) -> `Force
			| (false, true) -> `DryRun
			| _ -> raise (Invalid_argument "Exactly one of --force (-f) or --dry-run (-n) must be given")

	open OptParser

	let main () =
		let options = OptParser.make ~usage: (
			"Usage: gup [action] [OPTIONS] [target [...]]\n\n" ^
				"actions: (if present, the action must be the first argument)\n\n" ^
				"  --always     Mark this target as always-dirty\n" ^
				"  --ifcreate   Rebuild the current target if the given file(s) are created\n" ^
				"  --contents   Checksum the contents of stdin\n" ^
				"  --clean      Clean any gup-built targets\n" ^
				"  (use gup <action> --help) for further details") () in

		add options ~short_name:'u' ~long_names:["update";"ifchange"] ~help:"Only rebuild stale targets" update;
		add options ~short_name:'j' ~long_name:"jobs" ~help:"Number of concurrent jobs to run" jobs;
		add options ~short_name:'x' ~long_name:"trace" ~help:"Trace build script invocations (also sets $GUP_XTRACE=1)" trace;
		add options ~short_name:'q' ~long_name:"quiet" ~help:"Decrease verbosity" quiet;
		add options ~short_name:'v' ~long_name:"verbose" ~help:"Increase verbosity" verbose;
		options
	;;

	let clean () =
		let options = OptParser.make ~usage: "Usage: gup --clean [OPTIONS] [dir [...]]" () in
		add options ~short_name:'i' ~long_name:"interactive" ~help:"Ask for confirmation before removing files" interactive;
		add options ~short_name:'n' ~long_name:"dry-run" ~help:"Just print files that would be removed" dry_run;
		add options ~short_name:'f' ~long_name:"force" ~help:"Actually remove files" force;
		add options ~short_name:'m' ~long_name:"metadata" ~help:"Remove .gup metadata directories, but leave targets" metadata;
		action := Actions.clean;
		options
	;;

	let ifcreate () =
		let options = OptParser.make ~usage: "Usage: gup --ifcreate [file [...]]" () in
		action := Actions.mark_ifcreate;
		options
	;;

	let contents () =
		let options = OptParser.make ~usage: "Usage: gup --contents [file [...]]" () in
		action := Actions.mark_contents;
		options
	;;

	let always () =
		let options = OptParser.make ~usage: "Usage: gup --always" () in
		action := Actions.mark_always;
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

	if Var.has_env "GUP_IN_TESTS" then
		begin
			lvl := Logging.Trace;
			fmt := Logging.test_formatter
		end;
	
	(* persist for child processes *)
	Var.set_verbosity verbosity;

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
		| Some "--always" -> Options.always ()
		| _ -> firstarg := 1; Options.main ()
		in

	try (
		let posargs = OptParse.OptParser.parse p ~first:!firstarg Sys.argv in

		_init_logging !Options.verbosity;

		!Options.action posargs
	) with
		| Error.Unbuildable path -> (
				log#error "Don't know how to build %s" path;
				exit 1
		)
		| Common.Safe_exception (msg, ctx) -> (
				(* TODO: context?*)
				log#error "%s" msg;
				exit 1
		)
;;
