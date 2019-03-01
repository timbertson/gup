open Batteries
open OUnit2
open Gup.Util

let suite = "Util" >:::
[
	"normpath on a single file" >:: (fun _ ->
		assert_equal ~printer:identity "filename" (normpath "filename");
		assert_equal ~printer:identity "a/b/filename" (normpath "a/b/filename");
		assert_equal ~printer:identity "a/filename" (normpath "a/b/../filename");
		assert_equal ~printer:identity "../filename" (normpath "../filename");
		assert_equal ~printer:identity "filename" (normpath "./filename");
		assert_equal ~printer:identity "." (normpath "./")
	)
]
