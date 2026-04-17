open Otk

(* ==== Command.of_argv ==== *)

let test_of_argv_git_status () =
  Alcotest.(check (pair string (list string)))
    "git status → porcelain -b"
    ("git", [ "status"; "--porcelain"; "-b" ])
    (Command.to_exec (Command.of_argv [ "git"; "status" ]))

let test_of_argv_git_status_passthrough_user_flags () =
  let _, args = Command.to_exec (Command.of_argv [ "git"; "status"; "-v" ]) in
  Alcotest.(check bool) "user -v is kept" true (List.mem "-v" args)

let test_of_argv_git_log_defaults () =
  let _, args = Command.to_exec (Command.of_argv [ "git"; "log" ]) in
  Alcotest.(check bool) "--oneline added"   true (List.mem "--oneline"   args);
  Alcotest.(check bool) "--no-merges added" true (List.mem "--no-merges" args);
  Alcotest.(check bool) "-20 added"         true (List.mem "-20"         args)

let test_of_argv_git_log_respects_user_count () =
  let _, args = Command.to_exec (Command.of_argv [ "git"; "log"; "-5" ]) in
  Alcotest.(check bool) "user -5 kept"    true  (List.mem "-5"  args);
  Alcotest.(check bool) "-20 not injected" false (List.mem "-20" args)

let test_of_argv_git_log_respects_user_format () =
  let _, args = Command.to_exec (Command.of_argv [ "git"; "log"; "--pretty=%s" ]) in
  Alcotest.(check bool) "--oneline not injected" false (List.mem "--oneline" args)

let test_of_argv_git_diff_adds_stat () =
  let _, args = Command.to_exec (Command.of_argv [ "git"; "diff" ]) in
  Alcotest.(check bool) "--stat added" true (List.mem "--stat" args)

let test_of_argv_git_diff_no_duplicate_stat () =
  let _, args = Command.to_exec (Command.of_argv [ "git"; "diff"; "--stat" ]) in
  let stat_count = List.length (List.filter (( = ) "--stat") args) in
  Alcotest.(check int) "--stat appears once" 1 stat_count

let test_of_argv_pytest_defaults () =
  let _, args = Command.to_exec (Command.of_argv [ "pytest" ]) in
  Alcotest.(check bool) "--tb=short added" true (List.mem "--tb=short" args);
  Alcotest.(check bool) "-q added"         true (List.mem "-q"         args)

let test_of_argv_pytest_no_duplicate_tb () =
  let _, args = Command.to_exec (Command.of_argv [ "pytest"; "--tb=long" ]) in
  Alcotest.(check bool) "--tb=short not added when user set --tb" false
    (List.mem "--tb=short" args)

let test_of_argv_passthrough () =
  Alcotest.(check (pair string (list string)))
    "unknown command passes through"
    ("cargo", [ "test" ])
    (Command.to_exec (Command.of_argv [ "cargo"; "test" ]))

let test_of_argv_cat_adds_squeeze () =
  let _, args = Command.to_exec (Command.of_argv [ "cat"; "file.txt" ]) in
  Alcotest.(check bool) "-s added" true (List.mem "-s" args)

(* ==== Filter.string_contains ==== *)

let test_string_contains_present () =
  Alcotest.(check bool) "found" true
    (Filter.string_contains ~sub:"failed" "5 failed in 0.5s")

let test_string_contains_absent () =
  Alcotest.(check bool) "not found" false
    (Filter.string_contains ~sub:"xyz" "hello world")

let test_string_contains_empty_needle () =
  Alcotest.(check bool) "empty needle always true" true
    (Filter.string_contains ~sub:"" "anything")

(* ==== Filter.filter_git_status ==== *)

let test_filter_git_status_clean () =
  Alcotest.(check string) "empty porcelain → clean" "clean"
    (Filter.filter_git_status "")

let test_filter_git_status_with_branch () =
  let output =
    "## main...origin/main\n\
     M  lib/foo.ml\n\
     ?? new.txt"
  in
  let result = Filter.filter_git_status output in
  Alcotest.(check bool) "branch line present" true
    (Filter.string_contains ~sub:"* main" result);
  Alcotest.(check bool) "modified count present" true
    (Filter.string_contains ~sub:"1 modified" result);
  Alcotest.(check bool) "untracked count present" true
    (Filter.string_contains ~sub:"1 untracked" result)

let test_filter_git_status_groups_by_type () =
  let output =
    "## dev\n\
     M  a.ml\n\
     MM b.ml\n\
     A  c.ml\n\
     D  d.ml\n\
     R  e.ml\n\
     ?? f.ml\n\
     ?? g.ml"
  in
  let result = Filter.filter_git_status output in
  Alcotest.(check bool) "2 modified" true (Filter.string_contains ~sub:"2 modified" result);
  Alcotest.(check bool) "1 added"    true (Filter.string_contains ~sub:"1 added"    result);
  Alcotest.(check bool) "1 deleted"  true (Filter.string_contains ~sub:"1 deleted"  result);
  Alcotest.(check bool) "1 renamed"  true (Filter.string_contains ~sub:"1 renamed"  result);
  Alcotest.(check bool) "2 untracked" true (Filter.string_contains ~sub:"2 untracked" result)

