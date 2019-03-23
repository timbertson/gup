open Batteries
module Log = (val Var.log_module "gup.checksum")

let build fn =
	let open Cryptokit in
	let ctx = Hash.sha1 () in
	fn ctx;
	let bytes = ctx#result in
	transform_string (Hexa.encode ()) bytes

let pump_stream ?(nread = IO.nread) stream ctx=
	try
		while true do
			ctx#add_string (nread stream 4096)
		done
	with IO.No_more_input -> ()

(* TODO: is this really necessary? *)
let nread_ignoring_closed stream len =
	try
		IO.nread stream len
	with IO.Input_closed -> raise IO.No_more_input

let from_stream ~var input =
	Log.trace var (fun m->m "building checksum from stdin");
	build (pump_stream ~nread:nread_ignoring_closed input)

let from_files ~var files =
	Log.trace var PP.(fun m->m "building checksum from %a" (list string) files);
	build (fun ctx ->
		List.enum files |> Enum.iter (fun filename ->
			File.with_file_in filename (fun input ->
				pump_stream input ctx
			)
		)
	)
