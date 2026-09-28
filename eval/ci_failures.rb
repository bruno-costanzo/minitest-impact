#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds evaluation cases from a repository's failed GitHub Actions runs on its default branch:
# for each failed run, the change is everything since the last green run before it, and the
# expected tests are the test files the failed jobs reported. Logs are cached, so a second run is
# offline.
#
#   ruby eval/ci_failures.rb --repo ~/app --workflow ci.yml --out cases.json [--cache DIR] [--limit 200]
#
# Needs the gh CLI, authenticated for the repository. Costs nothing but GitHub API calls.

require "json"
require "open3"
require "optparse"
require "fileutils"

options = { workflow: "ci.yml", limit: 300, cache: "tmp/minitest-impact/ci-logs", branch: "main" }
OptionParser.new do |parser|
  parser.on("--repo DIR") { |v| options[:repo] = File.expand_path(v) }
  parser.on("--workflow FILE") { |v| options[:workflow] = v }
  parser.on("--branch NAME") { |v| options[:branch] = v }
  parser.on("--out FILE") { |v| options[:out] = v }
  parser.on("--cache DIR") { |v| options[:cache] = v }
  parser.on("--limit N", Integer) { |v| options[:limit] = v }
end.parse!
abort "usage: ci_failures.rb --repo DIR --out FILE" unless options[:repo] && options[:out]

def sh(*cmd, dir:)
  out, err, status = Open3.capture3(*cmd, chdir: dir)
  raise "#{cmd.join(" ")}: #{err}" unless status.success?

  out
end

FileUtils.mkdir_p(options[:cache])
runs = JSON.parse(sh("gh", "run", "list", "--workflow", options[:workflow], "--branch", options[:branch], "--event", "push",
                     "--limit", options[:limit].to_s, "--json", "databaseId,headSha,conclusion,createdAt", dir: options[:repo]))
runs.sort_by! { |run| run["createdAt"] }

# Rails prints a rerun line per failure ("bin/rails test test/models/user_test.rb:12"), and
# Minitest a location in brackets ("[test/models/user_test.rb:12]").
FAILING = %r{(?:bin/rails test |\[)(test/[\w/.-]+_test\.rb):\d+}

last_green = nil
still_failing = []
cases = []
runs.each do |run|
  if run["conclusion"] == "success"
    last_green = run["headSha"]
    still_failing = []
    next
  end
  next unless run["conclusion"] == "failure" && last_green

  cache = File.join(options[:cache], "#{run["databaseId"]}.log")
  unless File.exist?(cache)
    log, _err, status = Open3.capture3("gh", "run", "view", run["databaseId"].to_s, "--log-failed", chdir: options[:repo])
    File.write(cache, status.success? ? log : "")
  end
  reported = File.read(cache).scan(FAILING).flatten.uniq.sort
  # A test that already failed in the run before was broken by an earlier push, not this one.
  failing = reported - still_failing
  still_failing |= reported
  next if failing.empty?

  cases << { "id" => "run-#{run["databaseId"]}", "base" => last_green, "head" => run["headSha"], "expected" => failing,
             "source" => "ci_failure" }
end

File.write(options[:out], JSON.pretty_generate(cases))
puts "#{cases.size} cases from #{runs.count { |r| r["conclusion"] == "failure" }} failed runs into #{options[:out]}"
