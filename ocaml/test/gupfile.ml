open Batteries
open OUnit2
open Gup.Gupfile
open Gup

let possible_gup_files path = List.of_enum (possible_builders path)
let print_str_list lst = "[ " ^ (lst |> String.concat "\n") ^ " ]"
let map_repr = List.map(fun x -> x#repr)
let custom_printf fn obj = Printf.sprintf2 "%a" fn obj
let lift_compare m f a b = m (f a) (f b)
let eq cmp a b = (cmp a b) = 0
let compare_gupfile =
	let compare_rule = lift_compare String.compare (fun r -> r#text) in
	let compare_rules = lift_compare (List.compare compare_rule) (fun r -> r#rules) in
	let compare_string_and_rules = (Tuple2.compare ~cmp1:String.compare ~cmp2:compare_rules) in
	eq @@ List.compare compare_string_and_rules

let suite = "Gupfile" >:::
[
	"gupfile search paths" >:: (fun _ ->
		assert_equal
			~printer: print_str_list
			[
				"/a/b/c/d/e.gup (e)";
				"/a/b/c/d/[gup]/e.gup (e)";
				"/a/b/c/[gup]/d/e.gup (e)";
				"/a/b/[gup]/c/d/e.gup (e)";
				"/a/[gup]/b/c/d/e.gup (e)";
				"/[gup]/a/b/c/d/e.gup (e)";
				"/a/b/c/d/Gupfile (e)";
				"/a/b/c/d/[gup]/Gupfile (e)";
				"/a/b/c/[gup]/d/Gupfile (e)";
				"/a/b/[gup]/c/d/Gupfile (e)";
				"/a/[gup]/b/c/d/Gupfile (e)";
				"/[gup]/a/b/c/d/Gupfile (e)";
				"/a/b/c/Gupfile (d/e)";
				"/a/b/c/[gup]/Gupfile (d/e)";
				"/a/b/[gup]/c/Gupfile (d/e)";
				"/a/[gup]/b/c/Gupfile (d/e)";
				"/[gup]/a/b/c/Gupfile (d/e)";
				"/a/b/Gupfile (c/d/e)";
				"/a/b/[gup]/Gupfile (c/d/e)";
				"/a/[gup]/b/Gupfile (c/d/e)";
				"/[gup]/a/b/Gupfile (c/d/e)";
				"/a/Gupfile (b/c/d/e)";
				"/a/[gup]/Gupfile (b/c/d/e)";
				"/[gup]/a/Gupfile (b/c/d/e)";
				"/Gupfile (a/b/c/d/e)";
				"/[gup]/Gupfile (a/b/c/d/e)"
			]
			(possible_gup_files("/a/b/c/d/e") |> map_repr)
		;

		assert_equal
			~printer: print_str_list
			[
				"x/y/somefile.gup (somefile)";
				"x/y/[gup]/somefile.gup (somefile)";
				"x/[gup]/y/somefile.gup (somefile)"
			]
			(possible_gup_files("x/y/somefile") |> List.take 3 |> map_repr)
		;

		assert_equal
			~printer: print_str_list
			[
				"/x/y/somefile.gup (somefile)";
				"/x/y/[gup]/somefile.gup (somefile)";
				"/x/[gup]/y/somefile.gup (somefile)"
			]
			(possible_gup_files "/x/y/somefile" |> List.take 3 |> map_repr)
		;

		assert_equal
			~printer: print_str_list
			[
				"./somefile.gup (somefile)";
				"./[gup]/somefile.gup (somefile)";
			]
			(possible_gup_files("somefile") |> List.take 2 |> map_repr)
	)

	; "gupfile parsing" >:: (fun _ ->
		assert_equal
		~printer: (custom_printf print_gupfile)
		~cmp: (compare_gupfile)
		[
			("foo.gup", new match_rules [
				new match_rule "foo1";
				new match_rule "foo2"]
			);
			("bar.gup", new match_rules [
				new match_rule "bar1";
				new match_rule "bar2"]
			)
		]
		(parse_gupfile @@ IO.input_string (
			String.concat "\n" [
				"foo.gup:";
				" foo1";
				"# comment";
				"";
				"\t foo2";
				"# comment";
				"ignoreme:";
				"bar.gup :";
				" bar1\t ";
				"    bar2";
			])
		)
	)

	; "rule parsing" >:: (fun _ ->
		assert_equal ~printer:identity "^[^/]*$"         (regexp_of_rule "*");
		assert_equal ~printer:identity "^.*$"            (regexp_of_rule "**");
		assert_equal ~printer:identity "^foo.*bar[^/]*$" (regexp_of_rule "foo**bar*");
	)
]
