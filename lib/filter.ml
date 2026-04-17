(** Output filters. Pure module — transforms text, no IO. *)

open Angstrom

(* ==== String utilities ==== *)

(** Substring search. OCaml stdlib lacks this; we scan with String.sub. *)
let string_contains ~sub s =
  let sub_len = String.length sub and s_len = String.length s in
  if sub_len = 0 then true
  else if sub_len > s_len then false
  else
    let last_start = s_len - sub_len in
    let rec scan i =
      if i > last_start then false
      else if String.sub s i sub_len = sub then true
      else scan (i + 1)
    in
    scan 0

let take_lines n lines = List.filteri (fun i _ -> i < n) lines

let ls_line_limit = 50

(** Dirs whose content is noise for LLM context (mirrors rtk). *)
let noise_dir_names =
  [ "node_modules"; ".git"; "target"; "__pycache__"; ".next"; "dist"
  ; "build"; ".cache"; "coverage"; ".tox"; ".mypy_cache"; ".pytest_cache" ]

(* ==== Shared Angstrom primitives ==== *)

let is_digit = function '0' .. '9' -> true | _ -> false
let whitespace = skip_while (function ' ' | '\t' -> true | _ -> false)
let rest_of_line = take_while (fun c -> c <> '\n')
let newlines = skip_many1 (char '\n')

(* ==== Git status --porcelain -b AST ==== *)

type status_entry = { code : string; path : string }

type porcelain_line =
  | BranchLine of string    (** "## main...origin/main" *)
  | StatusEntry of status_entry

(** Parse "## <info>" — the branch header emitted by [git status -b]. *)
let branch_line_p =
  string "## " *> rest_of_line >>| fun info -> BranchLine info

(** Parse "XY<space><path>" — one file status line. *)
let status_entry_p =
  take 2 >>= fun code ->
  char ' ' *> rest_of_line >>| fun path -> StatusEntry { code; path }

