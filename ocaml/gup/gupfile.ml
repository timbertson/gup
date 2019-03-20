open Batteries
open Std
open Path

let len = List.length
let file_extension path =
	let filename = Filename.basename path in
	try (
		let _, ext = String.rsplit filename ~by:"." in
		"." ^ ext
	) with Not_found -> ""

let rec _up_path n (path:Concrete.t) =
	match n with
		| 0 -> path
		| n ->
			assert(n >= 0);
			_up_path (n-1) (Concrete.dirname path)

type gupfile =
	| Gupfile
	| Gupscript of string

let string_of_gupfile g = match g with
	| Gupfile -> "Gupfile"
	| Gupscript s -> s

let relative_of_gupfile = Relative.of_string % string_of_gupfile

type builder_suffix =
	| Empty
	| Suffix of Direct.t

module Log = (val Var.log_module "gup.gupfile")
let _match_rule_splitter = Str.regexp "\\*+"

let has_gup_extension f = String.lowercase (file_extension f) = ".gup"
let remove_gup_extension = String.rchop ~n:4
let extant_file_path ~var path =
	let path_str = Absolute.to_string path in
	try (
		match Sys.is_directory path_str with
			| true -> Log.trace var (fun m->m "skipping directory: %s" path_str); None
			| false -> Some path
	) with Sys_error _ -> None

(* converts path.sep into "/" for matching purposes *)
let canonical_sep = "/"
let canonicalize_target_name target =
	let target = Relative.to_string target in
	if Filename.dir_sep = canonical_sep then target
	else String.concat canonical_sep (PathString.split target)

(* join` prefix` to `target` using canonical_sep *)
let join_target prefix = match prefix with
	| "" -> identity
	| prefix -> (^) (prefix ^ canonical_sep)

let rule_literal = function
	| [ Str.Text t] -> Some t
	| _ -> None

let parts_of_rule_pattern = Str.full_split _match_rule_splitter

let regexp_of_rule_parts ~original_text parts =
	let re_parts = parts |> List.map (fun part ->
		match part with
		| Str.Text t -> Str.quote t
		| Str.Delim "*" -> "[^/]*"
		| Str.Delim "**" -> ".*"
		| _ -> Error.raise_safe "Invalid pattern: %s" original_text
	) in
	("^" ^ (String.concat "" re_parts) ^ "$")

class match_rule (original_text:string) =
	let exclude = String.left original_text 1 = "!" in
	let pattern_text = if exclude then String.tail original_text 1 else original_text in
	let rule_parts = parts_of_rule_pattern pattern_text in
	let rule_literal = rule_literal rule_parts in
	let match_fn = match rule_literal with
		| Some lit -> fun candidate -> lit = candidate
		| None ->
			let regexp = (Str.regexp (regexp_of_rule_parts ~original_text rule_parts)) in
			fun candidate -> Str.string_match regexp candidate 0
	in

	object (self)
		method matches (candidate:string) = match_fn candidate

		method matches_exactly (candidate:string) =
			match rule_literal with
				| Some lit -> lit = candidate
				| None -> false

		method repr = pattern_text
		method exclude = exclude
		method text = original_text
		method is_wildcard = rule_literal |> Option.is_none
		method definite_targets_in prefix existing_files =
			if exclude then assert false;
			let nothing = Enum.empty () in
			let full_target = join_target prefix in
			let declared_targets = begin match prefix with
				| "" ->
					(* return a string if the rule defines an exact match for a file *)
					rule_literal |> Option.map Enum.singleton |> Option.default nothing
				| prefix ->
					try
						let dir_match, file_match = String.split pattern_text ~by:canonical_sep in
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

let pp_match_rule : match_rule CCFormat.printer = fun fmt r ->
	let open PP in
	within "match_rule(" ")" string fmt r#text

