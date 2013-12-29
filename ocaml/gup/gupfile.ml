open Batteries open Std let path_join = String.concat Filename.dir_sep let path_split path = List.filter (fun x -> not @@ String.is_empty x) (String.nsplit path Filename.dir_sep) let len = List.length let file_extension path = let filename = Filename.basename path in
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

let regexp_of_rule text =
	let re_parts = Str.full_split _match_rule_splitter text |> List.map (fun part ->
		match part with
		| Str.Text t -> Str.quote t
		| Str.Delim "*" -> "[^/]*"
		| Str.Delim "**" -> ".*"
		| _ -> Common.raise_safe "Invalid pattern: %s" text
	) in
	("^" ^ (String.concat "" re_parts) ^ "$")

class match_rule (text:string) =
	let invert = String.left text 1 = "!" in
	let pattern_text = if invert then String.tail text 1 else text in
	let regexp = lazy (Str.regexp @@ regexp_of_rule pattern_text) in
	object
		method matches (str:string) =
			Str.string_match (Lazy.force regexp) str 0
		method invert = invert
		method text = text
	end

let print_match_rule out r =
	Printf.fprintf out "match_rule(%a)" String.print_quoted r#text

class match_rules (rules:match_rule list) =
	let (excludes, includes) = rules |> List.partition (fun rule -> rule#invert) in
	object
		method matches (str:string) =
			let any = Enum.exists (fun r ->
				r#matches str
		) in
			(any @@ List.enum includes)
				&& not
			(any @@ List.enum excludes)
		method rules = rules
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
		Common.raise_safe "Invalid gupfile - %s:%d (%s)" path line reason

class builder
	(script_path:string)
	(target:string)
	(basedir:string) =
	object (self)
		method repr = Printf.sprintf "builder(%s, %s, %s)" script_path target basedir
		method target = target
		method target_path = Filename.concat basedir target
		method path = script_path
		method basedir = basedir
	end

class build_candidate
	(root:string)
	(suffix:builder_suffix option)
	(gupfile:gupfile)
	(target:string) =
	object (self)
		val root = Utils.normpath root
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

		method repr : string =
			let leading = (self#_base_parts true) |>
				List.map (fun part -> if part = "gup" then "[gup]" else part) in
			let parts = List.append leading [string_of_gupfile gupfile] in
			Printf.sprintf "%s (%s)" (path_join parts) target

		method guppath =
			path_join @@ (self#_base_parts true) @ [string_of_gupfile gupfile]

		method get_builder : builder option =
			let path = self#guppath in
			let file_path = try (
				match Sys.is_directory path with
					| true -> log#trace "skipping directory: %s" path; None
					| false -> Some path
			) with Sys_error _ -> None in
			Option.bind file_path (fun path ->
				log#trace "candidate exists: %s" path;
				let target_base = path_join(self#_base_parts false) in
				match gupfile with
					| Gupscript script -> Some (new builder path target target_base)
					| Gupfile ->
						let target_name = Filename.basename target in
						if
							target_name = string_of_gupfile Gupfile ||
							String.lowercase (file_extension target_name) = ".gup"
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
								let match_target =
									if Filename.dir_sep = "/"
									then target
									else String.concat "/" (path_split target)
								in
								(List.enum rules) |> Enum.filter_map (fun (script, ruleset) ->
									if ruleset#matches match_target then (
										let base = Filename.concat target_base (Filename.dirname script) in
										let script_path = Filename.concat (Filename.dirname path) script in
										if not (Sys.file_exists script_path) then
											Common.raise_safe "Build script not found: %s\n     %s(specified in %s)" script_path Var.indent path;
										Some (new builder
											script_path
											(Util.relpath ~from:base (Filename.concat target_base target))
											base)
									) else
										None
								) |> Enum.get
							end
			)
	end

let possible_builders path : build_candidate Enum.t =
	(* we need an absolute path to tell how far up the tree we should go *)
	let filename = Filename.basename path and dirname = Filename.dirname path in
	let dirparts = path_split (Utils.abspath dirname) in
	let dirdepth = len dirparts in
	let direct_gupfile = Gupscript (filename ^ ".gup") in

	let make_suffix parts = match parts with
			| [] -> Empty
			| _ -> Suffix (path_join parts) in

	let direct_target = Enum.singleton @@ new build_candidate dirname None direct_gupfile filename in

	let direct_gup_targets = (Enum.range 0 ~until:dirdepth) |> Enum.map (fun i ->
		let suff = make_suffix (Utils.slice ~start:(dirdepth - i) dirparts) in
		let base = Filename.concat dirname (_up_path i) in
		new build_candidate base (Some suff) direct_gupfile filename
	) in

	let indirect_gup_targets = (Enum.range 0 ~until:dirdepth) |> Enum.map (fun up ->
		(* `up` controls how "fuzzy" the match is, in terms
		 * of how specific the path is - least fuzzy wins.
		 *
		 * As `up` increments, we discard a folder on the base path. *)
		let base_suff = path_join (Utils.slice ~start:(dirdepth - up) dirparts) in
		let parent_base = Filename.concat dirname (_up_path up) in
		let target_id = Filename.concat base_suff filename in
		Enum.concat @@ List.enum [
			(Enum.singleton @@ new build_candidate parent_base None Gupfile target_id);
			(Enum.range 0 ~until:(dirdepth - up)) |> Enum.map (fun i ->
				(* `i` is how far up the directory tree we're looking for the gup/ directory *)
				let suff = make_suffix @@ Utils.slice ~start:(dirdepth - i - up) ~stop:(dirdepth - up) dirparts in
				let base = Filename.concat parent_base (_up_path i) in
				new build_candidate base (Some suff) Gupfile target_id
			)]
	) in

	Enum.concat @@ List.enum [
		direct_target;
		direct_gup_targets;
		Enum.concat indirect_gup_targets
	]

let for_target path : builder option  =
	let builders = (possible_builders path) |>
		Enum.filter_map (fun candidate -> candidate#get_builder) in
	Enum.get builders

