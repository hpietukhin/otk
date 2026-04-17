(** Command ADT: parse argv → command, then rewrite → (exec, args). Pure module — no side
    effects. *)

type git_cmd = Status | Log | Diff

type t =
  | Git of git_cmd * string list
  | Pytest of string list
  | Ls of string list
  | Cat of string list
  | Passthrough of string * string list

let of_argv = function
  | "git" :: "status" :: rest -> Git (Status, rest)
  | "git" :: "log" :: rest -> Git (Log, rest)
  | "git" :: "diff" :: rest -> Git (Diff, rest)
  | "pytest" :: rest -> Pytest rest
  | "ls" :: rest -> Ls rest
  | "cat" :: rest -> Cat rest
  | cmd :: rest -> Passthrough (cmd, rest)
  | [] -> Passthrough ("", [])

(* ---- Arg-flag detectors (string list -> bool) ---- *)

let is_format_flag s =
  s = "--oneline"
  || String.starts_with ~prefix:"--pretty" s
  || String.starts_with ~prefix:"--format" s

let has_format_flag args = List.exists is_format_flag args

(** Matches [-5], [-n5], [--max-count=5] — any user-supplied commit count. *)
let is_commit_count_arg s =
  String.starts_with ~prefix:"-n" s
  || String.starts_with ~prefix:"--max-count" s
  || (String.length s >= 2 && s.[0] = '-' && s.[1] >= '0' && s.[1] <= '9')

let has_commit_count_flag args = List.exists is_commit_count_arg args

let has_merge_flag args =
  List.exists (fun s -> s = "--merges" || s = "--min-parents=2") args

let has_stat_flag args =
  List.exists (fun s -> s = "--stat" || s = "--numstat" || s = "--shortstat") args

let has_traceback_flag args = List.exists (String.starts_with ~prefix:"--tb") args
let has_quiet_flag args = List.exists (fun s -> s = "-q" || s = "--quiet") args

(** Prepend [flag] to [args] unless [present args] is true. *)
let ensure_unless flag present args = if present args then args else flag :: args

(** Rewrite command into (executable, args) with compact flags. Pure: no filesystem or env
    access. *)
let to_exec = function
  | Git (Status, user_args) -> ("git", "status" :: "--porcelain" :: "-b" :: user_args)
  | Git (Log, user_args) ->
      let args =
        user_args
        |> ensure_unless "--oneline" has_format_flag
        |> ensure_unless "-20" has_commit_count_flag
        |> ensure_unless "--no-merges" has_merge_flag
      in
      ("git", "log" :: args)
  | Git (Diff, user_args) ->
      let args = ensure_unless "--stat" has_stat_flag user_args in
      ("git", "diff" :: args)
  | Pytest user_args ->
      let args =
        user_args
        |> ensure_unless "--tb=short" has_traceback_flag
        |> ensure_unless "-q" has_quiet_flag
      in
      ("pytest", args)
  | Ls user_args -> ("ls", user_args)
  | Cat user_args -> ("cat", ensure_unless "-s" (List.mem "-s") user_args)
  | Passthrough (cmd, user_args) -> (cmd, user_args)
