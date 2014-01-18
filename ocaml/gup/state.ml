open Batteries
open Std
open Lwt
open Parallel

(* TODO: a bunch of type definitions are needlessly paramaterised,
 * just to avoid forward type definitions which ocaml
 * doesn't support. There should be a better way of structuring
 * this though.
 *)

type 'a dirty_result =
	| Known of bool
	| Unknown of 'a

type dirty_args = {
	path:string;
	base_path:string;
	builder_path:string;
	built:bool;
}

exception Version_mismatch of string

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

let log = Logging.get_logger "gup.state"
let meta_dir_name = ".gup"
let deps_ext = "deps"
let new_deps_ext = "deps2"

let empty_field = "-"
let format_version = 2
let version_marker = "version: "

(* exceptionless helpers *)
let readline f =
	try_lwt
		lwt line = Lwt_io.read_line f in
		Lwt.return @@ Some line
	with End_of_file -> Lwt.return None

let int_option_of_string s = try Some (Int.of_string s) with Invalid_argument _ -> None

let built_targets dir =
	let contents = Sys.readdir dir in
	contents |> Array.filter_map (fun f ->
		if String.ends_with f ("." ^ deps_ext)
			then Some (Tuple.Tuple2.first (String.rsplit f "."))
			else None
	) |> Array.to_list

class run_id id =
	object (self)
		method is_current = id = Var.run_id
		method repr = "run_id(" ^ id ^ ")"
		method fields = [id]
		method tag = RunId
		method print (out: unit IO.output) =
			Printf.fprintf out "run_id(%s)" id
	end

let current_run_id = new run_id Var.run_id
 
type 'a intermediate_dependencies = {
	checksum: string option ref;
	run_id: run_id option ref;
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


let serializable_dependencies = [
	{ tag = FileDependency; num_fields = 3; };
	{ tag = RunId; num_fields = 1; };
	{ tag = Checksum; num_fields = 1; };
	{ tag = BuildTime; num_fields = 1; };
	{ tag = Builder; num_fields = 3; };
	{ tag = AlwaysRebuild; num_fields = 0; };
]

let tag_assoc     = serializable_dependencies |> List.map (fun dep -> (dep.tag, dep))
let tag_assoc_str = tag_assoc |> List.map (fun (tag, dep) -> (string_of_dependency_type tag, dep))

