open OUnit2
module Logging = Gup.Logging

let ounit_formatter ctx _colors _fmt =
	{ Logs.report = (fun src lvl ~over k user_msgf ->
		user_msgf @@ (fun ?header:_ ?tags:_ fmt ->
			Format.kasprintf (fun msg ->
				logf ctx Logs.(match lvl with
					| Error -> `Error
					| Warning -> `Warning
					| App | Info | Debug -> `Info
				) "%s" msg;
				over ();
				k ()
			) ("[%s] " ^^ fmt) (Logs.Src.name src)
		)
	)}

let _ =
	Logging.set_level Gup.Logging.Trace;
	Logging.set_formatter Gup.Logging.trace_formatter;
	let tests = OUnit2.test_list [
		Util.suite;
		Gupfile.suite;
		Parallel.suite;
		Path.suite
	] in
	let rec wrap = OUnitTest.(function
		| TestCase (len, fn) -> TestCase (len, fun ctx ->
				bracket
					(fun ctx: unit -> Logging.set_formatter (ounit_formatter ctx))
					(fun () _ctx: unit -> Logging.set_formatter Logging.trace_formatter)
					ctx;
				fn ctx
			)
		| TestList tests -> TestList (List.map wrap tests)
		| TestLabel (name, test) -> TestLabel (name, wrap test)
	) in
	let tests = wrap tests in
	run_test_tt_main (tests)
