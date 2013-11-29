open Batteries


type 'a dirty_result =
	| Known of bool
	| Unknown of 'a

class target_state : string ->
	object
		method meta_path: string -> string
		method repr : string
		method perform_build : string -> (string -> bool) -> bool
		method deps : dependencies option
		method path : string
		method add_file_dependency : mtime:(int option) -> checksum:(string option) -> string -> unit
		method add_checksum : string -> unit
		method mark_always_rebuild : unit
	end

and dependencies : IO.input ->
	object
		method is_dirty : Gupfile.builder option -> bool -> (target_state list) dirty_result
		method checksum : string option
		method already_built : bool
		method children : string list
	end
