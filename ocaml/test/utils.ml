open Batteries
open OUnit2
open Gup.Gupfile
open Gup
open Gup.Utils

let suite = "Utils" >:::
[
	"normpath on a single file" >:: (fun _ ->
		assert_equal ~printer:identity "filename" (normpath "filename");
		assert_equal ~printer:identity "a/b/filename" (normpath "a/b/filename");
		assert_equal ~printer:identity "a/filename" (normpath "a/b/../filename");
		assert_equal ~printer:identity "../filename" (normpath "../filename");
		assert_equal ~printer:identity "filename" (normpath "./filename");
		assert_equal ~printer:identity "." (normpath "./")
	);

	(* XXX file bug against FileuUtils.make_relative *)
	"make_relative" >:: (fun ctx ->
		let tmp = bracket_tmpdir ctx in
		let root = Filename.concat tmp "a" in
		let base = Filename.concat tmp "a/b" in
		Gup.Utils.makedirs base;
		with_bracket_chdir ctx base (fun _ ->
			assert_equal ~printer:identity "b/c" (Gup.Util.relpath ~from:root "../b/c")
		)
	)
]
