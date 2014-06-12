open Batteries

val meta_dir_name : string
val built_targets : string -> string list

type base_dependency
type 'a intermediate_dependencies

type 'a dirty_result =
	| Known of bool
	| Unknown of 'a

val cancel_all_future_builds : unit -> unit

class target_state : string ->
	object
		method meta_path: string -> string
		method repr : string
		method path : string

		(* async methods *)
		method perform_build : string -> (string -> dependencies option -> bool Lwt.t) -> bool Lwt.t
		method deps : dependencies option Lwt.t
		method add_file_dependency : mtime:(Big_int.t option) -> checksum:(string option) -> string -> unit Lwt.t
		method add_checksum : string -> unit Lwt.t
		method mark_always_rebuild : unit Lwt.t
		method mark_clobbers : unit Lwt.t
	end

and dependencies : string -> base_dependency intermediate_dependencies ->
	object
		method is_dirty : Gupfile.buildscript -> bool -> (target_state list) dirty_result Lwt.t
		method checksum : string option
		method clobbers : bool
		method already_built : bool
		method children : string list
		method print : unit IO.output -> unit
	end
