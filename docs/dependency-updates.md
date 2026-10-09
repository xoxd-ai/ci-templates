# Estate dependency updates (RU5)

Operator ruling RU5 (2026-10-08) pins Svelte, SvelteKit, Vite, TypeScript,
vitest and Playwright exactly, as RS11 already does for Skeleton and Effect.
Everything else uses ranges and moves in **one grouped pull request per
repository per week**. The estate version manifest in `xoxd-ai/site.scaffold`
is the source of truth for the exact pins, and a CI drift check there fails on
a mismatch. Bots never bump those pins. They move when the manifest moves.

ci-templates ships two equivalent templates. Use the one for the bot the
repository already runs.

| Bot | Template | How a repository adopts it |
|---|---|---|
| Dependabot | [`templates/dependabot/estate-weekly.yml`](../templates/dependabot/estate-weekly.yml) | Copy it to `.github/dependabot.yml`, then add or remove `updates` entries for the ecosystems the repository has |
| Renovate | [`templates/renovate/estate-weekly.json`](../templates/renovate/estate-weekly.json) | `renovate.json`: `{ "extends": ["github>xoxd-ai/ci-templates//templates/renovate/estate-weekly"] }` |

Dependabot has no remote config include, so its template is copied. Pin the
Renovate preset to a release tag (`...//templates/renovate/estate-weekly#v6.x.y`)
once one carries it.

## What the templates guarantee

`just dependency-update-template-check` enforces these properties, and its
self-test proves that each mutation which would break them is rejected.

- **One PR per week.** Dependabot uses a single `multi-ecosystem-groups` entry
  on a weekly schedule. Every `updates` entry joins it with `patterns: ["*"]`
  and carries no schedule or `groups` of its own, so npm and GitHub Actions
  updates land in the same PR. Renovate uses one weekly cron window and one
  `groupName` for every package. Majors are not split out, and lock file
  maintenance is off because it would open a second PR.
- **Exact pins are excluded.** Every version of each package in the estate
  manifest (`xoxd-ai/site.scaffold` `estate/versions.json`, #224) is ignored:
  `@sveltejs/kit`, `svelte`, `vite`, `@sveltejs/vite-plugin-svelte`, the four
  `@sveltejs/adapter-*` packages (auto, cloudflare, node, static), `typescript`,
  `vitest`, `@vitest/browser-playwright`, `@vitest/coverage-v8`,
  `@playwright/test`, `playwright`, `effect`, `@skeletonlabs/skeleton` and
  `@skeletonlabs/skeleton-svelte`. RU13 (operator ruling 2026-10-08) makes
  TypeScript 7.0.2 itself the `typescript` package, and the manifest lists
  `@typescript/native` (the superseded U1-probe TS 6 fallback alias) as
  forbidden, so it is not on this list: the manifest drift check, not the
  update bot, removes it from a repo. `svelte-check` and the lint and format
  stack keep ranges and still update weekly.
- **ci-templates majors are not bumped.** Moving to a new ci-templates major is
  an estate re-pin decision, so only minor and patch updates are proposed.

The list lives in `scripts/dependency-update-template-contract.rb`
(`EXACT_PINS`) and in both templates. When the manifest adds or drops a
package, change all three in one PR. A version change inside the manifest needs
no change here.

## Superseded runs are cancelled

The bots handle superseded PRs themselves. Each one keeps a single branch for
the group and rebases it in place when newer versions appear, so a stale
grouped PR is updated rather than duplicated. The CI run on the old head is
cancelled by the **caller's** concurrency group. Every workflow that runs on
`pull_request` should carry:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Pushes to the default branch and tags are never cancelled. For `spoke-ci-v4.yml`
callers, the opt-in cancellation input proposed in ci-templates #185 (R111,
TIN-5447) does the same at the dispatch edge once it is released.

## What still opens its own PR

Security updates (Dependabot security updates, Renovate vulnerability alerts)
bypass the weekly schedule by design. Turn them off in repository settings only
with an operator ruling.

## Adding an ecosystem

Add an `updates` entry with `multi-ecosystem-group: "estate-weekly"` and
`patterns: ["*"]` and no `schedule`. Bazel modules from `xoxd-ai/bazel-registry`
are left out on purpose: in-house modules move through the dependency-ordered
package waves (RU2, RU10), not a weekly bot.
