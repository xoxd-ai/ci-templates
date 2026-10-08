# JS Bazel Package Workflow

`js-bazel-package.yml` is the reusable validation workflow for JavaScript and
TypeScript packages whose authoritative artifact is built by Bazel.

**It publishes nothing (RU8, operator ruling 2026-10-08).** Bazel is the only
distribution path for in-house packages: a release is a signed tag plus a
registry module that consumers take as a `bazel_dep` and link with
`npm_link_package` (RU6, RU9). The npmjs and GitHub Packages publish jobs and
their publish dry-runs are gone. See [Migrating off publication
(RU8)](#migrating-off-publication-ru8).

It is meant for packages like:

- `@tummycrypt/scheduling-kit`
- `@tummycrypt/tinyvectors`
- `@tummycrypt/scheduling-bridge`

## What it does

- makes runner intent explicit with `runner_mode`
- makes workspace hygiene explicit with `workspace_mode`
- installs the workspace with pnpm
- configures Attic and Bazel cache hints on self-hosted runners
- optionally keeps legacy cleanup-based workspace behavior for migration
- optionally stages validation work in an isolated scratch workspace
- runs optional metadata, lint, typecheck, unit, and integration commands
- builds the workspace artifact
- validates the Bazel-built package shape via `npm pack --dry-run` (a tarball
  shape check only; nothing is uploaded to a registry)
- uploads the Bazel-built package tarball as a workflow artifact for inspection
- fails closed when a caller still requests a real publication (RU8)

## Contract inputs

### `runner_mode`

Allowed values:

- `compat`
- `shared`
- `repo_owned`

`hosted` was **retired by TIN-3914** (`v3.0.0`) and is now rejected with a
migration error. The estate has no GitHub-hosted runners; see
[`migration-v2-to-v3.md`](migration-v2-to-v3.md).

Meaning:

- `compat`
  - preserve the legacy `runner_labels_json` behavior
  - use this only as a migration bridge
  - since `v3.0.0` the unset default resolves to `["tinyland-nix"]` (it was
    `["ubuntu-latest"]`), and a GitHub-hosted label passed here is rejected
- `shared`
  - validate on a documented shared GloriousFlywheel lane
  - pass a non-empty `shared_runner_labels_json`; an empty value is rejected
    because it usually means the caller repo variable is missing
  - labels must include an org capability-class label
- `repo_owned`
  - validate on a repo/owner-scoped runner registration path
  - workflow-facing labels still stay org capability classes
  - labels must include an org capability-class label

`repo_owned` is a trust and registration boundary, not permission to mint
known repo-label fossils. GloriousFlywheel keeps runner labels capability-based
(`tinyland-nix`, `great-falls-tool-bus-nix`, and related classes); owner/repo
separation belongs in ARC registration identity, runner groups, GitHub App
installation, and implementation-overlay policy.

### `workspace_mode`

Allowed values:

- `isolated`
- `persistent_compat`

Meaning:

- `isolated`
  - checkout normally
  - copy the repo into a per-job scratch directory under `$RUNNER_TEMP`
  - run validation there
- `persistent_compat`
  - keep the old cleanup-based model for long-lived self-hosted workspaces

### Retired publication inputs (RU8)

`publish_mode`, `npm_access`, `npm_publish_provenance`, `npm_publish_mode`,
`npm_registry_url`, `github_package_name`, `github_package_registry`, `dry_run`
and `publish_on_tag`, plus the `NPM_TOKEN` and `TINYLAND_GITHUB_PACKAGES_TOKEN`
secrets, are still declared so a caller that passes them keeps parsing (an
undeclared `workflow_call` input is a hard startup error). They no longer do
anything, with one fail-closed exception and some warnings:

- A caller that **would have published** fails the validate job with an RU8
  migration error. That is a publication request (`dry_run: false`, or
  `publish_on_tag: true` on a `push` of a tag) together with a publication
  target (`npm_publish_mode` other than `disabled`, or a non-empty
  `github_package_name`).
- A publication request with no target only warns: it published nothing
  before RU8 either (for example `npm_publish_mode: disabled`, no
  `github_package_name`, `dry_run: false`), so it is not broken now.
- `publish_on_tag: true` off a tag push, and a non-empty
  `github_package_name`, warn.
- `publish_mode: hosted_exception` and an unknown `npm_publish_mode` are still
  rejected exactly as before.

A caller that asked to publish is therefore told so, rather than going green
without a release.

### `cache_backed`

Opt-in (default `false`) shared-cache-backed Bazel validation. This is the
TIN-2110 cache-first enrollment surface (TIN-1997 Option D, proven by GF#889).

- `false` / unset (default)
  - the Bazel target validation runs the existing plain
    `npx --yes @bazel/bazelisk build <targets> --verbose_failures` path,
    byte-identically. Non-opted consumers see zero behavior change.
- `true`
  - the consumer's `tinyland.repo.json` is validated against the vendored
    ci-templates schema (network-free); an invalid manifest **fails closed**
    (TIN-2109)
  - a fail-closed cache-attachment contract step runs next
    (`scripts/cache-attachment-contract.sh --strict`), rejecting unexpanded
    `${...}` placeholders, non-`grpc`/`http` endpoints, and localhost endpoints
    (unless `GF_BAZEL_ALLOW_LOCALHOST_PROOF=true`)
  - the contract's **expected mode is manifest-driven** (TIN-2109): it is read
    from `enrollment.substrateMode` in `tinyland.repo.json`. If the manifest
    declares `shared-cache-backed` but no cache actually attaches, the lane
    **fails closed** (declared-vs-actual mismatch) instead of silently degrading
  - the workflow exports `GF_FLYWHEEL_PROFILE_STATE` from the resolved substrate
    mode so consumer `flywheel-doctor` / `flywheel-verify` commands see the
    same machine-readable attachment state as CI
  - the contract **rejects hosted / non-cluster runner fallback**: the runner
    labels are inspected and a GitHub-hosted (`ubuntu-*`), bare `self-hosted`, or
    known repo-label fossil is a deterministic failure, never a silent degrade
    to a hosted build (override only with
    `GF_BAZEL_ALLOW_HOSTED_RUNNER=true`)
  - the Bazel validation then runs
    `--config=ci-cached --remote_cache=$BAZEL_REMOTE_CACHE
    --remote_upload_local_results=false`, reading the shared Bazel cache
  - the lane fails closed when `BAZEL_REMOTE_CACHE` is unset rather than
    silently building local-only

`cache_backed` is **cache-first only**. It never wires a remote executor; REAPI /
remote execution is out of scope for this lane (the workflow contains no
executor flag or endpoint). On self-hosted Tinyland cluster runners, `nix-setup`
exports `BAZEL_REMOTE_CACHE` from cluster DNS, so attach needs no new secret or
infrastructure; off-cluster, supply the endpoint via a repo/org secret or a
wrapping step before validation.

The contract script also **defines and enforces** the `executor-backed` contract
for any repo that declares `enrollment.substrateMode: executor-backed`: it then
requires the full set (remote executor endpoint + `BAZEL_REMOTE_CACHE` + a
cluster runner class for platform identity + a digest-pinned REAPI proof image,
`GF_BAZEL_REAPI_PROOF_IMAGE_DIGEST`) and fails closed if any piece is missing.
**No current repo selects executor-backed** (cache-first / Option D); the contract
is defined so the gate is enforceable the moment a repo declares it.

Consumers opting in must:

1. set `cache_backed: true` in the `with:` block
2. vendor `bazelrc/ci-cached.bazelrc` behavior in their `.bazelrc` (a base `:ci`
   config that empties `--disk_cache=` in CI plus the `:ci-cached` block) so a
   green build proves the **remote** cache, not an incidental disk hit
3. optionally vendor `scripts/cache-attachment-contract.sh` for the same
   fail-closed self-check locally (`scripts/cache-attachment-contract.sh
   --strict`); the workflow falls back to fetching the pinned ci-templates copy
   when the consumer has not vendored it

Real enrollment is proven by remote cache hit/transfer lines in the cache-backed
validation step log. A green build that shows only `--disk_cache` and no remote
transfer is **not** enrollment.

When the consumer has not vendored `scripts/cache-attachment-contract.sh`, the
workflow fetches it from an **immutable releasing tag** (the fallback ref is
pinned to `v2.5.1`, not the floating `v2` major), so pure-consumer spokes get a
reproducible fetch.

### `substrate_mode`

Optional operator override for the cache-backed lane's expected substrate mode
(`compatibility-local-only` | `shared-cache-backed` | `executor-backed`). It is
used **only** when `cache_backed: true` and the consumer's `tinyland.repo.json`
does not declare `enrollment.substrateMode` — the manifest is the authoritative
source (TIN-2109). When both are empty the lane defaults to
`shared-cache-backed`. This input has no effect on the default
(non-cache-backed) path.

## Example: repo-owned capability-class package path

```yaml
name: CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  package:
    uses: tinyland-inc/ci-templates/.github/workflows/js-bazel-package.yml@v2.0.0
    with:
      runner_mode: repo_owned
      runner_labels_json: ${{ vars.PRIMARY_LINUX_RUNNER_LABELS_JSON }}
      workspace_mode: isolated
      prepare_command: pnpm exec svelte-kit sync
      metadata_check_command: pnpm check:release-metadata
      lint_command: pnpm lint
      typecheck_command: pnpm check
      unit_test_command: pnpm test:unit
      integration_test_command: pnpm test:integration
      build_command: pnpm build
      package_check_command: pnpm check:package
      bazel_targets: "//:typecheck //:pkg //:test"
      package_dir: ./bazel-bin/pkg
    secrets: inherit
```

In that example, `PRIMARY_LINUX_RUNNER_LABELS_JSON` must resolve to a
capability-shaped label set such as `["self-hosted","linux","tinyland-nix"]`
or `["self-hosted","linux","great-falls-tool-bus-nix"]`.
It must not resolve to a known repo-label fossil. Pull-request validation remains
safe for forks because the workflow has no publish jobs and holds no publish
secrets; the only token it reads is the read-only registry fetch credential.

## Example: capability-class template consumer

```yaml
on:
  push:
    tags: ['v*']
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  package:
    uses: tinyland-inc/ci-templates/.github/workflows/js-bazel-package.yml@v3.0.0
    with:
      runner_mode: repo_owned
      runner_labels_json: '["tinyland-nix"]'
      workspace_mode: isolated
      lint_command: pnpm lint
      typecheck_command: pnpm typecheck
      unit_test_command: pnpm test
      build_command: pnpm build
      bazel_targets: "//:pkg"
      package_dir: ./bazel-bin/pkg
```

## Notes

- `compat` exists only to let existing consumers adopt the new template without
  breaking in one PR.
- `runner_mode=repo_owned` must pass explicit `runner_labels_json` and that
  label set must include an org capability-class label. It does not authorize
  known repo-label fossils.
- `runner_mode=shared` uses `shared_runner_labels_json`. The workflow resolves
  the selected labels in a small `resolve-runner` setup job, then passes simple
  JSON outputs into `runs-on` to avoid the complex inline expressions that
  previously caused GitHub Actions startup failures before jobs were created.
  Since TIN-3914 that setup job itself runs on `tinyland-nix`: it is on the
  critical path of every invocation, so leaving it hosted would have kept a
  GitHub-hosted runner in every run.
- `runner_mode=shared` rejects an explicitly empty `shared_runner_labels_json`.
  This catches missing caller repo variables before the workflow silently falls
  back to the default shared runner class.
- Package repos that need fork-safe owned capacity should prefer
  `runner_mode=repo_owned` with explicit capability-shaped
  `runner_labels_json`. Packages that do not need cluster-internal REAPI access
  yet should use `compat` with a base capability class rather than the retired
  `hosted` mode.
- `bazel_fetch_retry_attempts` defaults to `3` and wraps consumer-provided
  validation commands plus explicit Bazel target validation. It only retries
  when the command log matches transient Bazel external archive fetch failures,
  such as upstream GitHub release `502` responses. Deterministic compile/test
  failures are not retried.
- every mode now rejects a GitHub-hosted label in `runner_labels_json` /
  `shared_runner_labels_json`, including `compat`, where labels were previously
  unvalidated. There is no hosted lane left to degrade to, so a hosted label is
  a routing error, not a fallback.
- self-hosted jobs now call `nix-setup`, so Attic and Bazel cache hints are
  explicit instead of incidental runner state.
- `workspace_mode=isolated` is the preferred contract for downstream pilots.
- `cleanup_paths` is still available, but only applies to
  `workspace_mode=persistent_compat`.

## Migrating off publication (RU8)

1. Bump the pin to the ci-templates release that carries this change.
2. Delete `dry_run`, `publish_on_tag`, `publish_mode`, every `npm_*` and
   `github_package_*` input, and stop passing `NPM_TOKEN` /
   `TINYLAND_GITHUB_PACKAGES_TOKEN`. Leaving them is harmless except as noted
   above, but they are scheduled for removal at the next major.
3. Release by signed tag and a registry module in `xoxd-ai/bazel-registry`.
   Consumers take the module as a `bazel_dep` and link it with
   `npm_link_package(name = "node_modules/@tummycrypt/<pkg>", src =
   "@<module>//:pkg")`; `xoxd-ai/site.scaffold` is the reference wiring.
4. Already-published npmjs and GitHub Packages versions are deprecated with a
   pointer to the Bazel module and are never unpublished (RU8). That is an
   operator action, not something this workflow does.
