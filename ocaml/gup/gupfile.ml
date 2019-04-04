open Std
open Path
open CCFun

let len = List.length
let file_extension path =
	let filename = Filename.basename path in
	CCString.Split.right ~by:"." filename
		|> CCOpt.fold (fun _ (_, ext) -> "." ^ ext) ""

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

let has_gup_extension f = String.lowercase_ascii (file_extension f) = ".gup"
let remove_gup_extension = fst % CCString.Split.right_exn ~by:"."
let extant_file_path ~var path =
	let path_str = Absolute.to_string path in
	try%lwt
		let%lwt stat = Lwt_unix.stat path_str in
		Lwt.return (match stat.st_kind with
			| S_DIR -> Log.trace var (fun m->m "skipping directory: %s" path_str); None
			| _ -> Some path
		)
	with Unix.(Unix_error (ENOENT, _, _)) -> Lwt.return_none

(* converts path.sep into "/" for matching purposes *)
let canonical_sep = "/"
let canonicalize_target_name target =
	let target = Relative.to_string target in
	if Filename.dir_sep = canonical_sep then target
	else String.concat canonical_sep (PathString.split target)

(* join` prefix` to `target` using canonical_sep *)
let join_target prefix = match prefix with
	| "" -> id
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
	let exclude, pattern_text = match CCString.chop_prefix ~pre:"!" original_text with
		| Some t -> (true, t)
		| None -> (false, original_text)
	in
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
			rule_literal |> CCOpt.exists (String.equal candidate)

		method repr = pattern_text
		method exclude = exclude
		method text = original_text
		method is_wildcard = rule_literal |> CCOpt.is_none
		method definite_targets_in prefix existing_files =
			if exclude then assert false;
			let nothing = OSeq.empty in
			let full_target = join_target prefix in
			let seq_of_option = CCOpt.fold (fun _ -> Seq.return) nothing in
			let declared_targets = (match prefix with
				| "" ->
					(* return a string if the rule defines an exact match for a file *)
					seq_of_option rule_literal
				| prefix ->
					CCString.Split.left ~by:canonical_sep pattern_text |> CCOpt.fold (fun _ (dir_match, file_match) ->
						let dir_match = new match_rule dir_match in
						if dir_match#matches prefix then (
							(new match_rule file_match)#definite_targets_in "" existing_files
						) else nothing
					) nothing
			) in

			(* if rule happens to match existing files, include them *)
			let existing_file_targets = existing_files |> OSeq.of_array |> OSeq.filter (function filename ->
				self#matches (full_target filename)
			) in

			OSeq.append declared_targets existing_file_targets
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
			(existing_files:string array) : string OSeq.t
		=
			includes |> OSeq.of_list
				|> OSeq.map (fun r -> r#definite_targets_in prefix existing_files)
				|> OSeq.flatten
				|> OSeq.filter (fun f ->
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

let parse_gupfile (input:Lwt_io.input Lwt_io.channel) =
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

	let%lwt () = Lwt_io.read_lines input |> Lwt_stream.iter (fun line ->
		(* TODO: rewrite to be less imerative *)
		if not (CCString.prefix line ~pre:"#") then (
			let new_rule = not @@ Str.string_match initial_space line 0 in
			let line = String.trim line in
			if not (CCString.is_empty line) then (
				if new_rule then (
					finish_rule ();
					if not (CCString.suffix line ~suf:":") then
						invalid_syntax "script line must end with a colon";
					let line = String.sub line 0 (String.length line - 1) in
					current_script := Some (String.trim line)
				) else (
					current_matches := (new match_rule line) :: !current_matches
				)
			)
		);
		lineno := !lineno + 1
	) in
	finish_rule ();
	Lwt.return (
		List.rev !rules_r |> List.map (fun (script, rules) -> script, new match_rules rules)
	)

let parse_gupfile_at path =
	let path = Absolute.to_string path in
	try%lwt
		Lwt_io.with_file ~mode:Lwt_io.input path parse_gupfile
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

		method builder_for gupfile (target:Relative.t) : Buildable.t Recursive.t option Lwt.t =
			let target_name = Relative.basename target in
			let build_basedir = self#_base_path false in
			let with_extant_guppath (fn: Absolute.t -> 'a option Lwt.t): 'a option Lwt.t =
				let%lwt extant = extant_file_path ~var (self#guppath gupfile) in
				extant |> (CCOpt.map (fun path ->
					Log.trace var (fun m->m "candidate exists: %s" (Absolute.to_string path));
					fn path
				)) |> CCOpt.get_or ~default:Lwt.return_none
			in

			let target_is_builder target_name = (target_name = string_of_gupfile Gupfile) || (has_gup_extension target_name) in
			(match (gupfile, target_name) with
				| Gupscript _, Some target_name when target_is_builder target_name ->
					(* gupfiles & scripts can only be built by Gupfile targets, not .gup scripts *)
					Lwt.return_none
				| Gupfile, None ->
					Error.raise_safe "target.basename is empty"

				| Gupscript _, _ ->
					with_extant_guppath (fun path ->
						let basedir = Concrete.resolve_abs build_basedir in
						Lwt.return (
							Some (Recursive.Terminal (Buildable.make ~script:path ~target:(RelativeFrom.make basedir target)))
						)
					)

				| Gupfile, Some target_name ->
					with_extant_guppath (fun path ->
						let%lwt rules = parse_gupfile_at path in
						Log.trace var (fun m->m "Parsed gupfile -> %a" pp_gupfile rules);
						(* always use `/` as path sep in gupfile patterns *)
						let match_target = canonicalize_target_name target in

						let rec resolve_builder ~basedir ~script_name ~target : Buildable.t Recursive.t = (
							match CCString.chop_prefix ~pre:"!" script_name with
								| Some script_name -> (
									let script = match Util.which script_name with
										| Some script_path -> script_path |> PathString.parse |> PathString.to_absolute ~cwd:var.Var.cwd
										| None -> Error.raise_safe "Build command not found on PATH: %s\n     %s(specified in %s)"
											script_name var.Var.indent_str (Absolute.to_string path)
									in
									Recursive.Terminal (Buildable.make ~script ~target)
								)
								| None -> (
									let script_path = PathString.parse script_name in
									let concrete = Buildable.make ~script:(Absolute.concat_from path script_path) ~target in
									let buildscript_builder = (OSeq.of_list rules) |> OSeq.filter_map (fun (builder_name, ruleset) ->
										if ruleset#matches_exactly script_name then
											let target = RelativeFrom.concat_from basedir script_path in
											Some (resolve_builder ~basedir ~script_name:builder_name ~target)
										else
											None
									) |> Util.oseq_head in
									match buildscript_builder with
										| Some builder -> Recursive.connect ~parent:builder concrete
										| None -> Recursive.terminal concrete
								)
						) in

						let matches = if target_is_builder target_name
							then fun ruleset -> ruleset#matches_exactly match_target
							else fun ruleset -> ruleset#matches match_target
						in

						(OSeq.of_list rules) |> OSeq.filter_map (fun (script_name, ruleset) ->
							if matches ruleset then (
								let basedir = Concrete.resolve_abs build_basedir in
								let target = RelativeFrom.make basedir target in
								Some (resolve_builder ~basedir ~script_name ~target)
							) else
								None
						) |> Util.oseq_head |> Lwt.return
					)
			)
	end

type build_source =
	| Direct of Concrete.t * builder_suffix option
	| Indirect of Concrete.t * builder_suffix option * Relative.t

let build_sources (dir:Concrete.t) : build_source OSeq.t =
	(* we need a concrete path to tell how far up the tree we should go *)
	let dirparts = Concrete.split dir in
	let dirdepth = len dirparts in

	let make_suffix parts = match PathComponent.direct_of_names parts with
			| None -> Empty
			| Some suffix -> Suffix suffix in

	(* /path/to/filename.gup *)
	let direct_target = OSeq.return @@ Direct (dir, None) in

	let oseq_range start ~until:end_inclusive =
		OSeq.iterate start succ |> OSeq.take (end_inclusive+1)
	in

	(* /path/to[/gup]/filename.gup with [/gup] at each directory *)
	let direct_gup_targets = (oseq_range 0 ~until:dirdepth) |> OSeq.map (fun i ->
		let suff = make_suffix (Util.slice ~start:(dirdepth - i) dirparts) in
		let base = _up_path i dir in
		Direct (base, Some suff)
	) in

	let indirect_gup_targets = (oseq_range 0 ~until:dirdepth) |> OSeq.map (fun up ->
		(* `up` controls how "fuzzy" the match is, in terms
		 * of how specific the path is - least fuzzy wins.
		 *
		 * As `up` increments, we discard a folder on the base path. *)
		let parent_base = _up_path up dir in
		(* base_suff is the path back to our target after stripping off `up` components
		 * - used to match against the gupfile rule *)
		let base_suff = PathComponent.join_names (Util.slice ~start:(dirdepth - up) dirparts) in
		OSeq.flatten @@ OSeq.of_list [
			(OSeq.return @@ Indirect (parent_base, None, base_suff));
			(oseq_range 0 ~until:(dirdepth - up)) |> OSeq.map (fun i ->
				(* `i` is how far up the directory tree we're looking for the gup/ directory *)
				let suff = make_suffix @@ Util.slice ~start:(dirdepth - i - up) ~stop:(dirdepth - up) dirparts in
				let base = _up_path i parent_base in
				Indirect (base, Some suff, base_suff)
			)]
	) in

	OSeq.flatten @@ OSeq.of_list [
		direct_target;
		direct_gup_targets;
		OSeq.flatten indirect_gup_targets
	]


let possible_builders ~var (path:ConcreteBase.t) : (build_candidate * gupfile * Relative.t) OSeq.t =
	let filename = ConcreteBase.basename path in
	let direct_gupfile = Gupscript ((PathComponent.string_of_name_opt filename) ^ ".gup") in

	let filename = filename |> PathComponent.relative_of_name_opt in
	build_sources (ConcreteBase.dirname path) |> OSeq.map (fun source ->
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
let buildable_files_in ~var (dir:Concrete.t) : string Lwt_stream.t =
	let readdir dir = try
		Sys.readdir dir
	with
		| Sys_error _ -> [| |]
	in
	let existing_files = (Concrete.lift readdir) dir in
	let extract_targets source : string list Lwt.t =
		match source with
			| Direct (root, suff) ->
					(* direct targets are just <name>.gup *)
					let candidate = new build_candidate var root suff in
					let base_path = candidate#base_path in
					let files = (Absolute.lift Lwt_unix.files_of_directory) base_path in
					files
						|> Lwt_stream.filter_map (fun f ->
							if (has_gup_extension f && Util.lexists ((Absolute.lift Filename.concat) base_path f))
								then Some (remove_gup_extension f)
								else None
						)
						|> Lwt_stream.to_list
			| Indirect (root, suff, target_prefix) ->
					let candidate = new build_candidate var root suff in
					let%lwt guppath = candidate#guppath Gupfile |> extant_file_path ~var in
					let get_targets (guppath: Absolute.t) : string list Lwt.t =
						parse_gupfile_at guppath |> Lwt.map (fun parsed -> parsed
							|> List.map snd
							|> List.map (fun rule ->
								rule#definite_targets_in (Relative.to_string target_prefix) existing_files |> OSeq.to_list
							) |> List.flatten
						)
					in
					guppath |> CCOpt.map get_targets |> CCOpt.get_or ~default:(Lwt.return CCList.empty)
	in

	let chunks : string list Lwt.t OSeq.t = (build_sources dir |> OSeq.map extract_targets) in
	let all_results : string Lwt_stream.t = Util.stream_of_lwt_oseq chunks
		|> Lwt_stream.map Lwt_stream.of_list |> Lwt_stream.concat in

	(* all_results may have dupes - instead return an enum that lazily filters out successive seen elements *)
	let module Set = Set.Make(String) in
	let seen = ref Set.empty in
	all_results |> Lwt_stream.filter (fun elem ->
		let is_new = not (Set.mem elem !seen) in
		seen := Set.add elem !seen;
		is_new
	)

let stream_of_seq input =
	let head = ref input in
	Lwt_stream.from_direct (fun () ->
		let open OSeq in
		match !head () with
			| Nil -> None
			| Cons (x, tail) -> head := tail; Some x
	)

let find_builder ~var path : Buildable.t Recursive.t option Lwt.t =
	possible_builders ~var path |> Util.stream_of_oseq |> Lwt_stream.filter_map_s (fun ((candidate:build_candidate), gupfile, target) ->
		candidate#builder_for gupfile target
	) |> Lwt_stream.get
