open Unix

let log =
	let verbosity = try Unix.getenv "GUP_XTRACE" |> int_of_string with Not_found -> 0 in
	if verbosity > 0 then Printf.eprintf else Printf.ifprintf Pervasives.stderr

let gup_u paths =
	let args = (Array.append [| "gup"; "-u"; |] paths) in
	log "%s\n" (Array.to_list args |> String.concat " ");
	let pid = create_process "gup" args stdin stdout stderr in
	let () = match waitpid [] pid with
		| _, WEXITED 0 -> ()
		| _, _other -> exit 1
	in
	()

let () =
	(match Sys.argv with
	| [| _; out; target |] ->
		let fan_out = fun prefix ->
			(* depend on files 1-10 of the next level *)
			let base = (List.rev prefix) in
			log "base = %s\n" (String.concat "." base);
			let d i = Filename.concat "out"
				(String.concat "." (base @ [string_of_int i])) in
			gup_u [| d 0; d 1; d 2; d 3; d 4; d 5; d 6; d 7; d 8; d 9 |]
		in

		log "building %s\n" out;
		let parts = (String.split_on_char '.' (Filename.basename target)) in

		if List.length parts >= 3
			then gup_u [| "input" |]
			else fan_out parts;

		let out = open_out out in
		Printf.fprintf out "hello, from %s\n" target;
		close_out out

	| other -> failwith "Unexpected args"
	)


