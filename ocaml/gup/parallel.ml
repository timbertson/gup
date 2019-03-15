open Batteries
open Std

module Log = (val Var.log_module "gup.par")
module ExtUnix = ExtUnix.Specific

(* because lockf is pretty much insane,
 * we must *never* close an FD that we might hold a lock
 * on elsewhere in the same process.
 *
 * So as well as lockf() based locking, we have a
 * process-wide register of locks (keyed by device_id,inode).
 *
 * To take a lock, you first need to hold the (exclusive)
 * process-level lock for that file's identity
 *
 * TODO: only use this if we're actually using --jobs=n for n>1
 *)
module FileIdentity = struct
	type device_id = | Device of int
	type inode = | Inode of int
	type t = (device_id * inode)
	let _extract (Device dev, Inode ino) = (dev, ino)
	let create stats = (Device stats.Unix.st_dev, Inode stats.Unix.st_ino)
	let compare a b =
		Tuple2.compare ~cmp1:Int.compare ~cmp2:Int.compare (_extract a) (_extract b)
end

module LockMap = struct
	include Map.Make (FileIdentity)
	let _map = ref empty
	let with_lock id fn =
		let lock =
			try find id !_map
			with Not_found -> (
				let lock = Lwt_mutex.create () in
				_map := add id lock !_map;
				lock
			)
		in
		Lwt_mutex.with_lock lock fn

	let with_process_mutex : 'a. Lwt_unix.file_descr -> (unit -> 'a Lwt.t) -> 'a Lwt.t =
	fun fd fn ->
		let%lwt stats = Lwt_unix.fstat fd in
		with_lock (FileIdentity.create stats) fn
end

(**
 * Jobpool: single-process mechanism for controlling the number of parallel jobs
 * (this can be single-process since clients submit all jobs to the root process
 * in a parallel execution)
 *)
