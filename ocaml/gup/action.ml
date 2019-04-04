open Parallel
open Std
open Path
open Error

module Log = (val Var.log_module "gup.action")

let _report_nobuild var path =
	(if CCOpt.is_some var.Var.parent_target then Log.trace else Log.info) var
		(fun m ->m "%s: up to date" (ConcreteBase.to_string path))

let build ~lease ~var ~update (path:string) : unit Lwt.t = (
	let parent_target = var.Var.parent_target in
	let path = RelativeFrom.concat_from var.Var.cwd (PathString.parse path) in
	try%lwt
		let%lwt () = Lwt_option.may (fun parent ->
			let path = ConcreteBase.resolve_relfrom path in
			if ConcreteBase.eq path parent then
				raise_safe "Target `%s` attempted to build itself" (ConcreteBase.to_string path);
			Lwt.return_unit
		) parent_target in

		let parent_state = parent_target |> CCOpt.map (fun path ->
			new State.target_state ~var path
		) in

		let add_intermediate_link_deps = function
			| [] -> Lwt.return_unit
			| links -> parent_state |> CCOpt.map (fun parent_state ->
				Log.trace var (fun m->m "adding %d intermediate (symlink) file dependencies"
					(List.length links));
				parent_state#add_file_dependencies links
			) |> CCOpt.get_or ~default:Lwt.return_unit
		in

		let rec build = fun (path:RelativeFrom.t) -> (
			let open Lwt in
			let traversed, path = ConcreteBase.traverse_relfrom path in
			join [
				add_intermediate_link_deps traversed;
				(
					let%lwt builder = Builder.prepare_build ~var path in
					let%lwt target = (match builder with
						| Some (`Target target) ->
							Builder.build ~lease ~var ~update target
								|> Lwt.map (fun (_:bool) -> Some (Recursive.leaf target))
						| Some (`Symlink_to path) ->
							(* recurse on destination
							 * (which will be added as a dep to parent_target)
							 *)
							let%lwt () = build path in
							Lwt.return_none
						| None -> begin
							if update && (ConcreteBase.lexists path) then (
								_report_nobuild var path;
								Lwt.return None
							) else (
								raise (Error.Unbuildable (ConcreteBase.to_string path))
							)
						end
					) in
					parent_state |> Lwt_option.may (fun (parent_state:State.target_state) ->
						let%lwt mtime = Util.get_mtime (ConcreteBase.to_string path)
						and checksum = target |> Lwt_option.bind (fun target ->
							(State.of_buildable ~var target)#deps |> Lwt.map (fun deps ->
								CCOpt.flat_map (fun deps -> deps#checksum) deps
							)
						) in
						parent_state#add_file_dependency_with ~checksum ~mtime:mtime path
					)
				);
			]
		) in
		build path
	with
		| Error.BuildCancelled -> Lwt.return_unit
		| err -> (
			begin match err with
				| Error.Target_failed (path, status, tempfile) ->
					let status_desc = match status with
						| None -> ""
						| Some i -> " with exit status " ^ (string_of_int i)
					in
					let tempfile_desc = match tempfile with
						| None -> ""
						| Some path -> " (keeping " ^ path ^ " for inspection)"
					in
					Log.err var (fun m ->m"Target `%s` failed%s%s" path status_desc tempfile_desc);
				| _ -> ()
			end;
			(* once one build fails, we tell the `State` module to just raise BuildCancelled for all
			* builds which have not yet started *)
			State.cancel_all_future_builds ();
			raise err
		)
)

let build_all ~job_info ~var ~update targets = (
	match (job_info, targets) with
		| _, [] -> assert false
		| None, targets ->
			(* no jobserver, just build in sequence *)
			Lwt_list.iter_s (build ~lease:None ~var ~update) targets

		| Some (_, lease), [target] ->
			(* single target: use existing lease *)
			build ~lease:(Some lease) ~var ~update target

		| Some (jobpool, lease), target :: targets ->
			(* multilpe tasks + jobpool, build in parallel *)
			let first_build =
				(build ~lease:(Some lease) ~var ~update target)[%lwt.finally
					(* Immediately drop the first token when done with it (may unblock further targets),
					 * the lease will revert to the parent when this function returns *)
					Jobpool.drop ~var jobpool lease;
					Lwt.return_unit
				]
			in
			let remaining_builds = List.map (fun target ->
				Jobpool.use_new ~var jobpool (fun lease ->
					build ~lease:(Some lease) ~var ~update target
				)
			) targets in
			(Lwt.join (first_build :: remaining_builds))
)
