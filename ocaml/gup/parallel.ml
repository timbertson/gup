open Batteries
open Std
open Lwt

let log = Logging.get_logger "gup.par"
module ExtUnix = ExtUnix.Specific

type lock_mode =
	| ReadLock
	| WriteLock

let lock_flag mode = match mode with
	| ReadLock -> Unix.F_RLOCK
	| WriteLock -> Unix.F_LOCK

let lock_flag_nb mode = match mode with
	| ReadLock -> Unix.F_TRLOCK
	| WriteLock -> Unix.F_TLOCK

let print_lock_mode out mode = Printf.fprintf out "%s" (match mode with
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
class lock_file path =
	let lock_path = path ^ ".lock" in
	let current_lock = ref None in

	let do_lockf path fd flag =
		try_lwt
			Lwt_unix.lockf fd flag 0
		with Unix.Unix_error (errno, _,_) ->
			Error.raise_safe "Unable to lock file %s: %s" path (Unix.error_message errno)
	in

	let lock_file mode path =
		lwt fd = Lwt_unix.openfile path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC] 0o664 in
		lwt () = do_lockf path fd (lock_flag mode) in
		log#trace "--Lock[%s] %a" path print_lock_mode mode;
		Lwt.return (mode, fd, path)
	in
		
	let release_lock current =
		lwt () = match current with
			| (_, fd, desc) ->
					log#trace "Unlock[%s]" desc;
					Lwt_unix.close fd
		in Lwt.return_unit
	in

	let with_lock mode path f =
		lwt lock = lock_file mode path in
		try_lwt
			f ()
		finally
			release_lock lock
	in

object (self)
	method use : 'a. lock_mode -> (string -> 'a Lwt.t) -> 'a Lwt.t = fun mode f ->
		match !current_lock with

			(* acquire initial lock *)
			| None -> with_lock mode lock_path (fun () ->
					current_lock := Some mode;
					let rv = f path in
					current_lock := None;
					rv
				)

			(* already locked, perform action immediately *)
			| Some WriteLock -> f path

			(* other transitions not yet needed *)
			| _ -> assert false
end

type fds = (Lwt_unix.file_descr * Lwt_unix.file_descr) option ref

let _lwt_descriptors (r,w) = (
	Lwt_unix.of_unix_file_descr ~blocking:true ~set_flags:false r,
	Lwt_unix.of_unix_file_descr ~blocking:true ~set_flags:false w
)

class fd_jobserver (read_end, write_end) toplevel =
	let _have_token = Lwt_condition.create () in
	let token = 't' in

	(* initial token held by this process *)
	let _mytoken = ref (Some ()) in
	let repeat_tokens len = String.make len token in

	(* for debugging only *)
	let _free_tokens = ref 0 in

	let _write_tokens n =
		let buf = repeat_tokens n in
		lwt written = Lwt_unix.write write_end buf 0 n in
		assert (written = n);
		Lwt.return_unit
	in

	let _read_token () =
		let buf = " " in
		let success = ref false in
		while_lwt not !success do
			(* XXX does this really return without reading sometimes? *)
			lwt n = Lwt_unix.read read_end buf 0 1 in
			let succ = n > 0 in
			success := succ;
			if not succ
			then Lwt_unix.wait_read read_end
			else Lwt.return_unit
		done
	in

	let _release n =
		log#trace "release(%d)" n;
		let n = match !_mytoken with
		| Some _ -> n
		| None ->
				(* keep one for myself *)
				_mytoken := Some ();
				Lwt_condition.signal _have_token ();
				n - 1
		in
		if n > 0 then (
			_free_tokens := !_free_tokens + n;
			log#trace "free tokens: %d" !_free_tokens;
			_write_tokens n
		) else Lwt.return_unit
	in

	let _get_token () =
		(* Get (and consume) a single token *)
		let use_mine = fun () ->
			assert (Option.is_some !_mytoken);
			_mytoken := None;
			log#trace "used my own token";
			Lwt.return_unit
		in

		match !_mytoken with
			| Some t -> use_mine ()
			| None ->
				log#trace "waiting for token...";
				lwt () = Lwt.pick [
					Lwt_condition.wait _have_token >>= use_mine;
					_read_token () >>= fun () ->
						_free_tokens := !_free_tokens - 1;
						log#trace "used a free token, there are %d left" !_free_tokens;
						Lwt.return_unit;
				] in
				log#trace "got a token";
				Lwt.return_unit
	in

	let () = Option.may (fun tokens -> Lwt_main.run (_release (tokens - 1))) toplevel in

object (self)
	method finish =
		match toplevel with
			| Some tokens ->
				(* wait for outstanding tasks by comsuming the number of tokens we started with *)
				let remaining = ref (tokens - 1) in
				let buf = repeat_tokens !remaining in
				while_lwt !remaining > 0 do
					log#debug "waiting for %d free tokens to be returned" !remaining;
					lwt n = Lwt_unix.read read_end buf 0 !remaining in
					remaining := !remaining - n;
					Lwt.return_unit
				done
			| None -> Lwt.return_unit

	method run_job : 'a. (unit -> 'a Lwt.t) -> 'a Lwt.t = fun fn ->
		lwt () = _get_token () in
		try_lwt
			fn ()
		finally
			_release 1
