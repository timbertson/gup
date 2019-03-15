open Path
open Std

(* A buildable target, the pair of build script + target path
 * (relative from the builder's basedir, typically) *)
module Impl_ : sig
	type t
	val make : script:Absolute.t -> target:RelativeFrom.t -> t
	val target_repr : t -> string
	val target_path : t -> ConcreteBase.t
	val target : t -> RelativeFrom.t
	val script : t -> Absolute.t
	val repr : t -> string
end = struct
	type t = Absolute.t * RelativeFrom.t
	let make ~script ~target = (script, target)
	let target_repr (_script, target) = RelativeFrom.to_string target
	let target_path (_script, target) = ConcreteBase.resolve_relfrom target
	let target (_script, target) = target
	let repr (script, target) = Printf.sprintf "Buildable (%s, %s)"
			(Absolute.to_string script)
			(RelativeFrom.to_string target)
	let script (script, _target) = script
end

include Impl_
let print = ppf repr