module IntSet = Set.Make(Int)
module Jobpool = struct
	[@@@ocaml.warning "-3"]
	type waiters = unit Lwt.u Lwt_sequence.t
	type lease = {
		id: int;
		parent: int option;
	}
	type t = {
		next_id: int ref;
		num_free: int ref;
		waiters: waiters;
		leases: IntSet.t ref;
	}
	let empty parallelism =
		assert (parallelism > 0);
		{
			next_id = ref 0;
			num_free = ref parallelism;
			waiters = Lwt_sequence.create ();
			leases = ref IntSet.empty;
		}

	let string_of_lease { id; parent } =
		Printf.sprintf2 "{id=%d; parent=%a}"
			id (Option.print Int.print) parent

	(* If ID is given, it must not be an active lease
	 * (this is used for reacquiring a lease which has
	 * been transferred).
	 * Returns the ID of the lease. *)
	let acquire t ~var ~current ~lease_id : lease Lwt.t = (
		let { next_id; num_free; waiters; leases } = t in
		Log.debug var (fun m->m "acquire: num_free = %d" !num_free);
		let lease_id = match lease_id with
			| Some lease_id ->
				(* Leases aren't reentrant! *)
				assert (not (IntSet.mem lease_id !leases));
				lease_id
			| None ->
				let lease_id = !next_id in
				next_id := lease_id + 1;
				lease_id
		in

		let _acquire parent =
			let lease = { id = lease_id; parent } in
			Log.debug var (fun m->m "lease %s: acquired" (string_of_lease lease));
			leases := IntSet.add lease_id !leases;
			lease
		in

		(* only adopt the current slot if the passed in
	* is the current owner *)
		let owner = current |> Option.filter (fun lease ->
			IntSet.mem lease !leases
		) in

		match owner with
			| Some owner ->
				(* take over this lease *)
				Log.debug var (fun m->m "lease ID %d: stealing %d" lease_id owner);
				leases := IntSet.remove owner !leases;
				Lwt.return (_acquire (Some owner))
			| None -> (
				(* the parent lease isn't active, so we need to
				 * consume a new slot *)
				let current_free = !num_free in
				if current_free > 0 then (
					(* take a free slot *)
					num_free := current_free - 1;
					Lwt.return (_acquire None)
				) else (
					(* put self on the waitlist *)
					let task, waiter = Lwt.task () in
					let (_:unit Lwt.u Lwt_sequence.node) = Lwt_sequence.add_r waiter waiters in
					Lwt.map (fun () -> _acquire None) task
				)
			)
	)

	let drop ~var { num_free; waiters; leases; _ } lease = (
		Log.debug var (fun m->m "lease %s: removing ..." (string_of_lease lease));
		assert (IntSet.mem lease.id !leases);
		leases := IntSet.remove lease.id !leases;
		(* we just freed up a slot, either dequeue a waiter
		 * or increment `free` *)
		match Lwt_sequence.take_opt_l waiters with
			| Some waiter -> (
				Log.debug var (fun m->m "Waking up next waiter");
				Lwt.wakeup_later waiter ()
			)
			| None -> (
				num_free := !num_free + 1;
				Log.debug var (fun m->m "Incrementing `num_free` to %d" !num_free)
			)
	)

	(* Reacquire parent lease, after dropping the lease. If the lease is already
	 * dropped, only reacquire parent *)
	let revert ~var t lease =
		Log.debug var (fun m->m "revert(%s)" (string_of_lease lease));
		if (IntSet.mem lease.id !(t.leases)) then drop ~var t lease;
		match lease.parent with
			| None ->
					Lwt.return_unit
			| Some parent ->
				Lwt.map
					(ignore: lease -> unit)
					(acquire t ~var ~current:None ~lease_id:(Some parent))

	let use t ~var ~parent fn =
		let%lwt lease = acquire t ~var ~current:parent ~lease_id:None in
		(fn lease)[%lwt.finally
			revert ~var t lease
		]

	let use_new ~var t fn =
		let%lwt lease = acquire t ~var ~current:None ~lease_id:None in
		(fn lease)[%lwt.finally
			drop ~var t lease;
			Lwt.return_unit
		]

	let extend_env ~lease env =
		match lease with
			| None -> env
			| Some { id; _ } ->
				StringMap.add Var_global.Key.parent_lease (string_of_int id) env
	
	let is_empty t = IntSet.is_empty !(t.leases)
end


(***
 * Lock files
 *)
type lock_mode =
	| ReadLock
	| WriteLock

let lock_flag mode = match mode with
	| ReadLock -> Unix.F_RLOCK
	| WriteLock -> Unix.F_LOCK

let lock_flag_nb mode = match mode with
	| ReadLock -> Unix.F_TRLOCK
	| WriteLock -> Unix.F_TLOCK

let print_lock_mode out mode = Format.fprintf out "%s" (match mode with
	| ReadLock -> "ReadLock"
	| WriteLock -> "WriteLock"
)

type active_lock = (lock_mode * Lwt_unix.file_descr * string)

type lock_state =
	| Unlocked
	| Locked of active_lock
	| PendingLock of active_lock Lwt.t Lazy.t

exception Not_locked


(* a reentrant lock file *)
class lock_file ~var ~target lock_path =
	let current_lock = ref None in

	let do_lockf path fd flag =
		try%lwt
			Lwt_unix.lockf fd flag 0
		with Unix.Unix_error (errno, _,_) ->
			Error.raise_safe "Unable to lock file %s: %s" path (Unix.error_message errno)
	in

	let with_lock mode path f =
		(* lock file *)
		let%lwt fd = Lwt_unix.openfile path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC] 0o664 in
		
		(* ensure only one instance process-wide ever locks the given inode *)
		
		LockMap.with_process_mutex fd (fun () ->
			let%lwt () = do_lockf path fd (lock_flag mode) in
			Log.trace var (fun m->m "--Lock[%s] %a" path print_lock_mode mode);
			(
				try%lwt
					f ()
				with e -> raise e
			) [%lwt.finally (
				Log.trace var (fun m->m "Unlock[%s]" path);
				Lwt_unix.close fd
			)]
		)
	in

object
	method use : 'a. lock_mode -> (string -> 'a Lwt.t) -> 'a Lwt.t = fun mode f ->
		match !current_lock with

			(* acquire initial lock *)
			| None -> with_lock mode lock_path (fun () ->
					current_lock := Some mode;
					let rv = f target in
					current_lock := None;
					rv
				)

			(* already locked, perform action immediately *)
			| Some WriteLock -> f target

			(* other transitions not yet needed *)
			| _ -> assert false
end