class match_rules (rules:match_rule list) =
	let (excludes, includes) = rules |> List.partition (fun rule -> rule#exclude) in
	object
		method matches (str:string) =
			let any = List.exists (fun r ->
				r#matches str
			) in
			(any includes) && not (any excludes)
		method rules = rules

		method matches_exactly (str:string) =
			List.exists (fun r -> r#matches_exactly str) includes

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
			let open Batteries in
			includes |> List.enum
				|> Enum.map (fun r -> r#definite_targets_in prefix existing_files)
				|> Enum.concat
				|> Enum.filter (fun f ->
					(* remove files matched by an inverted rule *)
					let target = join_target prefix f in
					not @@ List.exists (fun rule -> rule#matches target) excludes
				)
	end

let pp_match_rules : match_rules CCFormat.printer = fun fmt r ->
	let open PP in
	within "match_rules(" ")" (list pp_match_rule) fmt r#rules

let pp_gupfile : (string * match_rules) list CCFormat.printer =
	let open PP in
	list (pair string pp_match_rules)

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
	let path = Absolute.to_string path in
	try
		File.with_file_in path parse_gupfile
	with Invalid_gupfile (line, reason) ->
		Error.raise_safe "Invalid gupfile - %s:%d (%s)" path line reason

class build_candidate
	(var:Var.t)
	(root:Concrete.t)
	(suffix:builder_suffix option) =
	object (self)
		method _base_path include_gup : Absolute.t =
			let path = root |> Concrete.absolute in
			(match suffix with
				| Some suff ->
					begin
						let path = if include_gup then
							Absolute.concat path (Relative.of_string "gup")
						else path in
						match suff with
							| Suffix suff -> Absolute.concat path (Direct.relative suff)
							| Empty -> path
					end
				| None -> path
			)

		method base_path = self#_base_path true

		method guppath (gupfile:gupfile) =
			Absolute.concat self#base_path (relative_of_gupfile gupfile)

		method builder_for gupfile (target:Relative.t) : Buildable.t Recursive.t option =
			let target_name = Relative.basename target in
			let build_basedir = self#_base_path false in
			let with_extant_guppath fn =
				Option.bind (self#guppath gupfile |> extant_file_path ~var) (fun path ->
					Log.trace var (fun m->m "candidate exists: %s" (Absolute.to_string path));
					fn path
				)
			in

			let target_is_builder target_name = (target_name = string_of_gupfile Gupfile) || (has_gup_extension target_name) in
			(match (gupfile, target_name) with
				| Gupscript _, Some target_name when target_is_builder target_name ->
					(* gupfiles & scripts can only be built by Gupfile targets, not .gup scripts *)
					None
				| Gupfile, None ->
					Error.raise_safe "target.basename is empty"

				| Gupscript _, _ ->
					with_extant_guppath (fun path ->
						let basedir = Concrete.resolve_abs build_basedir in
						Some (Recursive.Terminal (Buildable.make ~script:path ~target:(RelativeFrom.make basedir target)))
					)

				| Gupfile, Some target_name ->
					with_extant_guppath (fun path ->
						let rules = parse_gupfile_at path in
						Log.trace var (fun m->m "Parsed gupfile -> %a" pp_gupfile rules);
						(* always use `/` as path sep in gupfile patterns *)
						let match_target = canonicalize_target_name target in

						let rec resolve_builder ~basedir ~script_name ~target : Buildable.t Recursive.t = (
							if String.starts_with script_name "!" then (
								let script_name = String.lchop ~n:1 script_name in
								let script = match Util.which script_name with
									| Some script_path -> script_path |> PathString.parse |> PathString.to_absolute ~cwd:var.Var.cwd
									| None -> Error.raise_safe "Build command not found on PATH: %s\n     %s(specified in %s)"
										script_name var.Var.indent_str (Absolute.to_string path)
								in
								Recursive.Terminal (Buildable.make ~script ~target)
							) else (
								let script_path = PathString.parse script_name in
								let concrete = Buildable.make ~script:(Absolute.concat_from path script_path) ~target in
								let buildscript_builder = (List.enum rules) |> Enum.filter_map (fun (builder_name, ruleset) ->
									if ruleset#matches_exactly script_name then
										let target = RelativeFrom.concat_from basedir script_path in
										Some (resolve_builder ~basedir ~script_name:builder_name ~target)
									else
										None
								) |> Enum.get in
								match buildscript_builder with
									| Some builder -> Recursive.connect ~parent:builder concrete
									| None -> Recursive.terminal concrete
							)
						) in

						let matches = if target_is_builder target_name
							then fun ruleset -> ruleset#matches_exactly match_target
							else fun ruleset -> ruleset#matches match_target
						in

						(List.enum rules) |> Enum.filter_map (fun (script_name, ruleset) ->
							if matches ruleset then (
								let basedir = Concrete.resolve_abs build_basedir in
								let target = RelativeFrom.make basedir target in
								Some (resolve_builder ~basedir ~script_name ~target)
							) else
								None
						) |> Enum.get
					)
			)
	end

type build_source =
	| Direct of Concrete.t * builder_suffix option
	| Indirect of Concrete.t * builder_suffix option * Relative.t

let build_sources (dir:Concrete.t) : build_source Enum.t =
	(* we need a concrete path to tell how far up the tree we should go *)
	let dirparts = Concrete.split dir in
	let dirdepth = len dirparts in

	let make_suffix parts = match PathComponent.direct_of_names parts with
			| None -> Empty
			| Some suffix -> Suffix suffix in

	(* /path/to/filename.gup *)
	let direct_target = Enum.singleton @@ Direct (dir, None) in

	(* /path/to[/gup]/filename.gup with [/gup] at each directory *)
	let direct_gup_targets = (Enum.range 0 ~until:dirdepth) |> Enum.map (fun i ->
		let suff = make_suffix (Util.slice ~start:(dirdepth - i) dirparts) in
		let base = _up_path i dir in
		Direct (base, Some suff)
	) in

	let indirect_gup_targets = (Enum.range 0 ~until:dirdepth) |> Enum.map (fun up ->
		(* `up` controls how "fuzzy" the match is, in terms
		 * of how specific the path is - least fuzzy wins.
		 *
		 * As `up` increments, we discard a folder on the base path. *)
		let parent_base = _up_path up dir in
		(* base_suff is the path back to our target after stripping off `up` components
		 * - used to match against the gupfile rule *)
		let base_suff = PathComponent.join_names (Util.slice ~start:(dirdepth - up) dirparts) in
		Enum.concat @@ List.enum [
			(Enum.singleton @@ Indirect (parent_base, None, base_suff));
			(Enum.range 0 ~until:(dirdepth - up)) |> Enum.map (fun i ->
				(* `i` is how far up the directory tree we're looking for the gup/ directory *)
				let suff = make_suffix @@ Util.slice ~start:(dirdepth - i - up) ~stop:(dirdepth - up) dirparts in
				let base = _up_path i parent_base in
				Indirect (base, Some suff, base_suff)
			)]
	) in

	Enum.concat @@ List.enum [
		direct_target;
		direct_gup_targets;
		Enum.concat indirect_gup_targets
	]


let possible_builders ~var (path:ConcreteBase.t) : (build_candidate * gupfile * Relative.t) Enum.t =
	let filename = ConcreteBase.basename path in
	let direct_gupfile = Gupscript ((PathComponent.string_of_name_opt filename) ^ ".gup") in

	let filename = filename |> PathComponent.relative_of_name_opt in
	build_sources (ConcreteBase.dirname path) |> Enum.map (fun source ->
		match source with
			| Direct (root, suff) ->
					(new build_candidate var root suff, direct_gupfile, filename)
			| Indirect (root, suff, target) ->
					(new build_candidate var root suff, Gupfile, (Relative.concat target filename))
	)

(* Returns all targets in `dir` that are _definitely_ buildable.
 * Not exhaustive, since there may be wildcard targets in `dir`
 * that are also buildable, but obviously generating an infinite
 * list of _possible_ names is not useful.
 *)
let buildable_files_in ~var (dir:Concrete.t) : string Enum.t =
	let readdir dir = try
		Sys.readdir dir
	with
		| Sys_error _ -> [| |]
	in
	let existing_files = (Concrete.lift readdir) dir in
	let extract_targets source : string Enum.t =
		match source with
			| Direct (root, suff) ->
					(* direct targets are just <name>.gup *)
					let candidate = new build_candidate var root suff in
					let base_path = candidate#base_path in
					let files = (Absolute.lift readdir) base_path in
					let files = files
						|> Array.enum
						|> Enum.filter (fun f -> String.length f > 4 && has_gup_extension f)
						|> Enum.filter (fun f -> Util.lexists ((Absolute.lift Filename.concat) base_path f))
					in
					files |> Enum.map remove_gup_extension
			| Indirect (root, suff, target_prefix) ->
					let candidate = new build_candidate var root suff in
					let guppath = candidate#guppath Gupfile |> extant_file_path ~var in
					let get_targets guppath : string Enum.t =
						parse_gupfile_at guppath
							|> List.enum
							|> Enum.map snd
							|> Enum.map (fun rule ->
								rule#definite_targets_in (Relative.to_string target_prefix) existing_files)
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

let find_builder ~var path : Buildable.t Recursive.t option =
	possible_builders ~var path |> Enum.filter_map (fun (candidate, gupfile, target) ->
		candidate#builder_for gupfile target
	)
	|> Enum.get
