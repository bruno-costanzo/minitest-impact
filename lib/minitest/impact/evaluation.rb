# frozen_string_literal: true

require "json"

module Minitest
  module Impact
    # Replays a selection on past changes whose right answer is known and measures it.
    #
    # A case is {"id", "base", "head", "expected" => [test files]}: the tests a change broke (from
    # CI failures) or the tests written for it (from commits that changed code and its tests
    # together, with the test edits hidden from the selector).
    class Evaluation
      Result = Struct.new(:id, :expected, :selected, :hit, :suite_size, :seconds_share, :whole_suite, :confidence, keyword_init: true) do
        def caught? = hit.any?
        def all_caught? = (expected - hit).empty?
        def recall = hit.size.to_f / expected.size
        def precision = selected.empty? ? 0.0 : hit.size.to_f / selected.size
      end

      # Cases from commits that changed code and existing tests together. The tests they edited
      # are the ones written to verify the change.
      def self.co_changed_cases(repo, map, limit: 200)
        shas = repo.git("log", "--no-merges", "--format=%H", "-n", (limit * 10).to_s).split("\n")
        shas.each_with_object([]) do |sha, cases|
          break cases if cases.size >= limit

          files = Diff.parse(repo.git("diff", "--no-color", "-M", "--unified=0", "#{sha}^", sha, allow_failure: true).to_s)
          tests = files.select { |f| Rules.test_file?(f.path) && f.status == :modified && map.tests.key?(f.path) }.map(&:path)
          code = files.reject { |f| f.path.start_with?(Rules::TEST_ROOT) || Rules.quiet?(f.path) }
          next if tests.empty? || code.empty?

          cases << { "id" => sha[0, 10], "base" => "#{sha}^", "head" => sha, "expected" => tests, "hide_tests" => true }
        end
      end

      def initialize(repo:, map:, ranker: nil, granularity: :method)
        @repo = repo
        @map = map
        @ranker = ranker
        @granularity = granularity
      end

      def run(cases)
        cases.filter_map do |kase|
          expected = kase.fetch("expected") & @map.test_files
          next if expected.empty? || !@repo.commit?(kase.fetch("head"))

          exclude = kase["hide_tests"] ? ->(path) { path.start_with?(Rules::TEST_ROOT) } : nil
          selection = Selector.new(repo: @repo, map: @map, base: kase.fetch("base"), head: kase.fetch("head"),
                                   intent: kase["intent"], ranker: @ranker, exclude: exclude, granularity: @granularity).call
          selected = selection.whole_suite ? @map.test_files : selection.tests
          Result.new(id: kase.fetch("id"), expected: expected, selected: selected, hit: expected & selected,
                     suite_size: @map.test_files.size, seconds_share: seconds_share(selected), whole_suite: selection.whole_suite,
                     confidence: selection.confidence)
        end
      end

      def seconds_share(selected)
        total = @map.tests.values.sum(&:seconds)
        total.zero? ? 0.0 : selected.sum { |test| @map.seconds(test).to_f } / total
      end

      def self.summary(results)
        return {} if results.empty?

        n = results.size.to_f
        {
          "cases" => results.size,
          "caught" => (results.count(&:caught?) / n).round(3),
          "all_caught" => (results.count(&:all_caught?) / n).round(3),
          "recall" => (results.sum(&:recall) / n).round(3),
          "precision" => (results.sum(&:precision) / n).round(3),
          "selected_share" => (results.sum { |r| r.selected.size.to_f / r.suite_size } / n).round(3),
          "seconds_share" => (results.sum(&:seconds_share) / n).round(3),
          "whole_suite" => results.count(&:whole_suite)
        }
      end
    end
  end
end
