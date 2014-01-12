open Ocamlbuild_plugin ;;
dispatch begin function
| After_rules ->
	flag ["ocaml";"compile"; "lwt_debug"] & S[A"-ppopt"; A"-lwt-debug"];
	flag ["ocaml";"ocamldep"; "lwt_debug"] & S[A"-ppopt"; A"-lwt-debug"]
| _ -> ()
end;;
