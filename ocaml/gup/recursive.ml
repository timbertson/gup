open Batteries

(* A recursive structure, holding a node which may have an arbitrarily long chain of parent nodes.
 * Used for buildscripts, which are frequently single but may have (recursive) builders defined *)

type 'a relation = {
	parent: 'a t;
	child: 'a;
}
and 'a t =
	| Recurse of 'a relation
	| Terminal of 'a

let rec fold : 'a 'b. 'b -> ('b -> 'a -> 'b) -> 'a t -> 'b = fun acc fn -> function
	| Terminal t -> fn acc t
	| Recurse {parent; child} -> fn (fold acc fn parent) child

let rec map : 'a 'b. ('a -> 'b) -> 'a t -> 'b t = fun fn -> function
	| Terminal t -> Terminal (fn t)
	| Recurse {parent; child} -> Recurse { parent = (map fn parent); child = (fn child) }

let leaf = function
	| Terminal t -> t
	| Recurse {child; _} -> child

let connect ~parent child = Recurse { parent; child }
let terminal t = Terminal t

let rec print subprint out = function
	| Recurse { parent; child } ->
		Format.fprintf out "Recurse(%a, %a)" (print subprint) parent subprint child
	| Terminal t -> subprint out t
