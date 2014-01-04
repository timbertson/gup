open Batteries
open OUnit2
open Gup.Parallel
open Gup

let print_opt_int_pair p =
	Printf.sprintf2 "%a" (Option.print (Tuple.Tuple2.print Int.print Int.print)) p

let assertFds expected str =
	assert_equal ~printer: print_opt_int_pair expected (Jobserver.extract_fds str)

let suite = "MAKEFLAGS" >:::
[
	"extracts FDs" >:: (fun _ ->
		assertFds (Some (1,2)) "--jobserver-fds=1,2";
		assertFds (Some (100,200)) "make --jobserver-fds=100,200 -j";
	)
]
