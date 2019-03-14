(* TODO: eventually extract into gup-rpc library *)
open Parallel

module IntMap = Map.Make(BatInt)
open Std
open Batteries
module Log = (val Var.log_module "gup.rpc")

let null_byte = "\x00"
let null_byte_re = Str.regexp null_byte
(* We used to use abstract sockets for clients, but that only works on linux, so
 * either we don't use them or we figure out a way of testing for them which
 * doesn't impact performance. *)
(* let client_address_prefix = null_byte ^ "gup/" *)
(* let client_address_of_pid_str pid = client_address_prefix ^ pid *)
(* let client_address_of_pid pid = client_address_prefix ^ (string_of_int pid) *)
let server_address pid = Filename.concat (Var_global.runtime_dir ()) ("gup-" ^ (string_of_int pid))
let display_address addr = Str.replace_first (null_byte_re) "@" addr

let max_payload = 4096

type client_state = {
	next_id : int ref;
	socket: Lwt_unix.file_descr;
	server_address: Lwt_unix.sockaddr;
	pending : bool Lwt.u IntMap.t ref;
}

module Protocol = struct
	[@@@ocaml.warning "-39"]
	type build = {
		targets: string list [@key 1];
		update: bool [@key 2];
		cwd: string [@key 3];
		indent: int [@key 4];
		parent: string [@key 5];
	} [@@deriving protobuf { protoc = "../../../gup/rpc.proto" }]

	let pp_build fmt { targets; update; cwd; indent; parent } = (
		let open CCFormat.Dump in
		Format.fprintf fmt (
			"build {"
			^^ " targets = %a;"
			^^ " update = %b;"
			^^ " cwd = %s;"
			^^ " indent = %d;"
			^^ " parent = %s;"
			^^ "}")
			(list string) targets update cwd indent parent
	)

	type request =
		| Build of build [@key 1]
	[@@deriving protobuf { protoc = "../../../gup/rpc.proto" }]

	type response =
		| Exn of string [@key 1]
		| Success of bool [@key 2]
	[@@deriving protobuf { protoc = "../../../gup/rpc.proto" }]

	type packet = {
		id: int [@key 1];
		request: request option [@key 2];
		response: response option [@key 3];
		lease_id: string option [@key 4];
	} [@@deriving protobuf { protoc = "../../../gup/rpc.proto" }]

	let encode packet =
		Protobuf.Encoder.encode_exn packet_to_protobuf packet

	let decode bytes =
		Protobuf.Decoder.decode_exn packet_from_protobuf bytes

	let request ~id ~lease request = {
		id;
		lease_id = Some (string_of_int lease);
		request = Some request;
		response = None;
	}

	let response ~id response = {
		lease_id = None;
		request = None;
		response = Some response;
		id;
	}
end


let string_of_sockaddr = let open Lwt_unix in function
	| ADDR_INET _ -> "ADDR_INET (TODO)"
	| ADDR_UNIX str -> "ADDR_UNIX " ^ (display_address str)

let listen_loop ~path ~var s handler =
	let open Lwt_unix in
	(
		let buflen = max_payload in
		let buf = Bytes.make buflen '\x00' in
		let mode = [] in
		let rec loop () =
			let%lwt (bytes_read, sender) = recvfrom s buf 0 buflen mode in
			Log.debug var (fun m->m "got %d bytes of data from %s\n" bytes_read (string_of_sockaddr sender));
			Lwt.async (fun () -> handler (Bytes.sub buf 0 bytes_read) sender);
			loop ()
		in
		loop ()
	)[%lwt.finally
		Log.trace var (fun m->m "Closing RPC socket");
		let%lwt () = close s in
		unlink path
	]

let _send socket payload addr =
	let payload_len = Bytes.length payload in
	let%lwt sent = Lwt_unix.sendto
		socket payload 0 payload_len []
		addr in
	if sent <> payload_len then failwith "sendto failed with a partial send";
	Lwt.return_unit

let bind_socket ~var s path =
	let open Lwt_unix in
	let%lwt () = try%lwt
		bind s (ADDR_UNIX path)
	with
	| Unix.Unix_error (EEXIST, _, _)
	| Unix.Unix_error (EADDRINUSE, _, _) ->
		Log.debug var (fun m->m "replacing old socket at %s" path);
		let%lwt () = unlink path in
		bind s (ADDR_UNIX path)
	in
	Lwt.return s

let make_socket () =
	let s = Lwt_unix.(socket PF_UNIX SOCK_DGRAM 0) in
	Unix.set_close_on_exec (Lwt_unix.unix_file_descr s);
	s

let serve ~var ~path ~handler fn =
	let s = make_socket () in
	Log.debug var (fun m->m "listening on socket %s\n" path);
	let%lwt s = bind_socket ~var s path in
	let server_loop = listen_loop ~path ~var s (fun bytes sender ->
		Log.debug var (fun m->m "Received message %s from sender %s" (String.escaped (Bytes.to_string bytes)) (string_of_sockaddr sender));
		let packet = Protocol.(decode bytes) in
		packet.request |> Option.map (fun request ->
			let parent_lease = match packet.lease_id with
				| Some id -> (
					try Some (int_of_string id)
					with Failure _ -> (
						Log.warn var (fun m->m "Invalid lease_id, ignoring: %s" id);
						None
					)
				)
				| None -> (
					Log.warn var (fun m->m "RPC request contains no lease_id, build may deadlock");
					None
				)
			in
			let%lwt response = (
				try%lwt handler ~id:packet.id ~parent_lease request
				with e -> (
					Log.err var (fun m->m "Server job handler failed: %s" (Printexc.to_string e));
					Lwt.return (Protocol.response ~id:packet.id (Exn (Printexc.to_string e)))
				)
			) in
			try%lwt
				_send s (Protocol.encode response) sender
			with e -> (
				Log.warn var (fun m->m "Server response failed (%s); dropping" (Printexc.to_string e));
				Lwt.return_unit
			)
		) |> Option.default_delayed (fun () ->
			Log.warn var (fun m->m "Server received packet with no request; dropping");
			Lwt.return_unit
		)
	) in
	let%lwt () = fn () in
	Log.trace var (fun m->m "Terminating RPC server");
	Lwt.cancel server_loop;
	try%lwt server_loop
	with Lwt.Canceled -> (
		Lwt.return_unit
	)

let connect ~var ~server fn =
	let open Lwt_unix in
	let s = make_socket () in
	let path = server_address (Unix.getpid ()) in
	Log.debug var (fun m->m "connecting to server %s from %s" server path);
	let%lwt () = Lwt_unix.bind s (ADDR_UNIX path) in
	let state = {
		next_id = ref 0;
		socket = s;
		server_address = ADDR_UNIX server;
		pending = ref IntMap.empty;
	} in

	let usage = fn state in
	let loop = listen_loop ~path ~var state.socket (fun bytes _sender ->
		let open Protocol in
		let { id; response; _ } = decode bytes in
		match response with
			| Some (Success success) ->
				Lwt.return (match IntMap.find_opt id !(state.pending) with
					| Some resolver -> Lwt.wakeup_later resolver success
					| None -> Log.warn var (fun m->m "Received response for unknown request ID %d" id)
				)
			| Some (Exn err) -> failwith err
			| None -> failwith "No response field present"
	) in
	Lwt.pick [ usage; loop ]


let build ~lease ~state cmd =
	let id = !(state.next_id) in
	state.next_id := id + 1;

	let payload = Protocol.(encode (request ~id ~lease (Build cmd))) in
	let t, resolve = Lwt.task () in
	state.pending := IntMap.add id resolve !(state.pending);

	(try%lwt
		let%lwt () = _send state.socket payload state.server_address in
		t
	with e -> raise e) [%lwt.finally
		state.pending := IntMap.remove id !(state.pending);
		Lwt.return_unit
	]


module Server = struct
	let setup ~var maxjobs fn = (
		(* run `fn` with an active jobserver (if required) *)
		if Var_global.is_root then (
			if maxjobs = 1 then (
				(* TODO: allow opting into RPC server without parallelism? *)
				Log.debug var (fun m->m "no need for an RPC server (--jobs=1)");
				fn None
			) else (
				assert (maxjobs > 1);
				(* need to start a new server *)
				Log.trace var (fun m->m "new RPC server! %d" maxjobs);
				let pid = Unix.getpid () in
				let path = server_address pid in
				Var_global.set_rpc_server path;
				let jobs = Jobpool.empty maxjobs in
				serve ~var ~path ~handler:(fun ~id ~parent_lease request ->
					match request with
						| Build build -> (
							let open Protocol in
							Log.info var (fun m->m "got build request: %a" pp_build build);

							Jobpool.use jobs ~var ~parent:parent_lease (fun lease ->
								let var = Var.{
									indent = build.indent;
									indent_str = indent_str build.indent;
									cwd = Path.Concrete.of_string build.cwd;
									parent_target = Some (Path.ConcreteBase._cast build.parent);
								} in
								try%lwt
									let%lwt () = Action.build_all ~var ~job_info:(Some (jobs,lease))
										~update:build.update build.targets in
									Lwt.return (response ~id (Success true))
								with _ ->
									Lwt.return (response ~id (Success false))
							)
						)
				) (fun () ->
					(* run `fn` with an active lease *)
					let%lwt () = Jobpool.use_new ~var jobs (fun lease ->
						fn (Some (jobs, lease))
					) in
					if not (Jobpool.is_empty jobs)
						then failwith "Error: not all tokens returned to Jobpool";
					Lwt.return_unit
				)
			)
		) else (
			(* not root, job control is not my responsibility *)
			fn None
		)
	)
end