let test_filter_git_status_no_branch () =
  (* Porcelain without -b has no ## line *)
  let result = Filter.filter_git_status "M  foo.ml" in
  Alcotest.(check bool) "no branch prefix" false
    (Filter.string_contains ~sub:"*" result)

(* ==== Filter.filter_pytest ==== *)

let test_filter_pytest_all_pass () =
  let raw =
    {|=== test session starts ===
platform darwin
collected 5 items

tests/test_foo.py .....                    [100%]

=== 5 passed in 0.50s ===|}
  in
  Alcotest.(check string) "all pass summary"
    "Pytest: 5 passed"
    (Filter.filter_pytest raw)

let test_filter_pytest_with_failures () =
  let raw =
    {|=== test session starts ===
collected 3 items

=== FAILURES ===
___ test_bad ___
E   AssertionError

=== short test summary info ===
FAILED tests/test_foo.py::test_bad - AssertionError
=== 2 passed, 1 failed in 0.20s ===|}
  in
  let result = Filter.filter_pytest raw in
  Alcotest.(check bool) "summary line" true
    (Filter.string_contains ~sub:"2 passed, 1 failed" result);
  Alcotest.(check bool) "FAILED line kept" true
    (Filter.string_contains ~sub:"FAILED" result)

let test_filter_pytest_bare_summary () =
  (* -q mode: no === wrapper *)
  let raw = "5 failed, 1698 passed, 2 skipped in 108.89s" in
  let result = Filter.filter_pytest raw in
  Alcotest.(check bool) "bare summary parsed" true
    (Filter.string_contains ~sub:"5 failed" result);
  Alcotest.(check bool) "1698 passed" true
    (Filter.string_contains ~sub:"1698 passed" result)

let test_filter_pytest_no_tests () =
  let raw = "=== no tests ran in 0.00s ===" in
  Alcotest.(check string) "no tests collected"
    "Pytest: no tests collected"
    (Filter.filter_pytest raw)

(* ==== Filter.filter_ls ==== *)

let test_filter_ls_short () =
  let raw = "a.ml\nb.ml\nc.ml" in
  Alcotest.(check string) "short list passes through"
    "a.ml\nb.ml\nc.ml"
    (Filter.filter_ls raw)

let test_filter_ls_truncates_at_50 () =
  let lines = List.init 70 (fun i -> Printf.sprintf "file%d.txt" i) in
  let raw = String.concat "\n" lines in
  let result = Filter.filter_ls raw in
  let result_lines = String.split_on_char '\n' result in
  (* 50 files + 1 truncation line *)
  Alcotest.(check int) "51 lines total" 51 (List.length result_lines);
  Alcotest.(check bool) "truncation message" true
    (Filter.string_contains ~sub:"[... +20 more]" result)

let test_filter_ls_strips_noise_dirs () =
  let raw = "src\nnode_modules\nlib.ml\n.git\ntarget\nREADME.md" in
  let result = Filter.filter_ls raw in
  Alcotest.(check bool) "src kept"          true  (Filter.string_contains ~sub:"src"         result);
  Alcotest.(check bool) "node_modules gone" false (Filter.string_contains ~sub:"node_modules" result);
  Alcotest.(check bool) ".git gone"         false (Filter.string_contains ~sub:".git"         result);
  Alcotest.(check bool) "target gone"       false (Filter.string_contains ~sub:"target"       result)

let test_filter_ls_strips_noise_with_slash () =
  (* ls sometimes appends / to dirs *)
  let raw = "src/\nnode_modules/\nlib.ml" in
  let result = Filter.filter_ls raw in
  Alcotest.(check bool) "node_modules/ gone" false
    (Filter.string_contains ~sub:"node_modules" result)

(* ==== Suite ==== *)

let command_tests =
  [ "git status rewrite",           `Quick, test_of_argv_git_status
  ; "git status keeps user flags",  `Quick, test_of_argv_git_status_passthrough_user_flags
  ; "git log defaults",             `Quick, test_of_argv_git_log_defaults
  ; "git log respects user count",  `Quick, test_of_argv_git_log_respects_user_count
  ; "git log respects user format", `Quick, test_of_argv_git_log_respects_user_format
  ; "git diff adds --stat",         `Quick, test_of_argv_git_diff_adds_stat
  ; "git diff no duplicate --stat", `Quick, test_of_argv_git_diff_no_duplicate_stat
  ; "pytest defaults",              `Quick, test_of_argv_pytest_defaults
  ; "pytest no duplicate --tb",     `Quick, test_of_argv_pytest_no_duplicate_tb
  ; "cat adds -s",                  `Quick, test_of_argv_cat_adds_squeeze
  ; "passthrough unknown command",  `Quick, test_of_argv_passthrough
  ]

let string_contains_tests =
  [ "finds substring",      `Quick, test_string_contains_present
  ; "absent substring",     `Quick, test_string_contains_absent
  ; "empty needle is true", `Quick, test_string_contains_empty_needle
  ]

let git_status_tests =
  [ "empty output → clean",      `Quick, test_filter_git_status_clean
  ; "shows branch and counts",   `Quick, test_filter_git_status_with_branch
  ; "groups all status types",   `Quick, test_filter_git_status_groups_by_type
  ; "no branch when -b absent",  `Quick, test_filter_git_status_no_branch
  ]

let pytest_tests =
  [ "all pass",        `Quick, test_filter_pytest_all_pass
  ; "with failures",   `Quick, test_filter_pytest_with_failures
  ; "bare summary",    `Quick, test_filter_pytest_bare_summary
  ; "no tests ran",    `Quick, test_filter_pytest_no_tests
  ]

let ls_tests =
  [ "short list unchanged",      `Quick, test_filter_ls_short
  ; "truncates at 50",           `Quick, test_filter_ls_truncates_at_50
  ; "strips noise dirs",         `Quick, test_filter_ls_strips_noise_dirs
  ; "strips noise dirs (slash)", `Quick, test_filter_ls_strips_noise_with_slash
  ]

let () =
  Alcotest.run "otk"
    [ "Command.to_exec",       command_tests
    ; "Filter.string_contains", string_contains_tests
    ; "Filter.filter_git_status", git_status_tests
    ; "Filter.filter_pytest",  pytest_tests
    ; "Filter.filter_ls",      ls_tests
    ]
