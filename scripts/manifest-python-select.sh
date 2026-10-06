#!/usr/bin/env bash
# Select the python3 interpreter the repo-manifest-validate gate should run,
# from a fixed priority list, rather than trusting bare `python3` off PATH.
#
# WHY THIS EXISTS (TIN-4132 follow-up, 2026-09-06): the composite used to
# probe and invoke bare `python3`. Every consumer of this action runs
# `setup-nix` first, which puts a Nix profile interpreter ahead of everything
# else on PATH -- and that interpreter does not carry `jsonschema`. GF's
# runner image asserts `jsonschema` under /usr/bin/python3 ONLY (build
# receipt, GF run 33616870780 stage 11/11); a live consumer run confirms the
# gap live (site.scaffold run 33795601349, job 'ci / repo-manifest', runner
# tinyland-nix-compute-expansion-cbmmh-runner-2jk9c, 2026-09-03T19:19:44Z).
# The gate was therefore probing and running the ONE interpreter on the box
# guaranteed not to have the engine, and refusing (TIN-4132 exit 5) even
# though a perfectly good interpreter sat two directories away.
#
# Candidates, in priority order:
#   1. $REPO_MANIFEST_PYTHON, if set -- an explicit caller override, for a
#      consumer whose interpreter lives somewhere neither of the below finds.
#   2. /usr/bin/python3 -- the interpreter the runner image asserts carries
#      jsonschema.
#   3. `python3` resolved from PATH -- kept last on purpose: this is exactly
#      the entry setup-nix's Nix profile interpreter shadows.
#
# Runner-image candidates are probed with `<candidate> -I -c 'import
# jsonschema'` (`-I` isolates the probe from a caller's PYTHONPATH/site
# customization, so the probe answers "can THIS interpreter import it unaided",
# not "can it be made to"). The explicit $REPO_MANIFEST_PYTHON override is
# different: repo-manifest-jsonschema has already executed and proved that
# wrapper, and its lockfile-pinned Nix devShell exposes packages through the
# interpreter environment that `-I` deliberately discards. Probe it exactly as
# the validator will invoke it.
#
# Output contract:
#   - Every candidate's verdict is logged to stderr as an `::notice::` line,
#     in the order tried.
#   - On success: the chosen interpreter's resolved path is printed to
#     STDOUT ONLY (nothing else touches stdout), and the script exits 0. A
#     caller captures it with `chosen="$(manifest-python-select.sh)"`.
#   - On failure: nothing is printed to stdout, an `::error::` names EVERY
#     candidate tried and its verdict, and the script exits 5 -- the same
#     refusal code scripts/manifest-schema-validate.py uses for "no engine"
#     (TIN-4132). This is still a refusal, never a weaker verdict.
set -euo pipefail

# Test seam ONLY: lets the selftest substitute a stub for /usr/bin/python3
# without touching the real system interpreter. Consumers use
# $REPO_MANIFEST_PYTHON for that; this variable is not part of the public
# contract and is intentionally undocumented outside this file and the
# selftest that sets it.
sys_candidate="${_MANIFEST_PYTHON_SYS_CANDIDATE:-/usr/bin/python3}"

declare -a candidate_paths=()
declare -a candidate_labels=()
declare -a candidate_explicit=()

if [[ -n "${REPO_MANIFEST_PYTHON:-}" ]]; then
  candidate_paths+=("${REPO_MANIFEST_PYTHON}")
  candidate_labels+=("\$REPO_MANIFEST_PYTHON (${REPO_MANIFEST_PYTHON})")
  candidate_explicit+=(true)
fi
candidate_paths+=("${sys_candidate}")
candidate_labels+=("${sys_candidate}")
candidate_explicit+=(false)
candidate_paths+=("python3")
candidate_labels+=("python3 (PATH)")
candidate_explicit+=(false)

declare -a verdicts=()
chosen=""

for i in "${!candidate_paths[@]}"; do
  cand="${candidate_paths[$i]}"
  label="${candidate_labels[$i]}"

  resolved="$(command -v -- "${cand}" 2>/dev/null || true)"
  if [[ -z "${resolved}" ]]; then
    echo "::notice::manifest-python-select: candidate ${label}: not found" >&2
    verdicts+=("${label}: not found")
    continue
  fi

  if [[ "${candidate_explicit[$i]}" == true ]]; then
    probe=("${resolved}" -c 'import jsonschema')
  else
    probe=("${resolved}" -I -c 'import jsonschema')
  fi
  if "${probe[@]}" >/dev/null 2>&1; then
    echo "::notice::manifest-python-select: candidate ${label} (${resolved}): has jsonschema -- SELECTED" >&2
    chosen="${resolved}"
    break
  fi

  echo "::notice::manifest-python-select: candidate ${label} (${resolved}): jsonschema not importable" >&2
  verdicts+=("${label} (${resolved}): jsonschema not importable")
done

if [[ -z "${chosen}" ]]; then
  echo "::error::no candidate python interpreter could import 'jsonschema', so this gate has no validator. It REFUSES to substitute a weaker one (TIN-4132). Candidates tried, in order: ${verdicts[*]}. Remedy: add a step BEFORE this one that provides a complete interpreter through \$REPO_MANIFEST_PYTHON; spoke-ci.yml uses repo-manifest-jsonschema for that purpose. The ci-templates nix-setup and setup-nix composites do NOT provide it: nix-setup configures Attic/Bazel cache endpoints, setup-nix installs Nix itself, and neither installs a python package." >&2
  exit 5
fi

printf '%s\n' "${chosen}"
