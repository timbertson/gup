(* Copyright (C) 2013, Thomas Leonard
 * See the ZeroInstall README file for details, or visit http://0install.net.
 *)

open Batteries
open Error
let logger = Logging.get_logger "gup.utils"

type 'a result =
  | Success of 'a
  | Problem of exn

type filepath = string
type varname = string


let on_windows = Filename.dir_sep <> "/"

(** The string used to separate paths (":" on Unix, ";" on Windows). *)
let path_sep = if on_windows then ";" else ":"

(** Join a relative path onto a base.
    @raise Safe_exception if the second path is not relative. *)
let (+/) a b =
  if b = "" then
    a
  else if Filename.is_relative b then
    Filename.concat a b
  else
    raise_safe "Attempt to append absolute path: %s + %s" a b

type path_component =
  | Filename of string  (* foo/ *)
  | ParentDir           (* ../ *)
  | CurrentDir          (* ./ *)
  | EmptyComponent      (* / *)

let finally_do cleanup resource f =
  let result =
    try f resource
    with ex -> cleanup resource; raise ex in
  let () = cleanup resource in
  result

let safe_to_string = function
  | Safe_exception (msg, contexts) ->
      Some (msg ^ "\n" ^ String.concat "\n" (List.rev !contexts))
  | _ -> None

let () = Printexc.register_printer safe_to_string

let _try_stat stat path =
  try
    Some (stat path)
  with Unix.Unix_error (errno, _, _) as ex ->
    if errno = Unix.ENOENT then None
    else raise ex

let try_lstat = _try_stat Unix.lstat
let try_stat = _try_stat Unix.stat

let makedirs ?(mode=0o777) path =
  let rec loop path =
    let assert_dir st =
      if st.Unix.st_kind <> Unix.S_DIR then raise_safe "Not a directory: %s" path
    in
    match try_stat path with
    | Some info -> assert_dir info
    | None ->
        let parent = (Filename.dirname path) in
        assert (path <> parent);
        loop parent;
        try
          Unix.mkdir path mode
        with Unix.Unix_error (Unix.EEXIST, _, _) -> (
          assert_dir (Unix.stat path)
        )
  in
  try loop path
  with Safe_exception _ as ex -> reraise_with_context ex "... creating directory %s" path

let string_tail s i =
  let len = String.length s in
  if i > len then failwith ("String '" ^ s ^ "' too short to split at " ^ (string_of_int i))
  else String.sub s i (len - i)

let is_absolute path = not (Filename.is_relative path)

(** Find the next "/" in [path]. On Windows, also accept "\\".
    Split the path at that point. Multiple slashes are treated as one.
    If there is no separator, returns [(path, "")]. *)
let split_path_str path =
  let l = String.length path in
  let is_sep c = (c = '/' || (on_windows && c = '\\')) in

  (* Skip any leading slashes and return the rest *)
  let rec find_rest i =
    if i < l then (
      if is_sep path.[i] then find_rest (i + 1)
      else string_tail path i
    ) else (
      ""
    ) in

  let rec find_slash i =
    if i < l then (
      if is_sep path.[i] then (String.sub path 0 i, find_rest (i + 1))
      else find_slash (i + 1)
    ) else (
      (path, "")
    )
  in
  find_slash 0

(** Split off the first component of a pathname.
    "a/b/c" -> (Filename "a", "b/c")
    "a"     -> (Filename "a", "")
    "/a"    -> (EmptyComponent, "a")
    "/"     -> (EmptyComponent, "")
    ""      -> (CurrentDir, "")
  *)
let split_first path =
  if path = "" then
    (CurrentDir, "")
  else (
    let (first, rest) = split_path_str path in
    let parsed =
      if first = Filename.parent_dir_name then ParentDir
      else if first = Filename.current_dir_name then CurrentDir
      else if first = "" then EmptyComponent
      else Filename first in
    (parsed, rest)
  )

let normpath path : filepath =
  let rec explode path =
    match split_first path with
    | CurrentDir, "" -> []
    | CurrentDir, rest -> explode rest
    | first, "" -> [first]
    | first, rest -> first :: explode rest in

  let rec remove_parents = function
    | checked, [] -> checked
    | (Filename _name :: checked), (ParentDir :: rest) -> remove_parents (checked, rest)
    | checked, (first :: rest) -> remove_parents ((first :: checked), rest) in

  let to_string = function
    | Filename name -> name
    | ParentDir -> Filename.parent_dir_name
    | EmptyComponent -> ""
    | CurrentDir -> assert false
  in

  let parts = remove_parents ([], explode path) in

  match parts with
    | [] -> "."
    | _  -> String.concat Filename.dir_sep @@ List.rev_map to_string parts

let abspath path =
  normpath (
    if is_absolute path then path
    else (Unix.getcwd ()) +/ path
  )

let walk root fn : unit =
  let rec _walk path =
    let contents = Sys.readdir path in
    let (dirs, files) = List.partition (fun name -> Sys.is_directory (path +/ name)) (Array.to_list contents) in
    let dirs = fn path dirs files in
    Batteries.List.enum dirs |> Batteries.Enum.iter (fun dir -> _walk dir)
  in
  _walk root

let readdir path =
  try Success (Sys.readdir path)
  with Sys_error _ as ex -> Problem ex

let rmtree root =
  try
    let rec rmtree path =
      match try_lstat path with
      | None -> failwith ("Path " ^ path ^ " does not exist!")
      | Some info ->
        match info.Unix.st_kind with
        | Unix.S_REG | Unix.S_LNK | Unix.S_BLK | Unix.S_CHR | Unix.S_SOCK | Unix.S_FIFO ->
            Unix.unlink path
        | Unix.S_DIR -> (
            match readdir path with
            | Success files ->
                Array.iter (fun leaf -> rmtree @@ path +/ leaf) files;
                Unix.rmdir path
            | Problem ex -> raise_safe "Can't read directory '%s': %s" path (Printexc.to_string ex)
      ) in
    rmtree root
  with Safe_exception _ as ex -> reraise_with_context ex "... trying to delete directory %s" root

let slice ~start ?stop lst =
  let from_start = Batteries.List.drop start lst in
  match stop with
  | None -> from_start
  | Some stop -> Batteries.List.take (stop - start) from_start

