open Batteries

(* should be in `var`, but that causes recursive modules *)
let indent = try Sys.getenv "GUP_INDENT" with Not_found -> ""
let () =
	Unix.putenv "GUP_INDENT" (indent ^ "  ")

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

let default_formatter name lvl = ("","")

let info_formatter name lvl =
	(
		(color_for lvl) ^ "gup " ^ indent ^ (!bold),
		!plain
	)

let trace_formatter name lvl =
	let pid = Unix.getpid () in
	(
		Printf.sprintf "%s[%d %-11s|%5s] %s%s" (color_for lvl) pid name (string_of_level lvl) indent !bold,
		!plain
	)

let test_formatter name lvl =
	(
		"# " ^ (color_for lvl) ^ (string_of_level lvl) ^ " " ^ indent ^ !bold,
		!plain
	)

let current_formatter = ref default_formatter

class logger (name:string) =
	object (self)
		method logf : 'a. log_level -> ('a, unit IO.output, unit) format -> 'a = fun lvl ->
			if (ord lvl) >= !current_level then
				let (pre, post) = !current_formatter name lvl in
				let print_post = fun _ -> prerr_endline post in
				prerr_string pre;
				Printf.kfprintf print_post stderr
			else
				Printf.ifprintf stdout

		(* XXX are these ever used? *)
		method errors  = self#logf Error "%s"
		method warns   = self#logf Warn "%s"
		method infos   = self#logf Info "%s"
		method debugs  = self#logf Debug "%s"
		method traces  = self#logf Trace "%s"

		(* printf-style versions *)
		method error : 'a. ('a, unit IO.output, unit) format -> 'a = self#logf Error
		method warn  : 'a. ('a, unit IO.output, unit) format -> 'a = self#logf Warn
		method info  : 'a. ('a, unit IO.output, unit) format -> 'a = self#logf Info
		method debug : 'a. ('a, unit IO.output, unit) format -> 'a = self#logf Debug
		method trace : 'a. ('a, unit IO.output, unit) format -> 'a = self#logf Trace
	end

let get_logger name = new logger name
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