(** Lookahead on first char to choose between the two line types.
    Mirrors the tutorial's [peek_char >>= function] pattern. *)
let porcelain_line_p =
  peek_char >>= function
  | Some '#' -> branch_line_p
  | Some _   -> status_entry_p
  | None     -> fail "empty input"

let porcelain_output_p = sep_by newlines porcelain_line_p

(* ==== Pytest summary parser ==== *)

(** Parse one "N label" pair, e.g. "5 passed".
    [<*] discards trailing whitespace without returning it. *)
let count_label_p =
  whitespace *> take_while1 is_digit <* whitespace >>= fun digits ->
  take_while1 (function 'a' .. 'z' -> true | _ -> false) >>| fun label ->
  (int_of_string digits, label)

(** Handles both bare and [=== ... ===]-wrapped summary lines.
    [option] provides the "skip if present" pattern from the tutorial. *)
let pytest_summary_counts_p =
  option () (string "===" *> whitespace *> return ()) *>
  sep_by (whitespace *> char ',' <* whitespace) count_label_p

(* ==== Filter: git status ==== *)

let classify_status_code code =
  if code = "??" then `Untracked
  else if String.contains code 'A' then `Added
  else if String.contains code 'D' then `Deleted
  else if String.contains code 'R' then `Renamed
  else if String.contains code 'M' || String.contains code 'T' then `Modified
  else `Other

let has_status_class status_class entry = classify_status_code entry.code = status_class

let count_entries_by status_class entries =
  List.length (List.filter (has_status_class status_class) entries)

let format_count_pair (n, label) = Printf.sprintf "%d %s" n label

let has_nonzero_count (n, _) = n > 0

let format_status_summary entries =
  [ count_entries_by `Modified entries, "modified"
  ; count_entries_by `Added    entries, "added"
  ; count_entries_by `Deleted  entries, "deleted"
  ; count_entries_by `Renamed  entries, "renamed"
  ; count_entries_by `Untracked entries, "untracked"
  ]
  |> List.filter has_nonzero_count
  |> List.map format_count_pair
  |> String.concat ", "

let format_status_entry e = Printf.sprintf "%s %s" e.code e.path

let render_git_status ~branch entries =
  let branch_lines = Option.fold ~none:[] ~some:(fun b -> [ "* " ^ b ]) branch in
  let body =
    if entries = [] then [ "clean" ]
    else format_status_summary entries :: List.map format_status_entry entries
  in
  String.concat "\n" (branch_lines @ body)

let filter_git_status raw =
  match parse_string ~consume:Prefix porcelain_output_p (String.trim raw) with
  | Error _ -> String.trim raw
  | Ok [] -> "clean"
  | Ok parsed ->
    let branch =
      List.find_map (function BranchLine b -> Some b | StatusEntry _ -> None) parsed
    in
    let entries =
      List.filter_map (function StatusEntry e -> Some e | BranchLine _ -> None) parsed
    in
    render_git_status ~branch entries

(* ==== Filter: git log / diff ==== *)

(* --oneline / --stat output is already compact; just clean whitespace. *)
let filter_git_log raw = String.trim raw
let filter_git_diff raw = String.trim raw

(* ==== Filter: pytest ==== *)

let is_pytest_summary_line line =
  let trimmed = String.trim line in
  (string_contains ~sub:"passed" trimmed
   || string_contains ~sub:"failed" trimmed
   || string_contains ~sub:"error" trimmed)
  && string_contains ~sub:" in " trimmed

let is_pytest_failure_line line =
  let trimmed = String.trim line in
  String.starts_with ~prefix:"FAILED" trimmed || String.starts_with ~prefix:"ERROR" trimmed

let format_pytest_counts counts =
  match counts with
  | [] -> "Pytest: no tests collected"
  | pairs ->
    "Pytest: " ^ String.concat ", " (List.map format_count_pair pairs)

let parse_counts_from_summary_line line =
  match parse_string ~consume:Prefix pytest_summary_counts_p (String.trim line) with
  | Ok counts -> counts
  | Error _   -> []

let filter_pytest raw =
  let all_lines = String.split_on_char '\n' raw in
  let summary =
    all_lines
    |> List.find_opt is_pytest_summary_line
    |> Option.map parse_counts_from_summary_line
    |> Option.map format_pytest_counts
    |> Option.value ~default:"Pytest: no tests collected"
  in
  let failure_lines = List.filter is_pytest_failure_line all_lines in
  match failure_lines with
  | [] -> summary
  | fs -> summary ^ "\n" ^ String.concat "\n" fs

(* ==== Filter: ls ==== *)

let strip_trailing_slash s =
  if String.length s > 0 && s.[String.length s - 1] = '/' then
    String.sub s 0 (String.length s - 1)
  else s

let is_visible_ls_entry line =
  let name = String.trim line |> strip_trailing_slash in
  name <> "" && not (List.mem name noise_dir_names)

let filter_ls raw =
  let visible = String.split_on_char '\n' raw |> List.filter is_visible_ls_entry in
  let total = List.length visible in
  if total <= ls_line_limit then String.concat "\n" visible |> String.trim
  else
    let shown = take_lines ls_line_limit visible in
    String.concat "\n" shown ^ Printf.sprintf "\n[... +%d more]" (total - ls_line_limit)

(* ==== Filter: cat ==== *)

(* cat -s (squeeze blank) is applied at the command level; output passes through. *)
let filter_cat raw = raw

(* ==== Dispatch ==== *)

let apply cmd output =
  match cmd with
  | Command.Git (Status, _) -> filter_git_status output
  | Command.Git (Log, _)    -> filter_git_log output
  | Command.Git (Diff, _)   -> filter_git_diff output
  | Command.Pytest _         -> filter_pytest output
  | Command.Ls _             -> filter_ls output
  | Command.Cat _            -> filter_cat output
  | Command.Passthrough _    -> output
