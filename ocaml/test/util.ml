open OUnit2
open Gup.Util
open CCFun

let suite = "Util" >:::
[
	"normpath on a single file" >:: (fun _ ->
		assert_equal ~printer:id "filename" (normpath "filename");
		assert_equal ~printer:id "a/b/filename" (normpath "a/b/filename");
		assert_equal ~printer:id "a/filename" (normpath "a/b/../filename");
		assert_equal ~printer:id "../filename" (normpath "../filename");
		assert_equal ~printer:id "filename" (normpath "./filename");
		assert_equal ~printer:id "." (normpath "./")
	)
]
