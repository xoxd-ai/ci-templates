#!/usr/bin/env ruby
# frozen_string_literal: true

# RU5 contract (operator ruling 2026-10-08) for the estate dependency-update
# templates under templates/:
#
# - templates/dependabot/estate-weekly.yml yields ONE pull request per repository
#   per week: exactly one multi-ecosystem group on a weekly schedule, every
#   `updates` entry joins it with patterns ["*"], and no entry carries its own
#   schedule or `groups` (either would split the PR).
# - templates/renovate/estate-weekly.json does the same for Renovate: one
#   weekly schedule, every package in one group, majors not split out, lock
#   file maintenance off.
# - Both ignore every version of the estate's exact, manifest-driven framework
#   pins (EXACT_PINS) and agree with each other on that list.
#
#   ruby scripts/dependency-update-template-contract.rb --root .
#   ruby scripts/dependency-update-template-contract.rb --self-test

require "json"
require "optparse"
require "yaml"

# The packages of the estate version manifest, xoxd-ai/site.scaffold
# estate/versions.json (RU5 SSOT, site.scaffold #224). Change this list and both
# templates in the same PR whenever the manifest adds or drops a package.
EXACT_PINS = %w[
  @sveltejs/kit
  svelte
  vite
  @sveltejs/vite-plugin-svelte
  @sveltejs/adapter-auto
  @sveltejs/adapter-cloudflare
  @sveltejs/adapter-node
  @sveltejs/adapter-static
  typescript
  @typescript/native
  vitest
  @vitest/browser-playwright
  @vitest/coverage-v8
  @playwright/test
  playwright
  effect
  @skeletonlabs/skeleton
  @skeletonlabs/skeleton-svelte
].freeze

DEPENDABOT = "templates/dependabot/estate-weekly.yml"
RENOVATE = "templates/renovate/estate-weekly.json"

def dependabot_errors(doc)
  errors = []
  return ["#{DEPENDABOT}: not a mapping"] unless doc.is_a?(Hash)

  errors << "#{DEPENDABOT}: version must be 2" unless doc["version"] == 2
  groups = doc["multi-ecosystem-groups"]
  unless groups.is_a?(Hash) && groups.size == 1
    return errors << "#{DEPENDABOT}: exactly one multi-ecosystem group is required (one PR per repo per week)"
  end

  name, group = groups.first
  interval = group.is_a?(Hash) && group.dig("schedule", "interval")
  errors << "#{DEPENDABOT}: group #{name} must run weekly (got #{interval.inspect})" unless interval == "weekly"

  updates = doc["updates"]
  return errors << "#{DEPENDABOT}: updates must be a non-empty list" unless updates.is_a?(Array) && !updates.empty?

  updates.each_with_index do |entry, index|
    label = "#{DEPENDABOT}: updates[#{index}] (#{entry['package-ecosystem']})"
    errors << "#{label} must join multi-ecosystem-group #{name}" unless entry["multi-ecosystem-group"] == name
    errors << "#{label} must declare patterns [\"*\"]" unless entry["patterns"] == ["*"]
    errors << "#{label} must not carry its own schedule" if entry.key?("schedule")
    errors << "#{label} must not declare groups (they split the weekly PR)" if entry.key?("groups")
  end

  npm = updates.find { |entry| entry["package-ecosystem"] == "npm" }
  if npm.nil?
    errors << "#{DEPENDABOT}: an npm entry is required"
  else
    ignored = Array(npm["ignore"]).filter_map do |rule|
      # A rule narrowed by versions or update-types still lets some bumps through.
      rule["dependency-name"] if rule.is_a?(Hash) && rule.keys == ["dependency-name"]
    end
    missing = EXACT_PINS - ignored
    extra = ignored - EXACT_PINS
    errors << "#{DEPENDABOT}: npm must ignore every version of #{missing.join(', ')}" unless missing.empty?
    errors << "#{DEPENDABOT}: npm ignores #{extra.join(', ')}, which is not an exact estate pin" unless extra.empty?
  end
  errors
end

