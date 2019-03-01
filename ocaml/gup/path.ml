open Error
open Batteries

let log = Logging.get_logger "gup.path"

module RealUnix = Unix
module type UNIX = sig
	val getcwd : unit -> string
	val readlink : string -> string
end

module Make(Unix:UNIX) = struct
	module PathString_ = struct
		let _slash_re = Str.quote Filename.dir_sep
		let dir_seps_re = Str.regexp (_slash_re ^ "+")
		(* TODO: windows *)
		let split path = Str.split dir_seps_re path
		let trailing_dir_seps = (Str.regexp (_slash_re ^ "+$"))
		let leading_dir_seps = (Str.regexp ("^" ^ _slash_re ^ "+"))
		let rtrim s = Str.replace_first trailing_dir_seps "" s
		let ltrim s = Str.replace_first leading_dir_seps "" s

		let join = String.concat Filename.dir_sep

		let root = Filename.dir_sep (* TODO: windows *)

		(* gup doesn't chdir, so this is safe to cache *)
		let cwd = Lazy.from_fun Unix.getcwd
	end

	module PathAssertions = struct
		let absolute p = if Filename.is_relative p then raise_safe "Not an absolute path: %s" p else p
		let relative p = if not (Filename.is_relative p) then raise_safe "Not a relative path: %s" p else p
		let noop p = p

		(* NOTE: these checks are slow, so we only enable them in tests *)
		let concrete =
			if Var.is_test_mode then (fun p ->
				let p = absolute p in
				if Zeroinstall_utils.abspath p <> p then raise_safe "Not a concrete path: %s" p else p
			) else noop

		let direct =
			if Var.is_test_mode then (fun p ->
				let p = relative p in
				let parts = PathString_.split p in
				let is_direct = try
					let is_indirect_component = (fun part -> part = Filename.current_dir_name || part = Filename.parent_dir_name) in
					let (_:string) = List.find is_indirect_component parts in
					false
				with Not_found -> p <> "" in
				if not is_direct then raise_safe "Not a direct path: %s" p else p
			) else noop
	end

	module type PATH = sig
		val assert_valid : string -> string
	end

	module TypedPathCore(Path:PATH) : sig
		(* just the minimal phantom type and operators *)
		type t
		val of_string : string -> t
		val _cast : string -> t
		val to_string : t -> string
		val _map : (string -> string) -> (t -> t)
		val lift : (string -> 'a) -> (t -> 'a)
		val compare : t -> t -> int
		val basename : t -> string option
	end = struct
		type t = string
		let _cast p = p
		let of_string p =
			if PathString_.rtrim p <> p then raise_safe "Path has a trailing slash: %s" p;
			Path.assert_valid p
		let to_string p = p
		let _map fn = fn
		let lift fn = fn
		let compare = Pervasives.compare
		let basename path = match (Filename.basename path) with
			| s when s = PathString_.root -> None (* only happens for root path *)
			| other -> Some other
	end

	module TypedPath(Path:PATH) = struct
		(* more goodies, without needing to write their signatures *)
		include TypedPathCore(Path)
		let dirname = _map Filename.dirname
		let exists = lift Sys.file_exists
		let split = lift PathString_.split
		let lexists = lift Util.lexists
	end

	module Relative = struct
		include TypedPath(struct
			let assert_valid = PathAssertions.relative
		end)
		let join = _cast % PathString_.join
		let eq : t -> t -> bool = (=)
		let concat : t -> t -> t = fun base path ->
			_cast (Filename.concat (to_string base) (to_string path))
		let empty = of_string ""
	end

	(* a non-empty, relative path with no `..` or `.` components *)
	module Direct = struct
		(* TODO: should these be stored as `string list`? *)
		include TypedPath(struct
			let assert_valid = PathAssertions.direct
		end)
		let relative = Relative._cast % to_string
		let of_list : string list -> t = of_string % PathString_.join
	end

	module Absolute = struct
		include TypedPath(struct
			let assert_valid = PathAssertions.absolute
		end)

		let concat : t -> Relative.t -> t = fun base suffix ->
			_cast (Filename.concat (to_string base) (Relative.to_string suffix))

		let rootless : t -> Relative.t = fun path ->
			Relative._cast (PathString_.ltrim (to_string path))

		let concat_from_dir : t -> [`absolute of t | `relative of Relative.t ] -> t = fun base -> function
			| `absolute abs -> abs
			| `relative rel -> concat (dirname base) rel
	end

	module PathComponent : sig
		type name
		type t = [
			| `parent
			| `current
			| `name of name
		]
		val to_string : t -> string
		val name_of_string : string -> name
		val string_of_name : name -> string
		val string_of_name_opt : name option -> string
		val relative_of_name : name -> Relative.t
		val relative_of_name_opt : name option -> Relative.t
		val relative : t -> Relative.t
		val join : t list -> Relative.t
		val join_names : name list -> Relative.t
		val direct_of_names : name list -> Direct.t option
		val _cast : string -> name
		val parse : string -> t
		val lift : (string -> 'a) -> (name -> 'a)
		val name : name -> t
	end = struct
		type name = string
		type t = [
			| `parent
			| `current
			| `name of name
		]
		let to_string = function
			| `parent -> Filename.parent_dir_name
			| `current -> Filename.current_dir_name
			| `name n -> n

		let name n = `name n

		let string_of_name s = s
		let string_of_name_opt s = s |> Option.map string_of_name |> Option.default ""
		let _cast s = s
		let lift fn = fn
		let relative = Relative._cast % to_string
		let relative_of_name = Relative._cast
		let relative_of_name_opt n = n |> Option.map relative_of_name |> Option.default Relative.empty

		let join components = Relative._cast (PathString_.join (components |> List.map to_string))
		let join_names names = Relative._cast (PathString_.join (names |> List.map string_of_name))
		let direct_of_names = function
			| [] -> None
			| names -> Some (Direct._cast (PathString_.join (names |> List.map string_of_name)))

		let _any_sep = Str.regexp (".*" ^ (Str.quote Filename.dir_sep))
		let name_of_string name =
			if Str.string_match _any_sep name 0 then raise_safe "PathComponent cannot contain %s: %s" Filename.dir_sep name;
			name

		let parse name = match name with
			| "" -> `current
			| s when s = Filename.current_dir_name -> `current
			| s when s = Filename.parent_dir_name -> `parent
			| name -> `name (name_of_string name)
	end

	module PathString = struct
		include PathString_
		type t = [ `absolute of Absolute.t | `relative of Relative.t ]

		let parse : string -> t = fun path ->
			let path = rtrim path in
			if Filename.is_relative path
				then `relative (Relative._cast path)
				else `absolute (Absolute._cast path)

		let to_absolute : t -> Absolute.t = function
			| `absolute p -> p
			| `relative p ->
				let cwd = Absolute._cast (Lazy.force cwd) in
				Absolute.concat cwd p

		(* let join = Relative.of_string % PathString_.join *)
		let relative : t -> Relative.t option = function
			| `absolute _ -> None
			| `relative p -> Some p

		let readdir path = Sys.readdir path |> Array.map PathComponent.name_of_string

		let walk root fn : unit =
			let isdir = fun base name ->
				Sys.is_directory (
					Filename.concat base (PathComponent.string_of_name name)
				)
			in

			let rec _walk path =
				let contents = readdir path in
				let (dirs, files) = List.partition (isdir path) (Array.to_list contents) in
				let dirs = fn path dirs files in
				dirs |> List.iter (fun dir ->
					let subdir = Filename.concat path (PathComponent.string_of_name dir)
					in
					_walk subdir
				)
			in
			_walk root
	end

	module Concrete_ = struct
		module Super = TypedPath(struct
			let assert_valid = PathAssertions.concrete
		end)
		include Super
		let absolute = Absolute._cast % to_string
		let root = _cast PathString.root
		let cwd () = _cast (Lazy.force PathString.cwd)
		let dirname : t -> t = _map (Filename.dirname)
		let split : t -> PathComponent.name list = fun path ->
			(* cast is safe since concrete path cannot have . or .. components,
			 * and str.split removes ignores leading slash *)
			Super.split path |> List.map (PathComponent._cast)

		let concat : t -> Relative.t -> Absolute.t = fun base rel ->
			Absolute._cast (Filename.concat (to_string base) (Relative.to_string rel))

		let basename : t -> PathComponent.name option = fun path ->
			Super.basename path |> Option.map PathComponent.name_of_string
	end

	module RelativeFrom_ = struct
		type t = Concrete_.t * Relative.t
		let concat_from : Concrete_.t ->  PathString.t -> t = fun base -> function
			| `absolute path -> (Concrete_.root, Absolute.rootless path)
			| `relative path -> (base, path)

		let concat_from_cwd : PathString.t -> t = function
			| `absolute path -> (Concrete_.root, Absolute.rootless path)
			| `relative path -> (Concrete_.cwd (), path)
		let make (basedir:Concrete_.t) (path:Relative.t) : t = (basedir, path)
	end

	module ConcreteBase_ = struct
		type t = Concrete_.t * PathComponent.name option
		let compare = Pervasives.compare
		let make_named : Concrete_.t -> PathComponent.name option -> t = fun base path -> (base, path)
		let dirname : t -> Concrete_.t = fun (a,_) -> a
		let basename : t -> PathComponent.name option = fun (_,b) -> b
		let absolute ((base, leaf):t) = match leaf with
			| Some leaf -> Concrete_.concat base (PathComponent.relative_of_name leaf)
			| None -> Concrete_.absolute base
		let to_string : t -> string = Absolute.to_string % absolute
		let lift : (string -> 'a) -> (t -> 'a) = fun fn -> fn % to_string

		let make : Concrete_.t -> PathComponent.t -> t =
			let shift base =
				let newbase = Concrete_.dirname base in
				let name = Concrete_.basename base in
				(newbase, name)
			in
			fun base -> function
				| `parent -> (shift % fst % shift) base
				| `current -> shift base
				| `name name -> (base, Some name)

		let of_concrete (path:Concrete_.t): t =
			let base = Concrete_.dirname path in
			let name = Concrete_.basename path in
			(base, name)

		type readlink_result = [
			| `concrete of Concrete_.t
			| `link of RelativeFrom_.t
		]

		let readlink : t -> readlink_result = fun path -> (
			let (base, name) = path in
			match name with
				| None -> `concrete base
				| Some _name -> (
					let path_str = to_string path in
					let dest = (
						try
							Some (PathString.parse (Unix.readlink path_str))
						with
							| RealUnix.Unix_error (RealUnix.ENOENT, _, _)
							| RealUnix.Unix_error (RealUnix.EINVAL, _, _) -> None
					) in
					match dest with
						| Some (`absolute dest) ->
							`link (Concrete_.root, Absolute.rootless dest)
						| Some (`relative dest) ->
							`link (base, dest)
						| None -> `concrete (Concrete_._cast path_str)
				)
		)

	end

	module Concrete = struct
		include Concrete_
		type push_result = [
			| `concrete of t
			| `concrete_base of ConcreteBase_.t
		]

		let push : t -> PathComponent.t -> push_result = fun base name ->
			match name with
				| `parent -> `concrete (dirname base)
				| `current -> `concrete base
				| `name name -> `concrete_base (ConcreteBase_.make_named base (Some name))

		type _traverse_accumulator = ConcreteBase_.t -> unit
		type 'result _traverser = _traverse_accumulator -> RelativeFrom_.t -> 'result

		let _make_traverser step : 'result _traverser = fun traversed_link ->
			let parse_rel path = Relative.split path |> List.map PathComponent.parse in
			let rec continue = fun base name remaining ->
				match push base name with
				| `concrete path ->
						step continue path remaining
				| `concrete_base path ->
					(match (ConcreteBase_.readlink path) with
						| `concrete path ->
							step continue path remaining
						| `link (base, rel) ->
							traversed_link path;
							step continue base ((parse_rel rel) @ remaining)
					)
			in
			fun (base, path) ->
				step continue base (parse_rel path)

		let _traverser : t _traverser = _make_traverser (fun continue base -> function
			| [] -> base
			| name :: remaining -> (continue base name remaining)
		)

		let _make_traverse_from:
				'result. ('result _traverser) -> RelativeFrom_.t -> (ConcreteBase_.t list * 'result) =
			(fun traverser -> fun path ->
				let links_rev = ref [] in
				let accum = (fun path -> links_rev := path :: !links_rev) in
				let dest = traverser accum path in
				(List.rev !links_rev, dest)
			)

		let traverse_from : RelativeFrom_.t -> (ConcreteBase_.t list * t) = _make_traverse_from _traverser

		let resolve_from : RelativeFrom_.t -> t = _traverser (ignore)

		let resolve_abs : Absolute.t -> t = fun path ->
			resolve_from (RelativeFrom_.make root (Absolute.rootless path))

		let resolve : string -> t = fun path ->
			let path = RelativeFrom_.concat_from_cwd (PathString.parse path) in
			resolve_from path
	end

	module ConcreteBase = struct
		include ConcreteBase_

		let _cast : string -> t = fun p ->
			let dir = Filename.dirname p in
			let name = Filename.basename p in
			(Concrete._cast dir, if name = "" then None else Some (PathComponent._cast name))

		let eq : t -> t -> bool = (=)
		let lexists = lift Util.lexists

		let _traverser : t Concrete._traverser =
			Concrete._make_traverser (fun continue base -> function
				| [] -> make base `current
				| [name] -> make base name
				| name :: remaining -> continue base name remaining
			)

		let traverse_from : RelativeFrom_.t -> (t list * t) = Concrete._make_traverse_from _traverser

		let resolve_from : RelativeFrom_.t -> t = _traverser (ignore)

		let resolve : string -> t = fun path ->
			let path = RelativeFrom_.concat_from_cwd (PathString.parse path) in
			resolve_from path

		let resolve_abs : Absolute.t -> t = Absolute.lift resolve

		let rebase_to (newbase:Concrete.t) ((base, name):ConcreteBase_.t) : RelativeFrom_.t =
			let base_list = Concrete.split base in
			let newbase_list = Concrete.split newbase in

			let zipped = Enum.combine (List.enum base_list, List.enum newbase_list) in
			let common = Enum.count @@ Enum.take_while (fun (a,b) -> a = b) zipped in

			let depth_from_common_prefix = (List.length newbase_list - common) in
			let base_from_common_prefix = List.drop common base_list |> List.map PathComponent.name in

			let rel_list =
				List.of_enum (Enum.repeat ~times:depth_from_common_prefix `parent)
				@ base_from_common_prefix
				@ (match name with Some name -> [PathComponent.name name] | None -> [])
			in
			(newbase, PathComponent.join (rel_list))
	end

	module RelativeFrom = struct
		include RelativeFrom_
		let relative : t -> Relative.t = fun (_, rel) -> rel
		let base : t -> Concrete.t = fun (base, _) -> base
		let to_field : t -> string = fun path -> Relative.to_string (relative path)
		let of_field ~basedir path =
			(* log#trace "making RelativeFrom from %s, %s" (Concrete.to_string basedir) (path); *)
			make basedir (Relative.of_string path)

		let absolute : t -> Absolute.t = fun (base, path) ->
			Absolute._cast (Filename.concat (Concrete.to_string base) (Relative.to_string path))

		let to_string : t -> string = Absolute.to_string % absolute

		let lift : (string -> 'a) -> (t -> 'a) = fun fn -> fn % to_string

		let lexists = lift Util.lexists
		let exists = lift Sys.file_exists

		let concat : t -> Relative.t -> t = fun (base,rel) path ->
			(base, Relative.concat rel path)
	end

end

include Make(Unix)

module Var = struct
	include Var
	let (run_id, root_cwd) =
		if Var.is_root then
			begin
				let runid = Big_int.to_string (Util.int_time (Unix.gettimeofday ()))
				and root = Sys.getcwd () in
				Unix.putenv "GUP_RUNID" runid;
				Unix.putenv "GUP_ROOT" root;
				(runid, Concrete.of_string root)
			end
		else
			(
				Unix.getenv "GUP_RUNID",
				Unix.getenv "GUP_ROOT" |> Concrete.of_string
			)
end
