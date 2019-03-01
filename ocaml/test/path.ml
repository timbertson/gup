open Batteries
open OUnit2

module Path = Gup.Path.Make(Mock.Fake_unix)
open Path

let print_relative_from (base,rel) =
	Printf.sprintf2 "(%s,%s)"
		(Concrete.to_string base |> String.quote)
		(Relative.to_string rel |> String.quote)

let assertRelativeFrom expected actual =
	let expected = match expected with (base, p) -> (Concrete._cast base, Relative._cast p) in
	assert_equal ~printer:print_relative_from expected actual

let assertConcrete expected actual =
	let expected = Concrete._cast expected in
	assert_equal ~printer:Concrete.to_string expected actual


let suite = "RelativeFrom.pivot_to" >:::
[
	"RelativeFrom.rebase_to rebases a relative path onto its new base" >:: (fun _ ->
		assertRelativeFrom
			("/a/tmp", "../b/c/d")
			(ConcreteBase.rebase_to
				(Concrete._cast "/a/tmp")
				(ConcreteBase._cast "/a/b/c/d"));

		assertRelativeFrom
			("/a/b/d", "../c/d")
			(ConcreteBase.rebase_to
				(Concrete._cast "/a/b/d")
				(ConcreteBase._cast "/a/b/c/d"))
	);

	"resolve absolute symlink" >:: (fun _ ->
		let state = Mock.make_state
			~links:[ "/a/b/c/link", "/dest" ]
		() in
		Mock.run ~state (fun () ->
			assertConcrete "/dest/d"
				(Concrete.resolve "/a/b/c/link/d")
		)
	);

	"resolve relative symlink" >:: (fun _ ->
		let state = Mock.make_state
			~links:[ "/a/b/c/link", "../dest" ]
		() in
		Mock.run ~state (fun () ->
			assertConcrete "/a/b/dest/d" (Concrete.resolve "/a/b/c/link/d");
			assertConcrete "/a/b" (Concrete.resolve "/a/b/c/link/..");
		)
	);

	"resolve relative" >:: (fun _ ->
		Mock.run (fun () ->
			assertConcrete "/a/b/c/d" (Concrete.resolve "/a/b/./c/d");
			assertConcrete "/a/b/c/d" (Concrete.resolve "/a/b/c/d/.");
			assertConcrete "/a/b/c/e" (Concrete.resolve "/a/b/c/d/../e")
		)
	);
]
