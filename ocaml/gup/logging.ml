type log_level =
	| Error
	| Warn
	| Info
	| Debug
	| Trace

type colors = {
	red : string;
	green : string;
	yellow : string;
	bold : string;
	reset : string;
}

(* By default, no output colouring. *)
let no_colors = {
	red    = "";
	green  = "";
	yellow = "";
	bold   = "";
	reset  = "";
}

let color_for colors lvl =
	let open Logs in
	match lvl with
	| Error   -> colors.red
	| Warning -> colors.yellow
	| Info    -> colors.green
	| _ -> ""

let style_for colors lvl =
	let open Logs in
	match lvl with
	| Error | Warning | Info -> colors.bold
	| _ -> ""

let report colors apply ~over k user_msgf =
	let k (_:Format.formatter) = over (); k () in
	let k ppf = Format.kfprintf k ppf "%s\n" colors.reset in
	user_msgf @@ (fun ?header ?tags:_ fmt -> apply ~indent:(header |> CCOpt.get_or ~default:"") k fmt)

let default_formatter colors ppf =
	{ Logs.report = (fun _src level ->
		report colors (fun ~indent k fmt ->
			Format.kfprintf k ppf ("%sgup %s%s" ^^ fmt)
				(color_for colors level) indent (style_for colors level)
		)
	)}

let trace_formatter colors ppf =
	let pid = Unix.getpid () in
	{ Logs.report = (fun src level ->
		report colors (fun ~indent k fmt ->
			Format.kfprintf k ppf ("%s[%d %-11s|%5s] %s%s" ^^ fmt)
				(color_for colors level) pid (Logs.Src.name src)
				(Logs.level_to_string (Some level)) indent (style_for colors level)
		)
	)}

let test_formatter colors ppf =
	{ Logs.report = (fun _src level ->
		report colors (fun ~indent k fmt ->
			Format.kfprintf k ppf ("# %s%a %s%s" ^^ fmt)
				(color_for colors level) Logs.pp_level level indent (style_for colors level)
		)
	)}

let internal_level = ref Info

let set_level new_lvl =
	internal_level := new_lvl;
	Logs.set_level (Some (match new_lvl with
	| Error -> Logs.Error
	| Warn -> Logs.Warning
	| Info -> Logs.Info
	| Debug -> Logs.Debug
	| Trace -> Logs.Debug
	))

let _flush = ref ignore
let flush () = !_flush ()

let set_formatter r =
	let want_color =
		try Sys.getenv "GUP_COLOR"
		with Not_found -> "auto"
	in

	(* TODO: proper... *)
	let colors =
		if want_color = "1" || (
				want_color = "auto" &&
				Unix.isatty Unix.stderr &&
				(try Sys.getenv("TERM") with Not_found -> "dumb") <> "dumb"
			)
		then {
			(* ...use ANSI formatting codes. *)
			red    = "\x1b[31m";
			green  = "\x1b[32m";
			yellow = "\x1b[33m";
			bold   = "\x1b[1m";
			reset  = "\x1b[m";
		} else no_colors
	in
	let fmt = Format.err_formatter in
	_flush := Format.pp_print_flush fmt;
	Logs.set_reporter (r colors fmt)


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
				if !internal_level = Trace then
					Super.debug msgf
				else
					()
		end
		in
		(module Log : LOG)
end
