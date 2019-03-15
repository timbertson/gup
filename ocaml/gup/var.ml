open Batteries
open Path

(* vars which vary by build *)
type t = {
	indent : int;
	indent_str : string;
	cwd: Path.Concrete.t;
	parent_target: Path.ConcreteBase.t option;
}

let extend_env var env =
	(* always add 2 spaces to indent *)
	StringMap.add Var_global.Key.indent (var.indent_str ^ "  ") env

let resolve_parent_target var =
	var |> Option.map PathString.parse |> Option.map (function
		| `relative rel ->
			let msg = "relative path in $GUP_TARGET: " ^ (Relative.to_string rel) in
			raise (Invalid_argument msg)
		| `absolute p -> ConcreteBase._cast (Absolute.to_string p)
	)

let indent_str n = String.make n ' '

let global () =
	let open Var_global in
	{
		indent;
		indent_str = indent_str indent;
		parent_target = resolve_parent_target (Var_global.parent_target ());
		cwd = Lazy.force cwd |> Path.Concrete.of_string;
	}

let (run_id, root_cwd) =
	let open Var_global in
	if is_root then (
			let runid = Big_int.to_string (Util.int_time (Unix.gettimeofday ()))
			and root = Sys.getcwd () in
			Unix.putenv Key.run_id runid;
			Unix.putenv Key.root root;
			(runid, Lazy.force cwd |> Path.Concrete.of_string)
	) else
		(
			Unix.getenv Key.run_id,
			Unix.getenv Key.root |> Path.Concrete.of_string
		)

module VarLog = struct
	module type LOG = sig
		val err : t -> 'a Logs.log
		val warn : t -> 'a Logs.log
		val info : t -> 'a Logs.log
		val debug : t -> 'a Logs.log
		val trace : t -> 'a Logs.log
	end
	let src_log : Logs.src -> (module LOG) = fun src ->
		let module Base: Logging.LogsExt.LOG = (val Logging.LogsExt.src_log src) in
		let module Log = struct
			let wrap logfn var : 'a Logs.log = fun fn ->
				logfn (fun m -> fn (fun ?header ?tags fmt -> m ?header ?tags ("%s" ^^ fmt) var.indent_str))

			let err var = wrap Base.err var
			let warn var = wrap Base.warn var
			let info var = wrap Base.info var
			let debug var = wrap Base.debug var
			let trace var = wrap Base.trace var
		end
		in
		(module Log : LOG)
end

let log_module name = VarLog.src_log (Logs.Src.create name)

