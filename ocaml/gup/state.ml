open Std
open Lwt
open Path
open CCFun

type dirty_args = {
	var: Var.t;
	path: ConcreteBase.t;
	builder_path: RelativeFrom.t;
	build: (RelativeFrom.t -> bool Lwt.t)
}

let builds_have_been_cancelled = ref false
let cancel_all_future_builds () = builds_have_been_cancelled := true

exception Version_mismatch of string
exception Invalid_dependency_file

(* lwt wrappers for with_file_in and with_file_out *)
let with_file_in path fn =
	let flags = [Unix.O_CLOEXEC; Unix.O_RDONLY] in
	Lwt_io.with_file ~flags:flags ~mode:Lwt_io.input path fn

let with_file_out ?(flags) path fn =
	let default_flags = [Unix.O_CLOEXEC; Unix.O_WRONLY; Unix.O_CREAT] in
	let flags = match flags with
		| Some f -> List.concat [default_flags; f]
		| None -> default_flags
	in
	Lwt_io.with_file ~flags:flags ~mode:Lwt_io.output path fn

type dependency_type =
	| FileDependency
	| Checksum
	| RunId
	| Builder
	| BuildTime
	| AlwaysRebuild
	| ClobbersTarget

module Log = (val Var.log_module "gup.state")
let meta_dir_name = PathComponent.name_of_string ".gup"
let deps_ext = "deps"
let new_deps_ext = "deps2"

let empty_field = "-"
let format_version = 3
let version_marker = "version: "

(* exceptionless helpers *)
let readline f =
	try%lwt
		let%lwt line = Lwt_io.read_line f in
		Lwt.return @@ Some line
	with End_of_file -> Lwt.return None

let built_targets dir =
	let contents = Sys.readdir dir in
	contents |> CCArray.filter_map (fun f ->
		if CCString.prefix ~pre:(deps_ext ^ ".") f
			then (CCString.Split.left ~by:"." f) |> CCOpt.map (PathComponent.name_of_string % snd)
			else None
	) |> Array.to_list

let resolve_builder_path ~(target:ConcreteBase.t) (path:Absolute.t) : RelativeFrom.t =
	let newbase = ConcreteBase.dirname target in
	Concrete.resolve_abs path |> ConcreteBase.of_concrete |> ConcreteBase.rebase_to newbase

class run_id id =
	object
		method is_current = id = Var.run_id
		method repr = "run_id(" ^ id ^ ")"
		method fields = [id]
		method tag = RunId
		method print out = CCFormat.(within "run_id(" ")" string out id)
	end

let current_run_id = new run_id Var.run_id

type 'a intermediate_dependencies = {
	checksum: string option ref;
	run_id: run_id option ref;
	clobbers: bool ref;
	rules: 'a list ref;
}

type dependency_class = {
	tag: dependency_type;
	num_fields: int;
}


let string_of_dependency_type = function
	| Checksum -> "checksum"
	| RunId -> "run"
	| FileDependency -> "file"
	| BuildTime -> "built"
	| Builder -> "builder"
	| AlwaysRebuild -> "always"
	| ClobbersTarget -> "clobbers"


let serializable_dependencies = [
	{ tag = FileDependency; num_fields = 3; };
	{ tag = RunId; num_fields = 1; };
	{ tag = Checksum; num_fields = 1; };
	{ tag = BuildTime; num_fields = 1; };
	{ tag = Builder; num_fields = 3; };
	{ tag = AlwaysRebuild; num_fields = 0; };
	{ tag = ClobbersTarget; num_fields = 0; };
]

let tag_assoc     = serializable_dependencies |> List.map (fun dep -> (dep.tag, dep))
let tag_assoc_str = tag_assoc |> List.map (fun (tag, dep) -> (string_of_dependency_type tag, dep))

