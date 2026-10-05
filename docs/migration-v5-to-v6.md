# Migrate from v5 to v6

ci-templates `v6.0.0` retires runner-supplied tool custody (operator teardown
direction R70; TIN-4655). The only breaking change is in the opt-in
`rust-bazel-application.yml` workflow. Every other reusable workflow and
composite action keeps its v5 interface; their internal self-refs are raised to
the exact `@v6.0.0` release with no behaviour change.

## What changed

Up to v5, `rust-bazel-application.yml` ran a `rust-bazel-binary-custody`
action before caller checkout. It required each native runner to project a
root-owned Nix-store Bazelisk path in `TINYLAND_CI_BAZELISK_BIN`. No runner
set ever projected that fact, so every enabled native lane failed before
checkout. Requiring runners to carry build tools is a fat-runner pattern. The
action, its `custody.py`, and the runner fact are gone, and the contract check
refuses their return.

From v6, every Bazel invocation runs inside the caller repository's own flake
dev shell:

```text
nix develop --no-update-lock-file .#<nix_shell> --command <bazelisk driver> ...
```

- A new input, `nix_shell` (default `default`, the shell plain `nix develop`
  enters), names the devShell attribute. It must be a plain attribute name.
- `flake.nix` and `flake.lock` must be tracked regular files.
  `--no-update-lock-file` makes the tracked `flake.lock` the only authority for
  the Bazelisk binary.
- Before the first Bazel command the workflow resolves `bazelisk` inside that
  shell. It must be a direct `$NIX_STORE/<hash>-<name>/bin/bazelisk` output on
  the shell's `PATH`. If the shell does not provide one, the lane fails with
  `bazelisk is missing from the caller flake dev shell`.
- An impure `nix develop` appends the runner's `PATH` after the shell's own.
  A Bazelisk the shell provides shadows any runner copy. The workflow passes
  the runner's pre-shell `PATH` into the shell as `CI_RUNNER_PATH`, and the
  driver refuses a Bazelisk resolved from any of its entries, even a Nix-store
  one (NixOS systemd `path`, github-runners `extraPackages`). A profile or
  system Bazelisk that is not a direct Nix-store output is refused too.
- The runner supplies Bash, Git, Python 3, and Nix with flakes enabled, and no
  build tools.

The rest of the contract is unchanged: the pre-scheduling admission job,
pinned actions, `contents: read` permissions, finite targets, Bazel version
pinning, lock-drift checks, the environment scrubbing and
`--ignore_all_rc_files` driver, and the cache upload policy.

## Consumer steps

1. Add `bazelisk` to the devShell your Rust/Bazel lanes should use, for example
   `devShells.default = pkgs.mkShell { packages = [ pkgs.bazelisk ]; };`, and
   commit the updated `flake.lock`. A `pkgs.mkShell` shell exports `CC`, `CXX`
   and `NIX_*` variables into the Bazel client environment, and because the
   driver runs Bazel with `--ignore_all_rc_files`, Bazel's auto-configured C
   toolchain then picks up the Nix cc-wrapper. If your lanes should not, give
   them a `pkgs.mkShellNoCC` shell (for example
   `devShells.release = pkgs.mkShellNoCC { packages = [ pkgs.bazelisk ]; };`)
   and name it with `nix_shell`.
2. Re-pin the workflow call to the exact release and, if you do not use the
   default shell, name it:

   ```yaml
   jobs:
     rust:
       uses: xoxd-ai/ci-templates/.github/workflows/rust-bazel-application.yml@v6.0.0
       with:
         enabled: true
         nix_shell: default
         # ...unchanged inputs...
   ```

3. Remove any runner overlay work you staged to project
   `TINYLAND_CI_BAZELISK_BIN`. Nothing reads it.

Callers that never set `enabled: true` see no change. Other workflows can move
from `@v5.1.1` to `@v6.0.0` without edits.
