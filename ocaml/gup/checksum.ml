open Batteries

let build fn =
	let ctx = Sha1.init () in
	fn ctx;
	let digest = Sha1.finalize ctx in
	Sha1.to_hex digest

let pump_stream stream ctx =
	try
		while true do
			Sha1.update_string ctx (IO.nread stream 4096)
		done
	with IO.No_more_input -> ()

let from_stream input = build (pump_stream input)
let from_files files =
	build (fun ctx ->
		List.enum files |> Enum.iter (fun filename ->
			File.with_file_in filename (fun input ->
				pump_stream input ctx
			)
		)
	)
