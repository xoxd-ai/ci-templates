#!/usr/bin/env ruby
# frozen_string_literal: true

# required-gate-contract.rb — prove spoke-ci.yml's `all-required` aggregate
# gate (TIN-2611) cannot report success unless every other job succeeded.
#
# GitHub reports a job skipped by an unmet `needs:` (or by an `if:`) as a
# neutral check, and a neutral check satisfies a required status check of the
# same name. A failed secrets-scan therefore skipped bazel-graph and the matrix
# jobs, and a ruleset requiring those names could read the skips as passes.
# The gate closes that: it runs under `always()` and fails unless every job it
# needs reports `success`. The one accepted skip is playwright when the caller
# left `playwright_enabled` false.
#
# Proven offline, mechanically:
#   (a) shape: the gate exists, its condition is exactly `${{ always() }}`, its
#       `needs:` is exactly every other job in the workflow (so a job added
#       later without joining the gate fails here), nothing depends on it, and
#       it routes through the same base capability class as secrets-scan.
#   (b) wiring: every needed job has a RESULT_<JOB> env var bound to
#       `needs.<job>.result`, and the verdict loop reads every one of them.
#   (c) verdict: the step's own bash is executed over a result grid. All
#       success passes; any single failure, skip, cancellation or empty result
#       fails; a playwright skip passes only with playwright_enabled=false.
#
# `--self-test` proves the checker rejects its negative oracles.

require "open3"
require "yaml"

ROOT = File.expand_path("..", __dir__)
WORKFLOW = File.join(ROOT, ".github/workflows/spoke-ci.yml")
GATE = "all-required"
ROUTE_TWIN = "secrets-scan"
CONDITION = "${{ always() }}"
OPTIONAL_JOB = "playwright"
OPTIONAL_INPUT_ENV = "PLAYWRIGHT_ENABLED"
OPTIONAL_INPUT_EXPR = "${{ inputs.playwright_enabled }}"
BAD_RESULTS = ["failure", "skipped", "cancelled", ""].freeze

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def env_name(job)
  "RESULT_#{job.upcase.tr("-", "_")}"
end

def as_list(value)
  value.is_a?(Array) ? value : [value].compact
end

def gate_step(gate)
  Array(gate["steps"]).find { |step| step.is_a?(Hash) && step["run"].is_a?(String) }
end

def run_verdict(script, env)
  _out, _err, status = Open3.capture3(env, "bash", "-c", script)
  status.success?
end