end

class named_jobserver path toplevel =
	let fds =
		log#trace "opening jobserver at %s" path;
		let perm = 0o000 in (* ignored, since we don't use O_CREAT *)
		let r = Unix.openfile path [Unix.O_RDONLY ; Unix.O_NONBLOCK ; Unix.O_CLOEXEC] perm in
		let w = Unix.openfile path [Unix.O_WRONLY; Unix.O_CLOEXEC] perm in
		Unix.clear_nonblock r;
		(_lwt_descriptors (r,w))
	in

	let server = new fd_jobserver fds toplevel in

object (self)
	method finish =
		lwt () = server#finish in
		let (r, w) = fds in
		lwt (_:unit list) = Lwt_list.map_p Lwt_unix.close [r;w] in

		(* delete jobserver file if we are the toplevel *)
		lwt () = Lwt_option.may (fun _ -> Lwt_unix.unlink path) toplevel in
		Lwt.return_unit

	method run_job : 'a. (unit -> 'a Lwt.t) -> 'a Lwt.t = fun fn ->
		server#run_job fn
end

class serial_jobserver =
	let lock = Lwt_mutex.create () in
object (self)
	method run_job : 'a. (unit -> 'a Lwt.t) -> 'a Lwt.t = fun fn ->
		Lwt_mutex.with_lock lock fn

	method finish = Lwt.return_unit
end

module Jobserver = struct
	let _inherited_vars = ref []
	let _impl = ref (new serial_jobserver)

	let makeflags_var = "MAKEFLAGS"
	let jobserver_var = "GUP_JOBSERVER"
	let not_required = "0"

	let _discover_jobserver () = (
		(* open GUP_JOBSERVER if present *)
		let inherit_named_jobserver path = new named_jobserver path None in
		let server = Var.get jobserver_var |> Option.map inherit_named_jobserver in
		begin match server with
			| None -> (
				(* try extracting from MAKEFLAGS, if present *)
				let flags = Var.get_or makeflags_var "" in
				let flags_re = Str.regexp "--jobserver-fds=\\([0-9]+\\),\\([0-9]+\\)" in
				let fd_ints = (
					try
						ignore @@ Str.search_forward flags_re flags 0;
						Some (
							Int.of_string (Str.matched_group 1 flags),
							Int.of_string (Str.matched_group 2 flags)
						)
					with Not_found -> None
				) in

				Option.bind fd_ints (fun (r,w) ->
					let r = ExtUnix.file_descr_of_int r
					and w = ExtUnix.file_descr_of_int w
					in
					(* check validity of fds given in $MAKEFLAGS *)
					let valid fd = ExtUnix.is_open_descr fd in
					if valid r && valid w then (
						log#trace "using fds %a"
							(Tuple.Tuple2.print Int.print Int.print) (Option.get fd_ints);

						Some (new fd_jobserver (_lwt_descriptors (r,w)) None)
					) else (
						log#warn (
							"broken --jobserver-fds in $MAKEFLAGS;" ^^
							"prefix your Makefile rule with '+'\n" ^^
							"or pass --jobs flag to gup directly to ignore make's jobserver\n" ^^
							"Assuming --jobs=1");
						ExtUnix.unsetenv makeflags_var;
						None
					)
				)
			)
			| server -> server
		end
	)

	let _create_named_pipe ():string = (
		let filename = Filename.concat
			(Filename.get_temp_dir_name ())
			("gup-job-" ^ (string_of_int @@ Unix.getpid ())) in

		let create = fun () ->
			Unix.mkfifo filename 0o600
		in
		(* if pipe already exists it must be old, so remove it *)
		begin try create ()
		with Unix.Unix_error (Unix.EEXIST, _, _) -> (
			log#warn "removing stale jobserver file: %s" filename;
			Unix.unlink filename;
			create ()
		) end;
		log#trace "created jobserver at %s" filename;
		filename
	)

	let extend_env env =
		!_inherited_vars |> List.fold_left (fun env (key, value) ->
			EnvironmentMap.add key value env
		) env

	let setup maxjobs fn = (
		(* run the job server *)
		let inherited = ref None in

		if (Var.get jobserver_var) <> (Some not_required) then (
			if Option.is_none maxjobs then begin
				(* no --jobs param given, check for a running jobserver *)
				inherited := _discover_jobserver ()
			end;

			begin match !inherited with
				| Some server -> _impl := server
				| None -> (
					(* no jobserver set, start our own *)
					let maxjobs = Option.default 1 maxjobs in
					if maxjobs = 1 then (
						log#debug "no need for a jobserver (--jobs=1)";
						_inherited_vars := (jobserver_var, not_required) :: !_inherited_vars;
					) else (
						assert (maxjobs > 0);
						(* need to start a new server *)
						log#trace "new jobserver! %d" maxjobs;

						let path = _create_named_pipe () in
						_inherited_vars := (jobserver_var, path) :: !_inherited_vars;
						_impl := new named_jobserver path (Some maxjobs)
					)
				)
			end
		);

		try_lwt
			fn ()
		finally (
			!_impl#finish
		)
	)

	let run_job fn = !_impl#run_job fn
end
