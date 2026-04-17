(** Subprocess execution. Impure module — all side effects live here. *)

(** Rewrite (exec, args) for the current environment. Detects uv.lock to route pytest
    through [uv run]. *)
let resolve exec args =
  match exec with
  | "pytest" when Sys.file_exists "uv.lock" -> ("uv", "run" :: "pytest" :: args)
  | _ -> (exec, args)

let run cmd args =
  let stdout_path = Filename.temp_file "otk" ".stdout" in
  let stderr_path = Filename.temp_file "otk" ".stderr" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove stdout_path with Sys_error _ -> ());
      try Sys.remove stderr_path with Sys_error _ -> ())
    (fun () ->
      let shell_cmd =
        String.concat " " (List.map Filename.quote (cmd :: args))
        ^ " > " ^ Filename.quote stdout_path ^ " 2> " ^ Filename.quote stderr_path
      in
      let exit_code = Sys.command shell_cmd in
      let read path = In_channel.with_open_text path In_channel.input_all in
      (exit_code, read stdout_path, read stderr_path))
