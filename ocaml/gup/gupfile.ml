open Batteries
open Std
let path_join = String.concat Filename.dir_sep
let path_split path = List.filter (fun x -> not @@ String.is_empty x) (String.nsplit path Filename.dir_sep)
let len = List.length
let file_extension path =
	let filename = Filename.basename path in
	try (
		let _, ext = String.rsplit filename "." in
		"." ^ ext
	) with Not_found -> ""

let _up_path n =
	path_join (List.of_enum (Enum.repeat ~times:n ".."))


type gupfile =
	| Gupfile
	| Gupscript of string

let string_of_gupfile g = match g with
	| Gupfile -> "Gupfile"
	| Gupscript s -> s

type builder_suffix =
	| Empty
	| Suffix of string

let log = Logging.get_logger "gup.gupfile"
let _match_rule_splitter = Str.regexp "\\*+"

let has_gup_extension f = String.lowercase (file_extension f) = ".gup"
let remove_gup_extension = String.rchop ~n:4
let extant_file_path path = try (
		match Sys.is_directory path with
			| true -> log#trace "skipping directory: %s" path; None
			| false -> Some path
	) with Sys_error _ -> None

(* converts path.sep into "/" for matching purposes *)
let canonical_sep = "/"
let canonicalize_target_name target =
	if Filename.dir_sep = canonical_sep then target
	else String.concat canonical_sep (path_split target)

(* join` prefix` to `target` using canonical_sep *)
let join_target prefix = begin match prefix with
	| "" -> identity
	| prefix -> (^) (prefix ^ canonical_sep)
end


let regexp_of_rule text =
	let re_parts = Str.full_split _match_rule_splitter text |> List.map (fun part ->
		match part with
		| Str.Text t -> Str.quote t
		| Str.Delim "*" -> "[^/]*"
		| Str.Delim "**" -> ".*"
		| _ -> Error.raise_safe "Invalid pattern: %s" text
	) in
	("^" ^ (String.concat "" re_parts) ^ "$")

class match_rule (text:string) =
	let invert = String.left text 1 = "!" in
	let pattern_text = if invert then String.tail text 1 else text in
	let regexp = lazy (Str.regexp @@ regexp_of_rule pattern_text) in
	object (self)
		method matches (str:string) =
			Str.string_match (Lazy.force regexp) str 0
		method invert = invert
		method text = text
		method is_wildcard =
			try
				let (_:int) = Str.search_forward _match_rule_splitter pattern_text 0 in
				true
			with Not_found -> false

		method definite_targets_in prefix existing_files =
			if invert then assert false;
			let nothing = Enum.empty () in
			let full_target = join_target prefix in
			let declared_targets = begin match prefix with
				| "" ->
					if self#is_wildcard then nothing
					else Enum.singleton pattern_text (* rule defines an exact match for a file *)
				| prefix ->
					try
						let dir_match, file_match = String.split pattern_text canonical_sep in
						let dir_match = new match_rule dir_match in
						if dir_match#matches prefix then (
							(new match_rule file_match)#definite_targets_in "" existing_files
						) else nothing
					with Not_found -> nothing
			end in

			(* if rule happens to match existing files, include them *)
			let existing_file_targets = existing_files |> Array.enum |> Enum.filter (function filename ->
				self#matches (full_target filename)
			) in

			Enum.append declared_targets existing_file_targets
	end

let print_match_rule out r =
	Printf.fprintf out "match_rule(%a)" String.print_quoted r#text

