(** Output filters for git, pytest, ls, cat. Pure module — no IO.
    Go-command filters live in {!Filter_go}. *)

let string_contains = Util.string_contains

let rec take_lines n = function
  | _ when n <= 0 -> []
  | [] -> []
  | x :: xs -> x :: take_lines (n - 1) xs

let ls_line_limit = 50

(** Dirs whose content is noise for LLM context (mirrors rtk). *)
let noise_dir_names =
  [
    "node_modules";
    ".git";
    "target";
    "__pycache__";
    ".next";
    "dist";
    "build";
    ".cache";
    "coverage";
    ".tox";
    ".mypy_cache";
    ".pytest_cache";
    ".venv";
    "venv";
    ".direnv";
  ]

(* ==== Shared Angstrom primitives ==== *)

let is_digit = function '0' .. '9' -> true | _ -> false
let whitespace = Angstrom.skip_while (function ' ' | '\t' -> true | _ -> false)
let rest_of_line = Angstrom.take_till (fun c -> c = '\n')
let newlines = Angstrom.skip_many1 (Angstrom.char '\n')

(* ==== Git status --porcelain -b AST ==== *)

type status_entry = { code : string; path : string }

type porcelain_line =
  | BranchLine of string  (** "## main...origin/main" *)
  | StatusEntry of status_entry

(** Parse "## <info>" — the branch header emitted by [git status -b]. *)
let branch_line_p =
  Angstrom.(string "## " *> rest_of_line >>| fun info -> BranchLine info)

(** Parse "XY<space><path>" — one file status line. *)
let status_entry_p =
  Angstrom.(
    lift2
      (fun code path -> StatusEntry { code; path })
      (take 2)
      (char ' ' *> rest_of_line))

(** Lookahead on first char to choose between the two line types. *)
let porcelain_line_p =
  Angstrom.(
    peek_char_fail >>= function
    | '#' -> branch_line_p
    | _ -> status_entry_p)

let porcelain_output_p = Angstrom.sep_by newlines porcelain_line_p

(* ==== Pytest summary parser ==== *)

(** Parse one "N label" pair, e.g. "5 passed". *)
let count_label_p =
  Angstrom.(
    lift2
      (fun digits label -> (int_of_string digits, label))
      (whitespace *> take_while1 is_digit <* whitespace)
      (take_while1 (function 'a' .. 'z' -> true | _ -> false)))

(** Handles both bare and [=== ... ===]-wrapped summary lines. *)
let pytest_summary_counts_p =
  Angstrom.(
    option () (string "===" *> whitespace *> return ())
    *> sep_by (whitespace *> char ',' <* whitespace) count_label_p)

(* ==== Filter: git status ==== *)

type status_class = Untracked | Added | Deleted | Renamed | Modified | Other

let classify_status_code = function
  | "??" -> Untracked
  | code when String.contains code 'A' -> Added
  | code when String.contains code 'D' -> Deleted
  | code when String.contains code 'R' -> Renamed
  | code when String.contains code 'M' || String.contains code 'T' -> Modified
  | _ -> Other

let has_status_class cls entry = classify_status_code entry.code = cls

let count_entries_by cls entries =
  List.length (List.filter (has_status_class cls) entries)

let format_count_pair (n, label) = Printf.sprintf "%d %s" n label
let has_nonzero_count (n, _) = n > 0

let format_status_summary entries =
  [
    (count_entries_by Modified entries, "modified");
    (count_entries_by Added entries, "added");
    (count_entries_by Deleted entries, "deleted");
    (count_entries_by Renamed entries, "renamed");
    (count_entries_by Untracked entries, "untracked");
  ]
  |> List.filter has_nonzero_count |> List.map format_count_pair |> String.concat ", "

let format_status_entry e = Printf.sprintf "%s %s" e.code e.path

let render_git_status ~branch entries =
  let branch_lines = Option.fold ~none:[] ~some:(fun b -> [ "* " ^ b ]) branch in
  let body =
    if entries = [] then [ "clean" ]
    else format_status_summary entries :: List.map format_status_entry entries
  in
  String.concat "\n" (branch_lines @ body)

let filter_git_status raw =
  match
    Angstrom.parse_string ~consume:Angstrom.Consume.Prefix porcelain_output_p
      (String.trim raw)
  with
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

(* ==== Filter: pytest ==== *)

let is_pytest_summary_line line =
  let trimmed = String.trim line in
  (string_contains ~sub:"passed" trimmed
  || string_contains ~sub:"failed" trimmed
  || string_contains ~sub:"error" trimmed)
  && string_contains ~sub:" in " trimmed

let is_pytest_failure_line line =
  let trimmed = String.trim line in
  String.starts_with ~prefix:"FAILED" trimmed
  || String.starts_with ~prefix:"ERROR" trimmed

let format_pytest_counts = function
  | [] -> "Pytest: no tests collected"
  | pairs -> "Pytest: " ^ String.concat ", " (List.map format_count_pair pairs)

let parse_counts_from_summary_line line =
  match
    Angstrom.parse_string ~consume:Angstrom.Consume.Prefix pytest_summary_counts_p
      (String.trim line)
  with
  | Ok counts -> counts
  | Error _ -> []

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
  match failure_lines with [] -> summary | fs -> summary ^ "\n" ^ String.concat "\n" fs

(* ==== Filter: ls ==== *)

let strip_trailing_slash s =
  match String.length s with
  | 0 -> s
  | n when s.[n - 1] = '/' -> String.sub s 0 (n - 1)
  | _ -> s

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

(* ==== Dispatch ==== *)

let apply cmd output =
  match cmd with
  | Command.Git (Status, _) -> filter_git_status output
  | Command.Git (Log, _) | Command.Git (Diff, _) -> String.trim output
  | Command.Go (Test, _) -> Filter_go.filter_go_test output
  | Command.Go (Build, _) -> Filter_go.filter_go_build output
  | Command.Go (Vet, _) -> Filter_go.filter_go_vet output
  | Command.Go (GoOther, _) | Command.Passthrough _ -> output
  | Command.Pytest _ -> filter_pytest output
  | Command.Ls _ -> filter_ls output
  | Command.Cat _ -> output