def check(document)
  errors = []
  jobs = document["jobs"]
  return ["workflow has no jobs mapping"] unless jobs.is_a?(Hash)

  gate = jobs[GATE]
  return ["#{GATE} job is missing"] unless gate.is_a?(Hash)

  errors << "#{GATE} condition must be exactly #{CONDITION}" unless gate["if"].to_s.strip == CONDITION

  upstream = (jobs.keys - [GATE]).sort
  needs = as_list(gate["needs"]).map(&:to_s)
  errors << "#{GATE} needs (#{needs.sort.join(", ")}) must equal every other job (#{upstream.join(", ")})" unless needs.sort == upstream
  errors << "#{GATE} needs lists a job twice" unless needs.uniq.length == needs.length

  jobs.each do |name, body|
    next if name == GATE || !body.is_a?(Hash)

    errors << "#{name} must not depend on #{GATE}" if as_list(body["needs"]).include?(GATE)
  end

  twin = jobs[ROUTE_TWIN]
  unless twin.is_a?(Hash) && gate["runs-on"] == twin["runs-on"]
    errors << "#{GATE} runs-on must equal #{ROUTE_TWIN}'s base-class route"
  end

  step = gate_step(gate)
  return errors << "#{GATE} has no run step" if step.nil?

  env = step["env"].is_a?(Hash) ? step["env"] : {}
  script = step["run"]
  upstream.each do |job|
    var = env_name(job)
    expected = "${{ needs.#{job}.result }}"
    errors << "#{GATE} env #{var} must be #{expected}" unless env[var] == expected
    errors << "#{GATE} verdict loop does not read #{var}" unless script.match?(/(^|\s)#{Regexp.escape(var)}(\s|;|$)/)
  end
  extra = env.keys.grep(/\ARESULT_/) - upstream.map { |job| env_name(job) }
  errors << "#{GATE} env binds results for unknown jobs: #{extra.sort.join(", ")}" unless extra.empty?
  errors << "#{GATE} env #{OPTIONAL_INPUT_ENV} must be #{OPTIONAL_INPUT_EXPR}" unless env[OPTIONAL_INPUT_ENV] == OPTIONAL_INPUT_EXPR
  return errors unless errors.empty?

  all_success = upstream.each_with_object({}) { |job, out| out[env_name(job)] = "success" }
  [true, false].each do |enabled|
    flag = { OPTIONAL_INPUT_ENV => enabled.to_s }
    unless run_verdict(script, all_success.merge(flag))
      errors << "verdict failed with every job successful (playwright_enabled=#{enabled})"
    end
    upstream.each do |job|
      BAD_RESULTS.each do |result|
        accepted = run_verdict(script, all_success.merge(flag).merge(env_name(job) => result))
        allowed = job == OPTIONAL_JOB && result == "skipped" && !enabled
        if accepted && !allowed
          errors << "verdict passed with #{job}=#{result.inspect} (playwright_enabled=#{enabled})"
        elsif !accepted && allowed
          errors << "verdict failed with #{job} skipped and playwright_enabled=false"
        end
      end
    end
  end
  errors
end

def mutate_script(document)
  mutant = deep_copy(document)
  yield gate_step(mutant["jobs"][GATE])
  mutant
end

def self_test(document)
  mutants = {
    "gate condition !cancelled()" => deep_copy(document).tap { |d| d["jobs"][GATE]["if"] = "${{ !cancelled() }}" },
    "gate condition removed" => deep_copy(document).tap { |d| d["jobs"][GATE].delete("if") },
    "upstream job dropped from needs" => deep_copy(document).tap { |d| d["jobs"][GATE]["needs"] -= ["bazel-graph"] },
    "new job not joined to the gate" => deep_copy(document).tap { |d| d["jobs"]["new-job"] = deep_copy(d["jobs"]["bazel-graph"]) },
    "gate rerouted to a heavy class" => deep_copy(document).tap { |d| d["jobs"][GATE]["runs-on"] = d["jobs"]["bazel-graph"]["runs-on"] },
    "result env bound to the wrong job" => mutate_script(document) { |s| s["env"][env_name("bazel-graph")] = "${{ needs.secrets-scan.result }}" },
    "result var missing from loop" => mutate_script(document) { |s| s["run"] = s["run"].sub(/\s#{env_name("bazel-graph")}\s/, " ") },
    "skips accepted as success" => mutate_script(document) { |s| s["run"] = s["run"].sub('"$result" == "success"', '"$result" != "failure"') },
    "playwright exemption ignores the input" => mutate_script(document) { |s| s["run"] = s["run"].sub('"$PLAYWRIGHT_ENABLED" != "true" && ', "") },
    "verdict never fails" => mutate_script(document) { |s| s["run"] = s["run"].sub('exit "$failed"', "exit 0") },
  }
  survivors = mutants.select { |_label, mutant| check(mutant).empty? }.keys
  [survivors, mutants.length]
end

document = YAML.safe_load(File.read(WORKFLOW), aliases: false)
errors = check(document)
unless errors.empty?
  warn "required-gate contract FAILED:"
  errors.each { |error| warn "- #{error}" }
  exit 1
end

if ARGV.include?("--self-test")
  survivors, total = self_test(document)
  unless survivors.empty?
    warn "required-gate contract self-test FAILED; checker accepted:"
    survivors.each { |label| warn "- #{label}" }
    exit 1
  end
  puts "required-gate contract self-test passed (#{total} negative oracles rejected)"
else
  upstream = document["jobs"].keys.length - 1
  puts "required-gate contract passed (#{GATE} needs all #{upstream} jobs under always(); " \
       "verdict executed over #{upstream * BAD_RESULTS.length * 2 + 2} result scenarios)"
end
