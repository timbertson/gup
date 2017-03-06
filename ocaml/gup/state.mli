open Batteries
open Path

val meta_dir_name : PathComponent.name
val built_targets : string -> PathComponent.name list

type base_dependency
type 'a intermediate_dependencies

val cancel_all_future_builds : unit -> unit

class target_state : ConcreteBase.t ->
	object
		method meta_path: string -> Absolute.t
		method repr : string
		method path_repr : string

		(* async methods *)
		method perform_build : Gupfile.buildscript -> (dependencies option -> bool Lwt.t) -> bool Lwt.t
		method deps : dependencies option Lwt.t
		method add_file_dependency : ConcreteBase.t -> unit Lwt.t
		method add_file_dependencies : ConcreteBase.t list -> unit Lwt.t
		method add_file_dependency_with : mtime:(Big_int.t option) -> checksum:(string option) -> ConcreteBase.t -> unit Lwt.t
		method add_checksum : string -> unit Lwt.t
		method mark_always_rebuild : unit Lwt.t
		method mark_clobbers : unit Lwt.t
	end

and dependencies : ConcreteBase.t -> base_dependency intermediate_dependencies ->
	object
		method is_dirty : Gupfile.buildscript -> (RelativeFrom.t -> bool Lwt.t) -> bool Lwt.t
		method checksum : string option
		method clobbers : bool
		method already_built : bool
		method print : unit IO.output -> unit
	end