let serializable dep = (dep#tag, dep#fields)

let write_dependency output (tag,fields) =
	let (_, typ) = List.find (fun (t, _) -> t = tag) tag_assoc in
	if List.length fields <> typ.num_fields then Error.raise_safe "invalid fields";
	Lwt_io.write_line output @@ (string_of_dependency_type tag) ^ ": " ^ (String.join " " fields)

class virtual base_dependency = object (self)
	method virtual tag : dependency_type
	method virtual fields : string list
	method virtual is_dirty : dirty_args -> target_state dirty_result Lwt.t

	method child : string option = None
	method print out =
		Printf.fprintf out "<#%s: %a>"
			(string_of_dependency_type self#tag)
			(List.print String.print_quoted) self#fields
end

and file_dependency ~(mtime:Big_int.t option) ~(checksum:string option) (path:string) =
	object (self)
		inherit base_dependency
		method tag = FileDependency
		method child = Some path
		method fields =
			let mtime_str = Option.default empty_field (Option.map Big_int.to_string mtime) in
			let checksum_str = Option.default empty_field checksum in
			[mtime_str; checksum_str; path]

		method private path = path
		method private mtime = mtime
		method private is_dirty_cs full_path checksum args =
			(* checksum-based check *)
			log#trace "%s: comparing using checksum" self#path;
			let state = new target_state full_path in
			lwt deps = state#deps in
			let latest_checksum = Option.bind deps (fun deps -> deps#checksum) in
			let checksum_matches = match latest_checksum with
				| None -> false
				| Some dep_cs -> dep_cs = checksum
			in
			if not checksum_matches then (
				log#debug "DIRTY: %s (stored checksum is %s, current is %a)"
					self#path checksum (Option.print String.print) latest_checksum;
				Lwt.return @@ Known true)
			else (
				if args.built then
					Lwt.return @@ Known false
				else (
					log#trace "%s: might be dirty - returning %a"
						self#path
						print_repr state;
					Lwt.return @@ Unknown (state :> target_state)
				)
			)

		method private is_dirty_mtime full_path =
			(* pure mtime-based check *)
			lwt current_mtime = Util.get_mtime full_path in
			Lwt.return @@ if not @@ eq (Option.compare ~cmp:Big_int.compare) current_mtime self#mtime then (
				log#debug "DIRTY: %s (stored mtime is %a, current is %a)"
					self#path
					Util.print_mtime self#mtime
					Util.print_mtime current_mtime;
				Known true
			) else Known false

		method is_dirty args =
			let full_path = self#full_path args.base_path in
			match checksum with
				| Some checksum -> self#is_dirty_cs full_path checksum args
				| None -> self#is_dirty_mtime full_path

		method private full_path base =
			Filename.concat base self#path
	end

and builder_dependency ~mtime ~checksum path =
	object (self)
		inherit file_dependency ~mtime ~checksum path as super
		method child : string option = None
		method tag = Builder
		method is_dirty args =
			let builder_path = args.builder_path in
			assert (not @@ Util.is_absolute builder_path);
			assert (not @@ Util.is_absolute path);
			if builder_path <> path then (
				log#debug "DIRTY: builder changed from %s -> %s" path builder_path;
				Lwt.return (Known true)
			) else super#is_dirty args
	end

and always_rebuild =
	object (self)
		inherit base_dependency
		method tag = AlwaysRebuild
		method fields = []
		method is_dirty (_:dirty_args) = Lwt.return (Known true)
	end

and build_time time =
	object (self)
		inherit base_dependency
		method tag = BuildTime
		method fields = [Big_int.to_string time]
		method is_dirty args =
			let path = args.path in
			lwt mtime = Util.get_mtime path >>= (return $ Option.get) in
			Lwt.return @@ Known (
				if neq Big_int.compare mtime time then (
					let log_method = ref log#warn in
					if Sys.is_directory path then
						(* dirs are modified externally for various reasons, not worth warning *)
						log_method := log#debug
					;
					!log_method "%s was externally modified - rebuilding" path;
					true
				)
				else false
			)
	end

and dependencies target_path (data:base_dependency intermediate_dependencies) =
	object (self)
		method already_built = match !(data.run_id) with
			| None -> false
			| Some r -> r#is_current

		method children : string list = !(data.rules) |> List.filter_map (fun dep ->
			dep#child
		)

		method print out =
			Printf.fprintf out "<#Dependencies(run=%a, cs=%a, rules=%a)>"
				(Option.print print_obj) !(data.run_id)
				(Option.print String.print) !(data.checksum)
				(List.print print_obj) !(data.rules)

		method is_dirty (buildscript: Gupfile.buildscript) (built:bool) : (target_state list) dirty_result Lwt.t =
			if not (Sys.file_exists target_path) then (
				log#debug "DIRTY: %s (target does not exist)" target_path;
				return (Known true)
			) else (
				let base_path = Filename.dirname target_path in
				let args = {
					path = target_path;
					base_path = base_path;
					builder_path = Util.relpath ~from:base_path buildscript#path;
					built = built
				} in

				let rec collapse rules unknown_states =
					match rules with
					| [] -> (
						(* no more rules to consider; final return *)
						match unknown_states with
						| [] ->
							log#trace "is_dirty: %s returning false" target_path;
							return @@ Known false
						| _ ->
							log#trace "is_dirty: %s returning %a" target_path (List.print print_repr) unknown_states;
							return @@ Unknown (unknown_states)
					)
					| (rule::remaining_rules) ->
						lwt state = rule#is_dirty args in
						match state with
						| Known true -> (
							log#trace "is_dirty: %s returning true" target_path;
							return (Known true)
						)
						| Known false   -> collapse remaining_rules unknown_states
						| Unknown state -> collapse remaining_rules (state :: unknown_states)
				in
				collapse !(data.rules) []
			)

		method checksum = !(data.checksum)
end

and dependency_builder target_path (input:Lwt_io.input_channel) = object (self)
	(* extracted into its own object because we can't use lwt in an object consutrctor
	 * syntax *)
	method build =
		let update_singleton r v =
			assert (Option.is_none !r);
			r := v;
			None
		in

		let parse_line line : (dependency_class * string list) =
			let tag, content = String.split line ":" in
			let (_, typ) =
				try List.find (fun (prefix, typ) -> prefix = tag) tag_assoc_str
				with Not_found -> Error.raise_safe "invalid dep line: %s" line
			in
			let fields = Str.bounded_split (Str.regexp " ") (String.lchop content) typ.num_fields in
			(typ, fields)
		in

		let _parse input rv =
			let process_line line : base_dependency option =
				let typ, fields = parse_line (String.strip line) in
				let parse_cs cs = if cs = empty_field then None else Some cs in
				let parse_mtime mtime = if mtime = empty_field then None else Some (Big_int.of_string mtime) in
				match (typ.tag, fields) with
					| (Checksum, [cs]) -> update_singleton rv.checksum (Some cs)
					| (RunId, [r])     -> update_singleton rv.run_id (Some (new run_id r))
					| (FileDependency, [mtime; cs; path]) ->
							Some (new file_dependency
								~mtime:(parse_mtime mtime)
								~checksum:(parse_cs cs)
								path)
					| (Builder, [mtime; cs; path;]) ->
							Some (new builder_dependency
								~mtime:(parse_mtime mtime)
								~checksum:(parse_cs cs)
								path)
					| (BuildTime, [time]) -> Some (new build_time (Big_int.of_string time))
					| (AlwaysRebuild, []) -> Some (new always_rebuild)
					| _ -> Error.raise_safe "Invalid dependency line: %s" line
			in
			lwt rules = Lwt_io.read_lines input
				|> Lwt_stream.filter_map process_line
				|> Lwt_stream.to_list
			in
			rv.rules := rules;
			Lwt.return rv
		in

		lwt (data : base_dependency intermediate_dependencies) =
			let rv = {
				checksum = ref None;
				run_id = ref None;
				rules = ref [];
			} in
			lwt version_line = readline input in
			log#trace "version_line: %a" (Option.print String.print) version_line;
			let version_number = Option.bind version_line (fun line ->
				if String.starts_with line version_marker then (
					let (_, version_string) = String.split line " " in
					int_option_of_string version_string
				) else None
			) in
			match version_number with
				| None -> Error.raise_safe "Invalid dependency file"
				| Some v ->
					if v <> format_version then
						raise @@ Version_mismatch ("can't read format version: " ^ (string_of_int v))
			;
			_parse input rv
		in

		Lwt.return @@ new dependencies target_path data
	end

and target_state (target_path:string) =

	object (self)
		method private ensure_meta_path ext =
			let p = self#meta_path ext in
			Util.makedirs (Filename.dirname p);
			p

		method meta_path ext =
			let base = Filename.dirname target_path in
			let target = Filename.basename target_path in
			let meta_dir = Filename.concat base meta_dir_name in
			Filename.concat meta_dir (target ^ "." ^ ext)

		method path = target_path
		
		method repr =
			"TargetState(" ^ target_path ^ ")"

		method private locked_meta_path : 'a. Parallel.lock_mode -> string -> (string -> 'a Lwt.t) -> 'a Lwt.t
		= fun mode ext f ->
			let path = self#meta_path ext in
			let lock_path = self#ensure_meta_path (ext^".lock") in
			Parallel.with_lock mode lock_path (fun () -> f path)

		method private parse_dependencies : dependencies option Lwt.t =
			log#trace "parse_deps %s" self#path;
			let deps_path = self#meta_path deps_ext in
			if Sys.file_exists deps_path then (
				try_lwt
					self#locked_meta_path Parallel.ReadLock deps_ext (fun deps_path ->
						with_file_in deps_path (fun f ->
							(new dependency_builder target_path f)#build >>= (fun d -> Lwt.return (Some d))
						)
					)
				with Version_mismatch _ -> (
					log#debug "dep file is a previous version: %s" deps_path;
					Lwt.return None)
			) else
				Lwt.return None

		method deps =
			lwt deps = self#parse_dependencies in
			log#trace "Loaded serialized state: %a" (Option.print print_obj) deps;
			Lwt.return deps

		method private add_dependency dep : unit Lwt.t =
			(* log#debug "add dep: %s -> %s" self#path dep *)
			self#locked_meta_path Parallel.WriteLock new_deps_ext (fun out_filename ->
				with_file_out ~flags:[Unix.O_APPEND] out_filename
					(fun output -> write_dependency output dep)
			)

		method add_file_dependency ~(mtime:Big_int.t option) ~(checksum:string option) path =
			let dep = (new file_dependency ~mtime:mtime ~checksum:checksum path) in
			log#trace "Adding dependency %s -> %a" (Filename.basename target_path) print_obj dep;
			self#add_dependency (serializable dep)

		method add_checksum checksum =
			self#add_dependency (Checksum, [checksum])

		method mark_always_rebuild =
			self#add_dependency (serializable (new always_rebuild))

		method perform_build exe block : bool Lwt.t =
			assert (Sys.file_exists exe);
			log#trace "perform_build %s" self#path;

			(* TODO: quicker mtime-based check *)
			let still_needs_build = (fun () ->
				log#trace "Checking if %s still needs buld after releasing lock" self#path;
				lwt deps = self#deps in
				Lwt.return @@ match deps with
					| Some d -> not d#already_built
					| None -> true
			) in

			let build = (fun deps_path ->
				lwt wanted = still_needs_build () in

				if wanted then (
					lwt builder_mtime = Util.get_mtime exe in
					let builder_dep = new builder_dependency
						~mtime: builder_mtime
						~checksum: None
						(Util.relpath ~from: (Filename.dirname self#path) exe)
					in

					let temp = self#ensure_meta_path "deps2" in
					with_file_out temp (fun file ->
						Lwt_io.write_line file (version_marker ^ (string_of_int format_version)) >>
						(* TODO: make Dependencies module to store init stuff *)
						write_dependency file (serializable builder_dep) >>
						write_dependency file (serializable current_run_id)
					) >>
					lwt built = try_lwt
						block exe
					with ex ->
						Lwt_unix.unlink temp >>
						raise_lwt ex
					in
					lwt () = if built then (
						lwt mtime = Util.get_mtime self#path in
						mtime |> Lwt_option.may (fun time ->
							with_file_out ~flags:[Unix.O_APPEND] temp (fun output ->
								let timedep = new build_time time in
								write_dependency output (serializable timedep)
							)
						) >>
						Lwt_unix.rename temp deps_path
					) else return_unit in
					return built
				) else Lwt.return false
			) in

			lwt built =
				Jobserver.run_job (fun () ->
					self#locked_meta_path Parallel.WriteLock deps_ext build
				)
			in
			return built
	end