class match_rules (rules:match_rule list) =
	let (excludes, includes) = rules |> List.partition (fun rule -> rule#invert) in
	object
		method matches (str:string) =
			let any = List.exists (fun r ->
				r#matches str
			) in
			(any includes) && not (any excludes)
		method rules = rules

		(* return targets which *must* be buildable under `prefix`, based on either:
		 * - a non-wildcard match within the target prefix
		 *   (e.g foo/bar/baz or foo/*/baz or **/baz)
		 *
		 * - any match on an existing file
		 *   (e.g foo/*/*z when "baz" is in `existing_files`)
		 *)
		method definite_targets_in
			(prefix:string)
			(existing_files:string array) : string Enum.t
		=
			includes |> List.enum
				|> Enum.map (fun r -> r#definite_targets_in prefix existing_files)
				|> Enum.concat
				|> Enum.filter (fun f ->
					(* remove files matched by an inverted rule *)
					let target = join_target prefix f in
					not @@ List.exists (fun rule -> rule#matches target) excludes
				)
	end

let print_match_rules out r =
	Printf.fprintf out "match_rules(%a)" (List.print print_match_rule) r#rules

let print_gupfile out =
		(List.print (Tuple2.print String.print_quoted print_match_rules)) out

exception Invalid_gupfile of int * string

let parse_gupfile (input:IO.input) =
	let rules_r = ref []
	and current_script = ref None
	and current_matches = ref []
	and lineno = ref 1
	and initial_space = Str.regexp "^[\t ]"
	in
	let invalid_syntax s = raise @@ Invalid_gupfile (!lineno, s) in
	let finish_rule () =
		match !current_matches with
			| [] -> ()
			| matches -> match !current_script with
				| None -> invalid_syntax "pattern not associated with a script"
				| Some script -> begin
					rules_r := (script, List.rev matches) :: !rules_r;
					current_matches := []
				end
	in

	IO.lines_of input |> Enum.iter (fun line ->
		if not (String.starts_with line "#") then begin
			let new_rule = not @@ Str.string_match initial_space line 0 in
			let line = String.strip line in
			if not (String.is_empty line) then begin
				if new_rule then begin
					finish_rule ();
					if not (String.ends_with line ":") then
						invalid_syntax "script line must end with a colon";
					let line = String.sub line 0 (String.length line - 1) in
					current_script := Some (String.strip line)
				end
				else
					current_matches := (new match_rule line) :: !current_matches
			end
		end;
		lineno := !lineno + 1
	);
	finish_rule ();
	List.rev !rules_r |> List.map (fun (script, rules) -> script, new match_rules rules)

let parse_gupfile_at path =
	try
		File.with_file_in path parse_gupfile
	with Invalid_gupfile (line, reason) ->
		Error.raise_safe "Invalid gupfile - %s:%d (%s)" path line reason

class buildscript
	(script_path:string)
	(target:string)
	(basedir:string) =
	let script_path = Util.realpath script_path in
	object (self)
		method repr = Printf.sprintf "buildscript(%s, %s, %s)" script_path target basedir
		method target = target
		method target_path = Filename.concat basedir target
		method path = script_path
		method basedir = basedir
	end

class build_candidate
	(root:string)
	(suffix:builder_suffix option) =

	let suffix_depth = function
		| Empty -> 0
		| Suffix path ->
				String.fold_left (fun count c ->
					log#trace "compare %c to %s" c Filename.dir_sep;
					if (String.make 1 c) = Filename.dir_sep
					then succ count
					else count
				) 1 path
	in

	let rec goes_above depth path =
		match Util.split_first path with
			| (Util.ParentDir, rest) ->
					if depth = 0
					then true
					else goes_above (depth - 1) rest
			| _ -> false
	in

	object (self)
		val root = Util.normpath root
		method _base_parts include_gup : string list =
			let parts = ref [ root ] in
			(match suffix with
				| Some suff ->
					begin
						if include_gup then
							parts := List.append !parts ["gup"]
						;
						match suff with
							| Suffix str -> parts := List.append !parts [str]
							| Empty -> ()
					end
				| _ -> ()
			);
			!parts

		method base_path =
			path_join @@ (self#_base_parts true)

		method guppath (gupfile:gupfile) =
			path_join ([ self#base_path ] @ [string_of_gupfile gupfile])

		method get_buildscript gupfile target : buildscript option =
			let path = self#guppath gupfile |> extant_file_path in
			Option.bind path (fun path ->
				log#trace "candidate exists: %s" path;
				let target_base = path_join(self#_base_parts false) in
				match gupfile with
					| Gupscript script -> Some (new buildscript path target target_base)
					| Gupfile ->
						let target_name = Filename.basename target in
						if
							target_name = string_of_gupfile Gupfile || has_gup_extension target_name
						then
							begin
								(* gupfiles cannot be built by implicit targets *)
								log#debug "indirect build not supported for target %s" target_name;
								None
							end
						else
							begin
								let rules = parse_gupfile_at path in
								log#trace "Parsed gupfile -> %a" print_gupfile rules;
								(* always use `/` as path sep in gupfile patterns *)
								let match_target = canonicalize_target_name target in
								(List.enum rules) |> Enum.filter_map (fun (script, ruleset) ->
									if ruleset#matches match_target then (
										let script_path = Filename.concat (Filename.dirname path) script in
										if not (Sys.file_exists script_path) then
											Error.raise_safe "Build script not found: %s\n     %s(specified in %s)" script_path Var.indent path;

										(* if `Gupfile` lives inside a gup/ dir but `script` does not,
										 * we need to drop one `..` component to account for that *)
										let script = match suffix with
											| None -> script
											| Some suffix ->
												let script = Util.normpath script in
												if goes_above (suffix_depth suffix) script
													then snd (Util.split_first script)
													else script
										in
										let base = Filename.concat target_base (Filename.dirname script) in
										Some (new buildscript
											script_path
											(Util.relpath ~from:base (Filename.concat target_base target))
											base)
									) else
										None
								) |> Enum.get
							end
			)
	end

type build_source =
	| Direct of string * builder_suffix option
	| Indirect of string * builder_suffix option * string


let build_sources dir : build_source Enum.t =
	(* we need an absolute path to tell how far up the tree we should go *)
	let dirparts = path_split (Util.abspath dir) in
	let dirdepth = len dirparts in

	let make_suffix parts = match parts with
			| [] -> Empty
			| _ -> Suffix (path_join parts) in

	(* /path/to/filename.gup *)
	let direct_target = Enum.singleton @@ Direct (dir, None) in

	(* /path/to[/gup]/filename.gup with [/gup] at each directory *)
	let direct_gup_targets = (Enum.range 0 ~until:dirdepth) |> Enum.map (fun i ->
		let suff = make_suffix (Util.slice ~start:(dirdepth - i) dirparts) in
		let base = Filename.concat dir (_up_path i) in
		Direct (base, Some suff)
	) in

	let indirect_gup_targets = (Enum.range 0 ~until:dirdepth) |> Enum.map (fun up ->
		(* `up` controls how "fuzzy" the match is, in terms
		 * of how specific the path is - least fuzzy wins.
		 *
		 * As `up` increments, we discard a folder on the base path. *)
		let parent_base = Filename.concat dir (_up_path up) in
		(* base_suff is the path back to our target after stripping off `up` components
		 * - used to match against the gupfile rule *)
		let base_suff = path_join (Util.slice ~start:(dirdepth - up) dirparts) in
		Enum.concat @@ List.enum [
			(Enum.singleton @@ Indirect (parent_base, None, base_suff));
			(Enum.range 0 ~until:(dirdepth - up)) |> Enum.map (fun i ->
				(* `i` is how far up the directory tree we're looking for the gup/ directory *)
				let suff = make_suffix @@ Util.slice ~start:(dirdepth - i - up) ~stop:(dirdepth - up) dirparts in
				let base = Filename.concat parent_base (_up_path i) in
				Indirect (base, Some suff, base_suff)
			)]
	) in

	Enum.concat @@ List.enum [
		direct_target;
		direct_gup_targets;
		Enum.concat indirect_gup_targets
	]


let possible_builders path : (build_candidate * gupfile * string) Enum.t =
	let filename = Filename.basename path and dirname = Filename.dirname path in
	let direct_gupfile = Gupscript (filename ^ ".gup") in

	build_sources dirname |> Enum.map (fun source ->
		match source with
			| Direct (root, suff) ->
					(new build_candidate root suff, direct_gupfile, filename)
			| Indirect (root, suff, target) ->
					(new build_candidate root suff, Gupfile, (Filename.concat target filename))
	)

(* Returns all targets in `dir` that are _definitely_ buildable.
 * Not exhaustive, since there may be wildcard targets in `dir`
 * that are also buildable, but obviously generating an infinite
 * list of _possible_ names is not useful.
 *)
let buildable_files_in dir : string Enum.t =
	let readdir dir = try
		Sys.readdir dir
	with
		| Sys_error _ -> [| |]
	in
	let existing_files = readdir dir in
	let extract_targets source : string Enum.t =
		match source with
			| Direct (root, suff) ->
					(* direct targets are just <name>.gup *)
					let candidate = new build_candidate root suff in
					let base_path = candidate#base_path in
					let files = readdir base_path in
					let files = files
						|> Array.enum
						|> Enum.filter (fun f -> String.length f > 4 && has_gup_extension f)
						|> Enum.filter (fun f -> Util.lexists (Filename.concat base_path f))
					in
					files |> Enum.map remove_gup_extension
			| Indirect (root, suff, target_prefix) ->
					let candidate = new build_candidate root suff in
					let guppath = candidate#guppath Gupfile |> extant_file_path in
					let get_targets guppath : string Enum.t =
						parse_gupfile_at guppath
							|> List.enum
							|> Enum.map snd
							|> Enum.map (fun rule
								-> rule#definite_targets_in target_prefix existing_files)
							|> Enum.concat
					in
					guppath |> Option.map get_targets |> Option.default (Enum.empty ())
	in
	let all_results = Enum.concat (build_sources dir |> Enum.map extract_targets) in

	(* all_results may have dupes - instead return an enum that lazily filters out successive seen elements *)
	let module Set = Set.Make(String) in
	let seen = ref Set.empty in
	let next_new = fun f -> not (Set.mem f !seen) in
	Enum.from (fun () ->
		try
			let elem = Enum.find next_new all_results in
			seen := Set.add elem !seen;
			elem
		with Not_found -> raise Enum.No_more_elements
	)

let find_buildscript path : buildscript option  =
	possible_builders path |> Enum.filter_map (fun (candidate, gupfile, target) ->
		candidate#get_buildscript gupfile target
	) |> Enum.get

