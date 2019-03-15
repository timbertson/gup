open Batteries

let indent_str = String.make (Var_global.indent) ' '

type log_level =
	| Error
	| Warn
	| Info
	| Debug
	| Trace

let ord lvl =
	match lvl with
	| Error -> 50
	| Warn  -> 40
	| Info  -> 30
	| Debug -> 20
	| Trace -> 10

let string_of_level lvl =
	match lvl with
	| Error -> "ERROR"
	| Warn  -> "WARNING"
	| Info  -> "INFO"
	| Debug -> "DEBUG"
	| Trace -> "TRACE"

let current_level = ref (ord Warn)

(* By default, no output colouring. *)
let red    = ref ""
let green  = ref ""
let yellow = ref ""
let bold   = ref ""
let plain  = ref ""
let no_color = ""

let color_for lvl =
	match lvl with
	| Error -> !red
	| Warn  -> !yellow
	| Info  -> !green
	| _ -> no_color

let default_formatter (_name:string) (_lvl:log_level) = ("","")

let info_formatter _name lvl =
	(
		(color_for lvl) ^ "gup " ^ indent_str ^ (!bold),
		!plain
	)

let trace_formatter name lvl =
	let pid = Unix.getpid () in
	(
		Printf.sprintf "%s[%d %-11s|%5s] %s%s" (color_for lvl) pid name (string_of_level lvl) indent_str !bold,
		!plain
	)

let test_formatter _name lvl =
	(
		"# " ^ (color_for lvl) ^ (string_of_level lvl) ^ " " ^ indent_str ^ !bold,
		!plain
	)

let current_formatter = ref default_formatter

(* TODO: make formatting Logs compatible *)

(* let get_logger name = new logger name *)
let set_level new_lvl =
	current_level := ord new_lvl
let set_formatter fn =
	current_formatter := fn

(* initialization *)

let want_color =
	try Sys.getenv "GUP_COLOR"
	with Not_found -> "auto"

let () =
	if want_color = "1" || (
			want_color = "auto" &&
			Unix.isatty Unix.stderr &&
			(try Sys.getenv("TERM") with Not_found -> "dumb") <> "dumb"
		)
	then begin
		(* ...use ANSI formatting codes. *)
		red    := "\x1b[31m";
		green  := "\x1b[32m";
		yellow := "\x1b[33m";
		bold   := "\x1b[1m";
		plain  := "\x1b[m";
	end

(* upstream Logs compat, with added TRACE level *)
module LogsExt = struct
	module type LOG = sig
		include Logs.LOG
		val trace : 'a Logs.log
	end
	let src_log : Logs.src -> (module LOG) = fun src ->
		let module Super = (val Logs.src_log src : Logs.LOG) in
		let module Log = struct
			include Super
			let trace msgf =
				if !current_level <= (ord Trace) then
					Super.debug msgf
				else
					()
		end
		in
		(module Log : LOG)
end
