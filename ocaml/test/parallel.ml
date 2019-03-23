open OUnit2
open Gup.Parallel
open Common
open PP

let suite = "parallelism" >:::
[
	"meets but never exceeds the expected parallelism" >:: (fun _ ->
		let parallelism = 5 in
		let num_jobs = parallelism * 10 in
		let counter = ref 0 in
		let highest_count = ref 0 in
		let job () = (
			incr counter;
			let%lwt () = Lwt_unix.sleep 0.05 in
			let current = !counter in
			if current > parallelism then (
				assert_failure
					(Printf.sprintf "%d exceeds pool parallelism (%d)" current parallelism)
			) else if current > !highest_count then (
				highest_count := current
			);
			let%lwt () = Lwt_unix.sleep 0.1 in
			decr counter;
			Lwt.return_unit
		) in
	
		let pool = Jobpool.empty parallelism in
		let rec spawn = function
			| 0 -> Lwt.return_unit
			| n -> (
				Lwt.join [
					Jobpool.use_new ~var pool (fun _lease -> job ());
					spawn (n-1);
				]
			)
		in
		Lwt_main.run (spawn num_jobs);
		assert_equal ~printer:string_of_int !highest_count parallelism
	);
	"reacquires parent lease on revert" >:: (fun _ ->
		let pool = Jobpool.empty 5 in
		Lwt_main.run Jobpool.(
			let%lwt parent = acquire pool ~var ~current:None ~lease_id:None in
			let%lwt child = acquire pool ~var ~current:(Some parent.id) ~lease_id:None in
			assert_equal ~printer:(to_string (option int)) child.parent (Some parent.id);
			assert_equal (active pool child) true;
			assert_equal (active pool parent) false;

			let%lwt () = revert ~var pool child in
			assert_equal (active pool child) false;
			assert_equal (active pool parent) true;
			Lwt.return_unit
		)
	);
	"releases lease on drop and reacquires on revert" >:: (fun _ ->
		let pool = Jobpool.empty 5 in
		Lwt_main.run Jobpool.(
			let%lwt parent = acquire pool ~var ~current:None ~lease_id:None in
			let%lwt child = acquire pool ~var ~current:(Some parent.id) ~lease_id:None in
			assert_equal ~printer:(to_string (option int)) child.parent (Some parent.id);

			drop ~var pool child;
			assert_equal (active pool child) false;
			assert_equal (active pool parent) false;

			let%lwt () = revert ~var pool child in
			assert_equal (active pool child) false;
			assert_equal (active pool parent) true;
			Lwt.return_unit
		)
	);
	"takes over parent lease if it's active" >:: (fun _ ->
		let pool = Jobpool.empty 5 in
		Lwt_main.run Jobpool.(
			let%lwt parent = acquire pool ~var ~current:None ~lease_id:None in
			let%lwt child = acquire pool ~var ~current:(Some parent.id) ~lease_id:None in
			assert_equal ~printer:(to_string (option int)) child.parent (Some parent.id);
			Lwt.return_unit
		)
	);
	"acquires a new lease if the parent is inactive" >:: (fun _ ->
		let pool = Jobpool.empty 5 in
		Lwt_main.run Jobpool.(
			let%lwt parent = acquire pool ~var ~current:None ~lease_id:None in
			Jobpool.drop ~var pool parent;
			let%lwt child = acquire pool ~var ~current:(Some parent.id) ~lease_id:None in
			assert_equal ~printer:(to_string (option int)) child.parent None;
			Lwt.return_unit
		)
	);
]
