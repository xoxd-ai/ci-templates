#!/usr/bin/env ruby
# frozen_string_literal: true

# RU8 backstop (operator ruling 2026-10-08): Bazel is the only distribution
# path for in-house packages, so no shared workflow or composite action may
# publish a node package to npmjs or GitHub Packages, and no publish dry-run
# survives either. Comment lines are ignored; everything else that can run in a
# job is scanned textually.
#
#   ruby scripts/no-package-publish.rb --root .
#   ruby scripts/no-package-publish.rb --self-test

require "optparse"

FORBIDDEN = [
  [/\b(?:npm|pnpm|yarn|bun)\s+(?:-r\s+|--recursive\s+|run\s+)?publish\b/i, "package-manager publish"],
  [/\bchangeset\s+publish\b/i, "changesets publish"],
  [%r{\bchangesets/action\b}i, "changesets/action (publishes when given a publish command)"],
  [/\blerna\s+publish\b/i, "lerna publish"],
  [/\bsemantic-release\b/i, "semantic-release"],
  [%r{\bJS-DevTools/npm-publish\b}i, "JS-DevTools/npm-publish"],
  [%r{\bnpm-publish\.yml\b}i, "reference to the retired npm-publish.yml"],
].freeze

RETIRED_FILES = [
  ".github/workflows/npm-publish.yml",
].freeze

def violations_for(text, path)
  found = []
  text.each_line.with_index(1) do |line, number|
    next if line.lstrip.start_with?("#")

    FORBIDDEN.each do |pattern, label|
      found << "#{path}:#{number}: #{label}: #{line.strip}" if line.match?(pattern)
    end
  end
  found
end

def scan(root)
  found = []
  RETIRED_FILES.each do |rel|
    found << "#{rel}: retired by RU8 and must not exist" if File.exist?(File.join(root, rel))
  end
  Dir.glob(File.join(root, ".github", "{workflows,actions}", "**", "*.{yml,yaml}")).sort.each do |path|
    rel = path.delete_prefix("#{root}/")
    found.concat(violations_for(File.read(path), rel))
  end
  found
end

def self_test
  cases = {
    "run: npm publish ./pkg" => true,
    "run: pnpm publish --no-git-checks" => true,
    "run: pnpm -r publish" => true,
    "run: npm publish --dry-run ./pkg" => true,
    "run: yarn publish" => true,
    "run: pnpm changeset publish" => true,
    "uses: changesets/action@v1" => true,
    "uses: xoxd-ai/ci-templates/.github/workflows/npm-publish.yml@v5" => true,
    "run: npx semantic-release" => true,
    "# npm publish was removed (RU8)" => false,
    "run: npm pack --dry-run ./bazel-bin/pkg" => false,
    "description: \"Deprecated, inert (RU8): npm publication was removed\"" => false,
    "echo \"npm/GitHub Packages publication was removed\"" => false,
  }
  failures = cases.filter_map do |line, expected|
    got = !violations_for("#{line}\n", "case").empty?
    "#{expected ? 'missed' : 'false positive'}: #{line}" unless got == expected
  end
  if failures.empty?
    puts "no-package-publish self-test: #{cases.size} cases ok"
    0
  else
    warn failures.join("\n")
    1
  end
end

root = Dir.pwd
mode = :scan
OptionParser.new do |opts|
  opts.on("--root DIR") { |dir| root = File.expand_path(dir) }
  opts.on("--self-test") { mode = :self_test }
end.parse!

exit(self_test) if mode == :self_test

found = scan(root)
if found.empty?
  puts "no package publication on any workflow or action surface (RU8)"
  exit 0
end
warn "RU8: package publication is forbidden in shared templates:"
warn found.map { |line| "  #{line}" }.join("\n")
exit 1