let serializable dep = (dep#tag, dep#fields)

let write_dependency output (tag,fields) =
	let (_, typ) = List.find (fun (t, _) -> t = tag) tag_assoc in
	if List.length fields <> typ.num_fields then Error.raise_safe "invalid fields";
	Lwt_io.write_line output @@ (string_of_dependency_type tag) ^ ": " ^ (String.concat " " fields)

type dep_dirty_state = [ `clean | `dirty | `clean_after_build ]
let dirty_of_dep_state : dep_dirty_state -> bool = function
	| `dirty -> true
	| `clean | `clean_after_build -> false

let dirty_check_with_dep ~(path:RelativeFrom.t) checker args =
	let%lwt dirty = checker args in
	if dirty then Lwt.return `dirty else (
		let%lwt built = args.build path in
		if built
			then (
				Log.trace args.var (fun m->m "dirty_check_with_dep: path %s was built, rechecking" (RelativeFrom.to_string path));
				checker args |> Lwt.map (function
					| true -> `dirty
					| false -> `clean_after_build
				)
			) else Lwt.return `clean
	)

let is_mtime_mismatch ~var ~stored path =
	let%lwt current_mtime = (RelativeFrom.lift Util.get_mtime) path in
	Log.trace var PP.(fun m->m "%s: comparing stored mtime %a against current %a"
		(RelativeFrom.to_string path)
		(option Util.big_int_pp) stored
		(option Util.big_int_pp) current_mtime);
	Lwt.return @@ not @@ eq (CCOpt.compare Big_int.compare_big_int) stored current_mtime

let file_fields ~mtime ~checksum path =
	let mtime_str = CCOpt.get_or ~default:empty_field (CCOpt.map Big_int.string_of_big_int mtime) in
	let checksum_str = CCOpt.get_or ~default:empty_field checksum in
	[mtime_str; checksum_str; RelativeFrom.to_field path]

class virtual base_dependency = object (self)
	method virtual tag : dependency_type
	method virtual fields : string list
	method virtual is_dirty : dirty_args -> bool Lwt.t

	method print out =
		Format.fprintf out "<#%s: %a>"
			(string_of_dependency_type self#tag)
			PP.(list string) self#fields
end

and file_dependency ~(mtime:Big_int.big_int option) ~(checksum:string option) (path:RelativeFrom.t) =
	object (self)
		inherit base_dependency
		method tag = FileDependency
		method fields = file_fields ~mtime ~checksum path

		method private mtime = mtime
		method private is_dirty_cs checksum args =
			(* checksum-based check *)
			Log.trace args.var (fun m->m "%s: comparing using checksum %s" (RelativeFrom.to_string path) checksum);
			let resolved_path = ConcreteBase.resolve_relfrom path in
			let state = new target_state ~var:args.var resolved_path in
			let checksum_mismatch args =
				let%lwt deps = state#deps in
				let latest_checksum = CCOpt.flat_map (fun deps -> deps#checksum) deps in
				let dirty = match latest_checksum with
					| None -> true
					| Some dep_cs -> dep_cs <> checksum
				in
				Log.debug args.var PP.(fun m->m "%s: %s (stored checksum is %s, current is %a)"
					(if dirty then "DIRTY" else "CLEAN")
					(ConcreteBase.to_string resolved_path) checksum
					(option string) latest_checksum);
				Lwt.return dirty
			in
			dirty_check_with_dep ~path checksum_mismatch args |> Lwt.map dirty_of_dep_state

		method private is_dirty_mtime = dirty_check_with_dep ~path (fun args ->
			is_mtime_mismatch ~var:args.var ~stored:self#mtime path
		)

		method is_dirty args =
			let%lwt mtime_dirty = self#is_dirty_mtime args in
			match mtime_dirty with
				| `clean -> Lwt.return_false
				| `dirty | `clean_after_build -> (
					(* if mtime is unchanged after a build, try checksum anyway *)
					match checksum with
						| Some checksum -> self#is_dirty_cs checksum args
						| None -> Lwt.return (dirty_of_dep_state mtime_dirty)
				)
	end

and builder_dependency ~mtime (path:RelativeFrom.t) =
	object
		inherit base_dependency
		method tag = Builder
		method fields = file_fields ~mtime ~checksum:None path
		method is_dirty args =
			let relative_path = path |> RelativeFrom.relative in
			let builder_path = args.builder_path |> RelativeFrom.relative in
			if not (Relative.eq builder_path relative_path) then (
				Log.debug args.var (fun m->m "DIRTY: builder changed from %s -> %s"
					(Relative.to_string relative_path)
					(Relative.to_string builder_path));
				Lwt.return_true
			) else is_mtime_mismatch ~var:args.var ~stored:mtime path
	end

and always_rebuild =
	object
		inherit base_dependency
		method tag = AlwaysRebuild
		method fields = []
		method is_dirty (_:dirty_args) = Lwt.return_true
	end

and build_time time =
	object
		inherit base_dependency
		method tag = BuildTime
		method fields = [Big_int.string_of_big_int time]
		method is_dirty args =
			let path = args.path |> ConcreteBase.to_string in
			let%lwt mtime = Util.get_mtime path >>= (return $ CCOpt.get_exn) in
			Lwt.return (
				if neq Big_int.compare_big_int mtime time then (
					Log.debug args.var (fun m->m "%s mtime (%a) differs from build time (%a)" path
						Util.big_int_pp mtime
						Util.big_int_pp time);
					let log_method = ref Log.warn in
					if Util.lisdir path then
						(* dirs are modified externally for various reasons, not worth warning *)
						log_method := Log.debug
					;
					!log_method args.var (fun m->m"%s was externally modified - rebuilding" path);
					true
				)
				else false
			)
	end

and dependencies (target_path:ConcreteBase.t) (data:base_dependency intermediate_dependencies) =
	object
		method already_built = match !(data.run_id) with
			| None -> false
			| Some r -> r#is_current

		method print out =
			let open PP in
			Format.fprintf out "<#Dependencies(run=%a, cs=%a, clobbers=%b, rules=%a)>"
				(option print_obj) !(data.run_id)
				(option string) !(data.checksum)
				!(data.clobbers)
				(list print_obj) !(data.rules)

		method checksum = !(data.checksum)

		method clobbers = !(data.clobbers)

		method is_dirty ~var (buildable: Buildable.t) (build:RelativeFrom.t -> bool Lwt.t) : bool Lwt.t =
			let target_path_str = ConcreteBase.to_string target_path in
			if not (Util.lexists target_path_str) then (
				Log.debug var (fun m->m "DIRTY: %s (target does not exist)" target_path_str);
				return true
			) else (
				let script_path = Buildable.script buildable in
				let args = {
					var;
					path = target_path;
					builder_path = resolve_builder_path ~target:target_path script_path;
					build = build
				} in

				let rec iter rules =
					match rules with
					| [] ->
							Log.trace var (fun m->m "dependencies#is_dirty: %s returning false" target_path_str);
							Lwt.return_false
					| (rule::remaining_rules) ->
						Log.trace var (fun m->m "dependencies#is_dirty checking %a for path %s" print_obj rule target_path_str);
						let%lwt dirty = rule#is_dirty args in
						if dirty then (
							Log.trace var (fun m->m "dependencies#is_dirty: %s returning true" target_path_str);
							Lwt.return_true
						) else iter remaining_rules
				in
				iter !(data.rules)
			)
end

and dependency_builder ~var target_path (input:Lwt_io.input_channel) = object
	(* extracted into its own object because we can't use lwt in an object consutrctor
	 * syntax *)
	method build =
		let basedir = ConcreteBase.dirname target_path in
		let update_singleton r v =
			assert (CCOpt.is_none !r);
			r := v;
			None
		in

		let parse_line line : (dependency_class * string list) =
			let (typ, content) = CCString.Split.left line ~by:":" |> CCOpt.flat_map (fun (tag, content) ->
				CCList.find_opt (fun (prefix, _typ) -> prefix = tag) tag_assoc_str
					|> CCOpt.map (fun (_, typ) -> (typ, content))
			) |> CCOpt.get_lazy (fun () -> Error.raise_safe "invalid dep line: %s" line)
			in
			let fields = Str.bounded_split (Str.regexp " ") (CCString.ltrim content) typ.num_fields in
			(typ, fields)
		in

		let _parse input rv =
			let process_line line : base_dependency option =
				let typ, fields = parse_line (String.trim line) in
				let parse_cs cs = if cs = empty_field then None else Some cs in
				let parse_mtime mtime = if mtime = empty_field then None else Some (Big_int.big_int_of_string mtime) in
				match (typ.tag, fields) with
					| (Checksum, [cs])      -> update_singleton rv.checksum (Some cs)
					| (RunId, [r])          -> update_singleton rv.run_id (Some (new run_id r))
					| (ClobbersTarget, [])  -> (rv.clobbers := true; None)
					| (FileDependency, [mtime; cs; path]) ->
							Some (new file_dependency
								~mtime:(parse_mtime mtime)
								~checksum:(parse_cs cs)
								(RelativeFrom.of_field ~basedir path)
							)
					| (Builder, [mtime; _cs; path;]) ->
							Some (new builder_dependency
								~mtime:(parse_mtime mtime)
								(RelativeFrom.of_field ~basedir path))
					| (BuildTime, [time]) -> Some (new build_time (Big_int.big_int_of_string time))
					| (AlwaysRebuild, []) -> Some (new always_rebuild)
					| _ -> Error.raise_safe "Invalid dependency line: %s" line
			in
			let%lwt rules = Lwt_io.read_lines input
				|> Lwt_stream.filter_map process_line
				|> Lwt_stream.to_list
			in
			rv.rules := rules;
			Lwt.return rv
		in

		let%lwt (data : base_dependency intermediate_dependencies) =
			let rv = {
				checksum = ref None;
				run_id = ref None;
				clobbers = ref false;
				rules = ref [];
			} in
			let%lwt version_line = readline input in
			Log.trace var PP.(fun m->m "version_line: %a" (option string) version_line);
			let version_number = version_line |> CCOpt.flat_map (fun line ->
				if CCString.prefix ~pre:version_marker line then (
					CCString.Split.left line ~by:" " |> CCOpt.flat_map (CCInt.of_string % snd)
				) else None
			) in
			match version_number with
				| None -> raise Invalid_dependency_file
				| Some v ->
					if v <> format_version then
						raise @@ Version_mismatch ("can't read format version: " ^ (string_of_int v))
			;
			_parse input rv
		in

		Lwt.return @@ new dependencies target_path data
	end

and target_state ~var (target_path:ConcreteBase.t) =
	let base_path = ConcreteBase.dirname target_path in
	let meta_path ext =
		let target = ConcreteBase.basename target_path |> PathComponent.string_of_name_opt in
		let meta_dir = Absolute.concat (Concrete.absolute base_path) (meta_dir_name |> PathComponent.relative_of_name) in
		Absolute.concat meta_dir (Relative.of_string (ext ^ "." ^ target))
	in

	let ensure_meta_path ext =
		let p = meta_path ext in
		Absolute.lift (Util.makedirs) (Absolute.dirname p);
		p
	in

	let lock_for_ext ext = new Parallel.lock_file ~var
		~target:(ensure_meta_path ext |> Absolute.to_string)
		(meta_path (ext ^ "-lock") |> Absolute.to_string)
	in
	let deps_lock = lazy (lock_for_ext deps_ext) in
	let new_deps_lock = lazy (lock_for_ext new_deps_ext) in

	object (self)
		method meta_path ext = meta_path ext

		method path_repr = target_path |> ConcreteBase.to_string
		
		method repr =
			"TargetState(" ^ (self#path_repr) ^ ")"

		method private parse_dependencies : dependencies option Lwt.t =
			Log.trace var (fun m->m "parse_deps %s" (target_path |> ConcreteBase.to_string));
			let deps_path = self#meta_path deps_ext in
			if Absolute.lexists deps_path then (
				try%lwt
					(Lazy.force deps_lock)#use Parallel.ReadLock (fun deps_path ->
						with_file_in deps_path (fun f ->
							(new dependency_builder ~var target_path f)#build >>= (fun d -> Lwt.return (Some d))
						)
					)
				with
					| Version_mismatch _ -> (
						Log.warn var (fun m->m "Ignoring stored dependencies from incompatible version: %s"
							(Absolute.to_string deps_path));
						Lwt.return None
					)
					| Invalid_dependency_file -> (
						Log.warn var (fun m->m "Ignoring invalid stored dependencies: %s"
							(Absolute.to_string deps_path));
						Lwt.return None
					)
					| e -> (
						Log.warn var (fun m->m "Error loading %s: %s (assuming dirty)"
							(Absolute.to_string deps_path) (Printexc.to_string e));
						Lwt.return None
					)
			) else
				Lwt.return None

		method deps =
			let%lwt deps = self#parse_dependencies in
			Log.trace var PP.(fun m->m "Loaded serialized state: %a" (option print_obj) deps);
			Lwt.return deps

		method private with_dependency_lock fn : unit Lwt.t =
			(Lazy.force new_deps_lock)#use Parallel.WriteLock (fun out_filename ->
				with_file_out ~flags:[Unix.O_APPEND] out_filename fn
			)

		method private add_dependency dep : unit Lwt.t =
			self#with_dependency_lock (fun output -> write_dependency output dep)

		method private add_dependencies deps : unit Lwt.t =
			self#with_dependency_lock (fun output -> deps |> Lwt_list.iter_s (write_dependency output))

		method mark_clobbers =
			self#add_dependency (ClobbersTarget, [])

		method private file_dependency_with ~(mtime:Big_int.big_int option) ~(checksum:string option) path =
			let path = ConcreteBase.rebase_to base_path path in
			let dep = (new file_dependency ~mtime:mtime ~checksum:checksum path) in
			Log.trace var (fun m->m "Adding dependency %s -> %a"
				(ConcreteBase.basename target_path |> PathComponent.string_of_name_opt)
				print_obj dep);
			serializable dep

		method add_file_dependency_with ~(mtime:Big_int.big_int option) ~(checksum:string option) path =
			self#add_dependency (self#file_dependency_with ~mtime ~checksum path)

		method add_file_dependency path =
			let%lwt mtime = Util.get_mtime (ConcreteBase.to_string path) in
			self#add_file_dependency_with ~mtime ~checksum:None path

		method add_file_dependencies paths =
			let%lwt deps = Lwt_list.map_p (fun path ->
				let%lwt mtime = ConcreteBase.lift Util.get_mtime path in
				Lwt.return (self#file_dependency_with ~mtime ~checksum:None path)
			) paths in
			self#add_dependencies deps

		method add_checksum checksum =
			self#add_dependency (Checksum, [checksum])

		method mark_always_rebuild =
			self#add_dependency (serializable (new always_rebuild))

		method private builder_dependency path =
			let%lwt builder_mtime = (Absolute.lift Util.get_mtime) path in
			return (new builder_dependency
				~mtime:builder_mtime
				(resolve_builder_path ~target:target_path path)
			)

		method perform_build (buildable:Buildable.t) block : bool Lwt.t =
			let exe = Buildable.script buildable in
			assert (Sys.file_exists (Absolute.to_string exe));
			Log.trace var (fun m->m "perform_build %s" (ConcreteBase.to_string target_path));

			(* TODO: quicker mtime-based check *)
			let still_needs_build = (fun deps ->
				Log.trace var (fun m->m "Checking if %s still needs build after releasing lock"
					(ConcreteBase.to_string target_path));
				match deps with
					| Some d -> not d#already_built
					| None -> true
			) in

			let build = (fun deps_path ->
				if (!builds_have_been_cancelled) then raise Error.BuildCancelled;
				let%lwt deps = self#deps in
				if still_needs_build deps then (
					let%lwt builder_dep = self#builder_dependency exe in
					let temp = ensure_meta_path new_deps_ext |> Absolute.to_string in
					with_file_out temp (fun file ->
						Lwt_io.write_line file (version_marker ^ (string_of_int format_version)) >>= fun () ->
						(* TODO: make Dependencies module to store init stuff *)
						write_dependency file (serializable builder_dep) >>= fun () ->
						write_dependency file (serializable current_run_id)
					) >>= fun () ->
					let%lwt built = try%lwt
						block deps
					with ex ->
						let%lwt () = Lwt_unix.unlink temp in
						raise ex
					in
					let%lwt () = if built then (
						let%lwt mtime = (ConcreteBase.lift Util.get_mtime) target_path in
						mtime |> Lwt_option.may (fun time ->
							with_file_out ~flags:[Unix.O_APPEND] temp (fun output ->
								let timedep = new build_time time in
								write_dependency output (serializable timedep)
							)
						) >>= fun () ->
						Lwt_unix.rename temp deps_path
					) else return_unit in
					return built
				) else Lwt.return false
			) in

			let%lwt built = (Lazy.force deps_lock)#use Parallel.WriteLock build in
			return built
	end

let of_buildable ~var b = new target_state ~var (Buildable.target_path b)
