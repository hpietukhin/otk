# otk — ocaml token killer

rewrites shell commands and filters output to save llm tokens. port of [rtk](https://github.com/rtk-ai/rtk) to save us all from Rust slop.

currently rewrites only handful of commands:
`git status` → porcelain summary   
· `git log` → oneline -20   
· `git diff` → stat  
`pytest` → tb=short -q (auto uv) 
· `ls` → no noise dirs, max 50 lines 
· `cat` → squeeze blanks  

## install

grab the binary from [releases](../../releases/latest):
```sh
curl -L .../otk-darwin-arm64 -o ~/.local/bin/otk && chmod +x ~/.local/bin/otk
```

## build from source

`otk.opam.locked` pins exact dependency versions (like `package-lock.json`). to reproduce:
```sh
opam install . --deps-only --locked && dune build
```
to update the lock file: `opam lock .` and commit `otk.opam.locked`.

## opencode
```sh
cp hooks/opencode/otk.ts ~/.config/opencode/plugins/otk.ts
echo '{ "plugin": ["file:///'"$HOME"'/.config/opencode/plugins/otk.ts"] }' > ~/.config/opencode/opencode.json
```

## usage
`otk git status` — run and filter · `otk rewrite git status` — print rewrite only
