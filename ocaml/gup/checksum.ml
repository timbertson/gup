module Log = (val Var.log_module "gup.checksum")

let readloop stream consumer =
	let len = 4096 in
	let buf = Bytes.make len ' ' in
	let rec loop offset: unit Lwt.t =
		let%lwt nread = Lwt_unix.read stream buf 0 len in
		if nread = 0 then
			Lwt.return_unit
		else
			let () = consumer buf 0 nread in
			loop (offset + nread)
	in
	loop 0

let pump_stream stream ctx =
	readloop stream (ctx#add_substring)

let build fn =
	let open Cryptokit in
	let ctx = Hash.sha1 () in
	let%lwt () = fn ctx in
	let bytes = ctx#result in
	Lwt.return (transform_string (Hexa.encode ()) bytes)

let from_stream ~var input =
	Log.trace var (fun m->m "building checksum from stdin");
	build (pump_stream input)

let from_files ~var files =
	Log.trace var PP.(fun m->m "building checksum from %a" (list string) files);
	build (fun ctx ->
		files |> Lwt_list.iter_s (fun filename ->
			let%lwt fd = Lwt_unix.openfile filename (Unix.[O_RDONLY]) 0600 in
			(
				pump_stream fd ctx
			)[%lwt.finally Lwt_unix.close fd]
		)
	)
