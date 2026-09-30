# frozen_string_literal: true

# Compares minitest-impact's selection with two strategies a coding agent could follow with no
# map at all, on the same labelled cases, so the gem has to earn its place:
#
# - conventional: the changed test files, plus the test named after each changed file
#   (app/models/invoice.rb => test/models/invoice_test.rb).
# - mentions: tests whose source names the constant a changed file defines.
#
# Both apply the gem's own whole-suite rule (Gemfile.lock, test_helper.rb...), which needs no map.
#
#   ruby -Ilib eval/baselines.rb --repo ../app --map map.json --results eval-co.json [--cases ci-cases.json]
#
# --results is the JSON `minitest-impact eval --format json` wrote for the same cases; its per-case
# ids say which commits to replay. --cases gives base/head for cases that are not single commits.

require "json"
require "optparse"
require "minitest/impact"

module Minitest
  module Impact
    module Baselines
      module_function

      def selections(repo, map, base:, head:, hide_tests:)
        files = Diff.parse(repo.git("diff", "--no-color", "-M", "--unified=0", base, head, allow_failure: true).to_s)
        files = files.reject { |file| file.path.start_with?(Rules::TEST_ROOT) } if hide_tests
        known = map.test_files
        return { whole: true } if files.any? { |file| Rules.whole_suite?(file.path) }

        changed_tests = files.map(&:path).select { |path| Rules.test_file?(path) }
        conventional = changed_tests + files.flat_map { |file| Rules.conventional_tests(file.path) }
        mentions = files.filter_map { |file| Rules.constant_for(file.path) }.uniq
                        .flat_map { |constant| repo.grep(constant, paths: ["test"], rev: head) }
                        .select { |path| Rules.test_file?(path) }
        { whole: false, conventional: (conventional & known).uniq, mentions: ((changed_tests + mentions) & known).uniq }
      end

      def score(expected, selected, map)
        hit = expected & selected
        total = map.tests.values.sum(&:seconds)
        { caught: hit.any?, all_caught: (expected - hit).empty?, recall: hit.size.to_f / expected.size,
          precision: selected.empty? ? 0.0 : hit.size.to_f / selected.size,
          selected_share: selected.size.to_f / map.test_files.size,
          seconds_share: total.zero? ? 0.0 : selected.sum { |test| map.seconds(test).to_f } / total }
      end

      def summarize(rows)
        n = rows.size.to_f
        %i[caught all_caught].to_h { |key| [key, (rows.count { |row| row[key] } / n).round(3)] }
          .merge(%i[recall precision selected_share seconds_share].to_h { |key| [key, (rows.sum { |row| row[key] } / n).round(3)] })
      end
    end
  end
end

options = {}
OptionParser.new do |opts|
  opts.on("--repo PATH") { options[:repo] = it }
  opts.on("--map PATH") { options[:map] = it }
  opts.on("--results PATH") { options[:results] = it }
  opts.on("--cases PATH") { options[:cases] = it }
end.parse!

repo = Minitest::Impact::Repo.new(options.fetch(:repo))
map = Minitest::Impact::Map.load(options.fetch(:map))
results = JSON.parse(File.read(options.fetch(:results))).fetch("cases")
cases = options[:cases] ? JSON.parse(File.read(options[:cases])).to_h { [it["id"], it] } : {}

rows = Hash.new { |hash, key| hash[key] = [] }
results.each do |result|
  kase = cases[result["id"]]
  head = kase ? kase["head"] : result["id"]
  base = kase ? kase["base"] : "#{head}^"
  expected = result["expected"]
  picks = Minitest::Impact::Baselines.selections(repo, map, base: base, head: head, hide_tests: kase.nil?)
  all = map.test_files
  conventional = picks[:whole] ? all : picks[:conventional]
  mentions = picks[:whole] ? all : picks[:mentions]
  rows[:gem] << Minitest::Impact::Baselines.score(expected, result["selected"], map)
  rows[:conventional] << Minitest::Impact::Baselines.score(expected, conventional, map)
  rows[:mentions] << Minitest::Impact::Baselines.score(expected, mentions, map)
  rows[:conventional_or_mentions] << Minitest::Impact::Baselines.score(expected, (conventional | mentions), map)
end

puts JSON.pretty_generate(rows.transform_values { Minitest::Impact::Baselines.summarize(it) }.merge(cases: results.size))
