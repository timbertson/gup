open Batteries
open Std

type 'a dirty_result =
	| Known of bool
	| Unknown of 'a

type dirty_args = {
	path:string;
	base_path:string;
	builder_path:string;
	built:bool;
}

type dependency_type =
	| FileDependency
	| Checksum
	| RunId
	| Builder
	| BuildTime
	| AlwaysRebuild

let log = Logging.get_logger "gup.state"
let meta_dir_name = ".gup"

let empty_checksum = "-"
let format_version = 1
let version_marker = "version: "

(* exceptionless helpers *)
let readline f = try Some (IO.read_line f) with IO.No_more_input -> None
let int_option_of_string s = try Some (Int.of_string s) with Invalid_argument _ -> None

let built_targets dir =
	let contents = Sys.readdir dir in
	contents |> Array.filter_map (fun f ->
		if String.ends_with f ".deps"
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
	| FileDependency -> "filedep"
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

let tag_assoc_str = serializable_dependencies |> List.map (fun dep -> (string_of_dependency_type dep.tag, dep))
let tag_assoc     = serializable_dependencies |> List.map (fun dep -> (dep.tag, dep))

let serializable dep = (dep#tag, dep#fields)

let write_dependency output (tag,fields) =
	let (_, typ) = List.find (fun (t, _) -> t = tag) tag_assoc in
	if List.length fields <> typ.num_fields then Common.raise_safe "invalid fields";
	IO.write_line output @@ (string_of_dependency_type tag) ^ ": " ^ (String.join " " fields)

class virtual base_dependency = object (self)
	method virtual tag : dependency_type
	method virtual fields : string list
	method virtual is_dirty : dirty_args -> target_state dirty_result
	method print out =
		Printf.fprintf out "<#%s: %a>"
			(string_of_dependency_type self#tag)
			(List.print String.print_quoted) self#fields
	method child : string option = None
end

(* TODO: can this just be a serializable subclass of base_dependency? *)
and unserializable = object
	method tag : dependency_type = assert false
	method fields : string list = assert false
end

and file_dependency ~(mtime:int option) ~(checksum:string option) (path:string) =
	object (self)
		inherit base_dependency
		method tag = FileDependency
		method child = Some path
		method fields =
			let mtime_str = Option.default "0" (Option.map string_of_int mtime) in
			let checksum_str = Option.default empty_checksum checksum in
			[mtime_str; checksum_str; path]

		method private path = path
		method private mtime = mtime
		method private is_dirty_cs full_path checksum args =
			(* checksum-based check *)
			log#trace "%s: comparing using checksum" self#path;
			let state = new target_state full_path in
			let latest_checksum = Option.bind state#deps (fun deps -> deps#checksum) in
			let checksum_matches = match latest_checksum with
				| None -> false
				| Some dep_cs -> dep_cs = checksum
			in
			if not checksum_matches then (
				log#debug "DIRTY: %s (stored checksum is %s, current is %a)"
					self#path checksum (Option.print String.print) latest_checksum;
				Known true)
			else (
				if args.built then
					Known false
				else (
					log#trace "%s: might be dirty - returning %a"
						self#path
						print_repr state;
					Unknown (state :> target_state)
				)
			)

		method private is_dirty_mtime full_path =
			(* pure mtime-based check *)
			let current_mtime = Util.get_mtime full_path in
			if not @@ Option.eq current_mtime self#mtime then (
				log#debug "DIRTY: %s (stored mtime is %a, current is %a)"
					self#path
					Util.print_mtime self#mtime
					Util.print_mtime current_mtime;
				true
			) else false

		method is_dirty args =
			let full_path = self#full_path args.base_path in
			match checksum with
				| Some checksum -> self#is_dirty_cs full_path checksum args
				| None -> Known (self#is_dirty_mtime full_path)

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
			assert (not @@ Utils.is_absolute builder_path);
			assert (not @@ Utils.is_absolute path);
			if builder_path <> path then (
				log#debug "DIRTY: builder changed from %s -> %s" path builder_path;
				Known true
			) else super#is_dirty args
	end

and never_built =
	object (self)
		inherit unserializable
		method is_dirty (_:dirty_args) : target_state dirty_result = Known true
	end

and always_rebuild =
	object (self)
		inherit base_dependency
		method tag = AlwaysRebuild
		method fields = []
		method is_dirty (_:dirty_args) : target_state dirty_result = Known true
	end

and build_time time =
	object (self)
		inherit base_dependency
		method tag = BuildTime
		method fields = [string_of_int time]
		method is_dirty args = 
			let path = args.path in
			let mtime = Option.get (Util.get_mtime path) in
			Known (
				if mtime <> time then (
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

and dependencies target_path (input:IO.input) =
	let update_singleton r v =
		assert (Option.is_none !r);
		r := v;
		None
	in

	let parse_line line : (dependency_class * string list) =
		let tag, content = String.split line ":" in
		let (_, typ) =
			try List.find (fun (prefix, typ) -> prefix = tag) tag_assoc_str
			with Not_found -> Common.raise_safe "invalid dep line: %s" line
		in
		let fields = Str.bounded_split (Str.regexp " ") (String.lchop content) typ.num_fields in
		(typ, fields)
	in

	let _parse input rv =
		rv.rules := IO.lines_of input |> Enum.filter_map (fun line ->
			let typ, fields = parse_line (String.strip line) in
			let parse_cs cs = if cs = empty_checksum then None else Some cs in
			let parse_mtime mtime = match Int.of_string mtime with
				| 0 -> None
				| t -> Some t
			in
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
				| (BuildTime, [time]) -> Some (new build_time (int_option_of_string time |> Option.get))
				| (AlwaysRebuild, []) -> Some (new always_rebuild)
				| _ -> Common.raise_safe "Invalid dependency line: %s" line
		) |> List.of_enum;
		rv
	in

	let data =
		let rv = {
			checksum = ref None;
			run_id = ref None;
			rules = ref [];
		} in
		let version_line = readline input in
		log#trace "version_line: %a" (Option.print String.print) version_line;
		let version_number = Option.bind version_line (fun line ->
			if String.starts_with line version_marker then (
				let (_, version_string) = String.split line " " in
				int_option_of_string version_string
			) else None
		) in
		match version_number with
			| None -> Common.raise_safe "Invalid dependency file"
			| Some v ->
				if v <> format_version
					then Common.raise_safe "Version mismatch: can't read format version: %d" v
		;
		_parse input rv
	in
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

		method is_dirty (builder: Gupfile.builder) (built:bool) : (target_state list) dirty_result =
			Return.label (fun rv ->
				if not (Sys.file_exists target_path) then (
					log#debug "DIRTY: %s (target does not exist)" target_path;
					Return.return rv (Known true)
			)
			;
			let base_path = Filename.dirname target_path in
			let args = {
				path = target_path;
				base_path = base_path;
				builder_path = Util.relpath ~from:base_path builder#path;
				built = built
			} in

				let unknown_states = List.enum !(data.rules) |> Enum.filter_map (fun r ->
					let state = r#is_dirty args in
					match state with
					| Known false -> None (* ignore clean targets *)
					| Known true -> (
						log#trace "is_dirty: %s returning true" target_path;
						Return.return rv (Known true)
					)
					| Unknown state -> Some state
				) |> List.of_enum in
				if List.length unknown_states = 0 then (
					log#trace "is_dirty: %s returning false" target_path;
					Known false
				) else (
					log#trace "is_dirty: %s returning %a" target_path (List.print print_repr) unknown_states;
					Unknown unknown_states
				)
			)

		method checksum = !(data.checksum)
end

and target_state (target_path:string) =
	object (self)
		method private ensure_meta_path ext =
			let p = self#meta_path ext in
			Utils.makedirs (Filename.dirname p);
			p

		method meta_path ext =
			let base = Filename.dirname target_path in
			let target = Filename.basename target_path in
			let meta_dir = Filename.concat base meta_dir_name in
			Filename.concat meta_dir (target ^ "." ^ ext)

		method private ensure_dep_lock =
			(* TODO: lock this file *)
			ignore @@ self#ensure_meta_path "deps"

		method path = target_path
		
		method repr =
			"TargetState(" ^ target_path ^ ")"

		method private parse_dependencies path : dependencies option =
			if Sys.file_exists path then (
				self#ensure_dep_lock;
				File.with_file_in path (fun f ->
					Some (new dependencies target_path f)
				)
			) else
				None

		method deps =
			let deps_path = self#meta_path "deps" in
			let deps = self#parse_dependencies deps_path in
			log#trace "Loaded serialized state: %a" (Option.print print_obj) deps;
			deps


		method private add_dependency dep =
			(* lock = Lock(self.meta_path('deps2.lock')) *)
			(* log#debug "add dep: %s -> %s" self#path dep *)
			(* TODO: lock *)
			let out_filename = self#meta_path "deps2" in
			File.with_file_out ~mode:[`append] out_filename (fun output ->
				write_dependency output dep
			)

		method add_file_dependency ~(mtime:int option) ~(checksum:string option) path =
			let dep = (new file_dependency ~mtime:mtime ~checksum:checksum path) in
			log#trace "Adding dependency %s -> %a" (Filename.basename target_path) print_obj dep;
			self#add_dependency (serializable dep)

		method add_checksum checksum =
			self#add_dependency (Checksum, [checksum])

		method mark_always_rebuild =
			self#add_dependency (serializable (new always_rebuild))

		method perform_build exe block =
			assert (Sys.file_exists exe);
			let builder_dep = new builder_dependency
				~mtime: (Util.get_mtime exe)
				~checksum: None
				(Util.relpath ~from: (Filename.dirname self#path) exe)
			in

			let temp = self#ensure_meta_path "deps2" in
			File.with_file_out temp (fun file ->
				IO.write_line file (version_marker ^ (string_of_int format_version));
				(* TODO: make Dependencies module to store init stuff *)
				write_dependency file (serializable builder_dep);
				write_dependency file (serializable current_run_id)
			);
			let built = try
				block exe
			with ex ->
				Unix.unlink temp;
				raise ex
			in
			if built then (
				let mtime = Util.get_mtime self#path in
				mtime |> Option.may (fun time ->
					File.with_file_out ~mode:[`append] temp (fun output ->
						let timedep = new build_time time in
						write_dependency output (serializable timedep)
					)
				);
				Unix.rename temp (self#meta_path "deps")
			);
			built
	end

