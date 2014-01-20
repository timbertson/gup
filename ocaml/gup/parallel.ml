open Batteries
open Std
open Lwt

let log = Logging.get_logger "gup.state"
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


let do_lockf path fd flag =
	try_lwt
		Lwt_unix.lockf fd flag 0
	with Unix.Unix_error (errno, _,_) ->
		Error.raise_safe "Unable to lock file %s: %s" path (Unix.error_message errno)

let lock_file mode path =
	lwt fd = Lwt_unix.openfile path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC] 0o664 in
	lwt () = do_lockf path fd (lock_flag mode) in
	log#trace "--Lock[%s] %a" path print_lock_mode mode;
	Lwt.return (mode, fd, path)
	
let release_lock current =
	lwt () = match current with
		| (_, fd, desc) ->
				log#trace "Unlock[%s]" desc;
				Lwt_unix.close fd
	in Lwt.return_unit

let with_lock mode path f =
	lwt lock = lock_file mode path in
	try_lwt
		f ()
	finally
		release_lock lock

module Jobserver = struct
	let _fds : (Lwt_unix.file_descr * Lwt_unix.file_descr) option ref = ref None
	let read_end tup = Option.get !tup |> Tuple.Tuple2.first
	let write_end tup = Option.get !tup |> Tuple.Tuple2.second

	let _have_token = Lwt_condition.create ()
	let token = 't'

	(* MAKEFLAGS to set on children *)
	let _makeflags : string option ref = ref None

	(* initial token held by this process *)
	let _mytoken = ref (Some ())

	let makeflags_var = "MAKEFLAGS"

	let repeat_tokens len = String.make len token

	(* for debugging only *)
	let _free_tokens = ref 0

	let _write_tokens n =
		let buf = repeat_tokens n in
		lwt written = Lwt_unix.write (write_end _fds) buf 0 n in
	assert (written = n);
		Lwt.return_unit

	let _read_token () =
		let buf = " " in
		let success = ref false in
		let fd = read_end _fds in
		while_lwt not !success do
			(* XXX does this really return without writing sometimes? *)
			lwt n = Lwt_unix.read fd buf 0 1 in
			let succ = n > 0 in
			success := succ;
			if not succ
			then Lwt_unix.wait_read fd
			else Lwt.return_unit
		done

	let _release n =
		log#trace "release(%d)" n;
		let free_tokens = match !_mytoken with
		| Some _ -> n
		| None ->
				(* keep one for myself *)
				_mytoken := Some ();
				Lwt_condition.signal _have_token ();
				n - 1
		in
		if free_tokens > 0 then (
			_free_tokens := !_free_tokens + free_tokens;
			log#trace "free tokens: %d" !_free_tokens;
			_write_tokens free_tokens
		) else Lwt.return_unit

	let _release_mine () =
		match !_mytoken with
			| None -> assert false
			| Some _ -> _write_tokens 1
	
	let extract_fds flags =
		let flags_re = Str.regexp "--jobserver-fds=\\([0-9]+\\),\\([0-9]+\\)" in
		try
			ignore @@ Str.search_forward flags_re flags 0;
			Some (
				Int.of_string (Str.matched_group 1 flags),
				Int.of_string (Str.matched_group 2 flags)
			)
		with Not_found -> None

	let extend_env e =
		!_makeflags
		|> Option.map (fun flags -> EnvironmentMap.add makeflags_var flags e)
		|> Option.default e

	let setup maxjobs fn =
		(* run the job server *)
		let _toplevel = ref 0 in
		lwt () = match !_fds with
			| Some _ -> Lwt.return_unit
			| None -> (
				log#trace "setup_jobserver(%d)" maxjobs;
				let maxjobs = ref maxjobs in
				let flags = Var.get_or makeflags_var "" in
				let fd_ints = extract_fds flags in
				let fd_pair = Option.bind fd_ints (fun (a,b) ->
					let a = ExtUnix.file_descr_of_int a
					and b = ExtUnix.file_descr_of_int b
					in
					(* check validity of fds given in $MAKEFLAGS *)
					let valid fd = ExtUnix.is_open_descr fd in
					if valid a && valid b then (
						log#trace "using fds %a"
							(Tuple.Tuple2.print Int.print Int.print) (Option.get fd_ints);
						Some (a,b)
					) else (
						log#warn (
							"broken --jobserver-fds in $MAKEFLAGS;" ^^
							"prefix your Makefile rule with +\n" ^^
							"Assuming --jobs=1");
						maxjobs := 1;
						ExtUnix.unsetenv makeflags_var;
						None
					)
				) in

				let convert_fds (r,w) = (
					Lwt_unix.of_unix_file_descr ~blocking:true ~set_flags:false r,
					Lwt_unix.of_unix_file_descr ~blocking:true ~set_flags:false w
				) in

				match fd_pair with
				| Some pair -> (
						_fds := Some (convert_fds pair);
						Lwt.return_unit
					)
				| None -> (
					let maxjobs = !maxjobs in
					assert (maxjobs > 0);
					(* need to start a new server *)
					log#trace "new jobserver! %d" maxjobs;
					_toplevel := maxjobs;
					let pair = Unix.pipe () in
					_fds := Some (convert_fds pair);
					lwt () = _release (maxjobs-1) in
					let (a,b) = pair in
					let new_flags = Printf.sprintf
						"--jobserver-fds=%d,%d -j"
						(ExtUnix.int_of_file_descr a)
						(ExtUnix.int_of_file_descr b)
					in
					let modified_flags = (Var.get makeflags_var)
						|> Option.map (fun existing -> existing ^ " " ^ new_flags)
					in
					_makeflags := Some (Option.default new_flags modified_flags);
					Lwt.return_unit
				)
			)
		in
		try_lwt
			fn ()
		finally (
			(* release my token into the wild *)
			lwt () = Lwt_option.may _release_mine !_mytoken in
			Lwt.return_unit
		)

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
	
	let run_job fn =
		lwt () = _get_token () in
		try_lwt
			fn ()
		finally
			_release 1
end
