open OUnit2
let _ =
	Gup.Logging.set_level Gup.Logging.Trace;
	Gup.Logging.set_formatter Gup.Logging.trace_formatter;
	run_test_tt_main (OUnit2.test_list [
		Util.suite;
		Gupfile.suite;
		Parallel.suite
	])
