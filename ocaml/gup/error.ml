exception Unbuildable of string
exception BuildCancelled
exception Safe_exception of (string * string list ref)

(** Convenient way to create a new [Safe_exception] with no initial context. *)
let raise_safe fmt =
  let do_raise msg = raise @@ Safe_exception (msg, ref []) in
  Printf.ksprintf do_raise fmt


(** Add the additional explanation [context] to the exception and rethrow it.
    [ex] should be a [Safe_exception] (if not, [context] is written as a warning to [stderr]).
  *)
let reraise_with_context ex fmt =
  let do_raise context =
    let () = match ex with
    | Safe_exception (_, old_contexts) -> old_contexts := context :: !old_contexts
    | _ -> Printf.eprintf "warning: Attempt to add note '%s' to non-Safe_exception!" context
    in
    raise ex
  in Printf.ksprintf do_raise fmt