def renovate_errors(doc)
  errors = []
  return ["#{RENOVATE}: not an object"] unless doc.is_a?(Hash)

  schedule = Array(doc["schedule"])
  unless schedule.size == 1 && schedule.first.to_s.match?(/\A\S+ \S+ \* \* [0-6]\z/)
    errors << "#{RENOVATE}: schedule must be a single weekly cron window (got #{schedule.inspect})"
  end
  %w[separateMajorMinor separateMultipleMajor separateMinorPatch].each do |key|
    errors << "#{RENOVATE}: #{key} must be false so majors stay in the weekly PR" unless doc[key] == false
  end
  errors << "#{RENOVATE}: lockFileMaintenance must be disabled (it opens its own PR)" unless doc.dig("lockFileMaintenance", "enabled") == false

  rules = Array(doc["packageRules"])
  catch_all = rules.find { |rule| rule["matchPackageNames"] == ["*"] && rule.keys.none? { |key| key.start_with?("match") && key != "matchPackageNames" } }
  if catch_all.nil? || catch_all["groupName"].to_s.empty?
    errors << "#{RENOVATE}: a packageRule must put every package (matchPackageNames [\"*\"]) in one groupName"
  end
  disabled = rules.select { |rule| rule["enabled"] == false && rule.keys.none? { |key| key.start_with?("match") && key != "matchPackageNames" } }
                  .flat_map { |rule| Array(rule["matchPackageNames"]) }
  missing = EXACT_PINS - disabled
  extra = disabled - EXACT_PINS
  errors << "#{RENOVATE}: every version of #{missing.join(', ')} must be disabled" unless missing.empty?
  errors << "#{RENOVATE}: disables #{extra.join(', ')}, which is not an exact estate pin" unless extra.empty?
  errors
end

def load_yaml(text)
  YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
end

def check(root)
  dependabot = load_yaml(File.read(File.join(root, DEPENDABOT)))
  renovate = JSON.parse(File.read(File.join(root, RENOVATE)))
  dependabot_errors(dependabot) + renovate_errors(renovate)
end

def self_test(root)
  base_dependabot = load_yaml(File.read(File.join(root, DEPENDABOT)))
  base_renovate = JSON.parse(File.read(File.join(root, RENOVATE)))
  deep = ->(value) { Marshal.load(Marshal.dump(value)) }
  failures = []

  failures << "shipped templates fail the contract" unless (dependabot_errors(base_dependabot) + renovate_errors(base_renovate)).empty?

  dependabot_mutations = {
    "second group" => ->(doc) { doc["multi-ecosystem-groups"]["other"] = { "schedule" => { "interval" => "weekly" } } },
    "daily schedule" => ->(doc) { doc["multi-ecosystem-groups"].values.first["schedule"]["interval"] = "daily" },
    "entry outside the group" => ->(doc) { doc["updates"].first.delete("multi-ecosystem-group") },
    "per-entry schedule" => ->(doc) { doc["updates"].first["schedule"] = { "interval" => "weekly" } },
    "per-entry groups" => ->(doc) { doc["updates"].first["groups"] = { "x" => { "patterns" => ["*"] } } },
    "framework pin dropped" => ->(doc) { doc["updates"].first["ignore"].reject! { |rule| rule["dependency-name"] == "svelte" } },
    "framework pin narrowed to majors" => lambda { |doc|
      rule = doc["updates"].first["ignore"].find { |item| item["dependency-name"] == "vite" }
      rule["update-types"] = ["version-update:semver-major"]
    },
  }
  dependabot_mutations.each do |label, mutate|
    doc = deep.call(base_dependabot)
    mutate.call(doc)
    failures << "dependabot mutation not caught: #{label}" if dependabot_errors(doc).empty?
  end

  renovate_mutations = {
    "majors split out" => ->(doc) { doc["separateMajorMinor"] = true },
    "daily schedule" => ->(doc) { doc["schedule"] = ["* 6-11 * * *"] },
    "lock file maintenance on" => ->(doc) { doc["lockFileMaintenance"] = { "enabled" => true } },
    "no catch-all group" => ->(doc) { doc["packageRules"].reject! { |rule| rule["matchPackageNames"] == ["*"] } },
    "framework pin dropped" => lambda { |doc|
      doc["packageRules"].each { |rule| rule["matchPackageNames"] -= ["effect"] if rule["enabled"] == false }
    },
  }
  renovate_mutations.each do |label, mutate|
    doc = deep.call(base_renovate)
    mutate.call(doc)
    failures << "renovate mutation not caught: #{label}" if renovate_errors(doc).empty?
  end

  if failures.empty?
    puts "dependency-update template self-test: #{dependabot_mutations.size + renovate_mutations.size} mutations caught"
    0
  else
    warn failures.join("\n")
    1
  end
end

root = Dir.pwd
mode = :check
OptionParser.new do |opts|
  opts.on("--root DIR") { |dir| root = File.expand_path(dir) }
  opts.on("--self-test") { mode = :self_test }
end.parse!

exit(self_test(root)) if mode == :self_test

errors = check(root)
if errors.empty?
  puts "dependency-update templates: one weekly PR per repo, #{EXACT_PINS.size} exact framework pins excluded (RU5)"
  exit 0
end
warn errors.join("\n")
exit 1
