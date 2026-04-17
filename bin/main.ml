open Otk

let version = "0.1.0"

let usage () =
  Printf.printf
    {|otk %s — OCaml Token Killer

Usage: otk <command> [args...]

Supported filters:
  git status  → git status --porcelain -b
  git log     → git log --oneline --no-merges -20
  git diff    → git diff --stat
  go test     → go test -json  (compact pass/fail summary)
  go build    → errors only
  go vet      → issues only
  go <other>  → passthrough unchanged
  pytest      → pytest --tb=short -q  (uv run if uv.lock present)
  ls          → noise-filtered, truncate to 50 lines
  cat         → cat -s (squeeze blank lines)
  <other>     → passthrough unchanged
|}
    version

let run_command argv =
  let cmd = Command.of_argv argv in
  let exec, args = Command.to_exec cmd in
  let exec, args = Runner.resolve exec args in
  let exit_code, stdout, stderr = Runner.run exec args in
  if Util.string_contains ~sub:"not a git repository" stderr then (
    prerr_string "Not a git repository\n";
    exit_code)
  else begin
    let filtered = Filter.apply cmd stdout in
    if filtered <> "" then begin
      print_string filtered;
      if not (String.ends_with ~suffix:"\n" filtered) then print_newline ()
    end;
    if stderr <> "" then prerr_string stderr;
    exit_code
  end

let rewrite args =
  let cmd = Command.of_argv args in
  let exec, cmd_args = Command.to_exec cmd in
  let rewritten = String.concat " " (exec :: cmd_args) in
  let original = String.concat " " args in
  if rewritten <> original then print_string (rewritten ^ "\n")
  else print_string (original ^ "\n")

let () =
  let argv = match Array.to_list Sys.argv with _ :: rest -> rest | [] -> [] in
  match argv with
  | [] | [ "--help" ] | [ "-h" ] -> usage ()
  | [ "--version" ] -> Printf.printf "otk %s\n" version
  | "rewrite" :: args -> rewrite args
  | args -> exit (run_command args)
