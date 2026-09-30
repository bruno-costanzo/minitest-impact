# frozen_string_literal: true

module Minitest
  module Impact
    module Jev
      # Re-ranks and extends a map selection with Jev, for what the map cannot see: new files,
      # views, config, copy, and selections too large to run in a loop. A fast word-overlap search
      # over test paths and test names builds a shortlist; Jev reads the change once and answers one
      # question per candidate, in one request (docs.typesafe.ai/cookbooks/rerank_typesafe).
      #
      # Jev only adds and reorders; it never drops a pick. Measured on Piou Piou's history, dropping
      # lost tests the change needed and bought little, while the new order put the test written
      # for the change first far more often.
      class Ranker
        EXACT = 0.9

        def initialize(client:)
          @client = client
        end

        def call(picks:, changes:, intent:, repo:, map:, head:)
          candidates = shortlist(picks, changes, intent, repo, map, head)
          return [picks, nil] if candidates.empty?

          response = @client.ask(state: state(candidates, changes, intent, repo, head), questions: questions(candidates.size))
          [combine(picks, candidates, response.answers, map), report(response, candidates)]
        rescue Client::Failure => error
          [picks, { "error" => error.message }]
        end

        private

        def shortlist(picks, changes, intent, repo, map, head)
          chosen = picks.first(Questions::MAX_CANDIDATES).map(&:test)
          room = Questions::MAX_CANDIDATES - chosen.size
          return chosen if room <= 0

          words = query_words(changes, intent)
          pool = (map.test_files + repo.files(head).select { |file| Rules.test_file?(file) }).uniq - chosen
          scored = pool.filter_map do |test|
            overlap = (words & test_words(test, repo, head)).size
            [test, overlap] if overlap.positive?
          end
          chosen + scored.sort_by { |test, overlap| [-overlap, test] }.first(room).map(&:first)
        end

        def query_words(changes, intent)
          text = changes.map { |change| "#{change.path} #{change.added_text} #{change.removed_text}" }.join(" ") + " #{intent}"
          words(text)
        end

        def test_words(test, repo, head)
          words("#{test} #{test_names(test, repo, head).join(" ")}")
        end

        STOP = %w[test tests rb app the and for with that this should when from into def end do].freeze

        def words(text)
          text.downcase.scan(/[a-z][a-z0-9]{2,}/).map { |word| Rules.singularize(word) }.uniq - STOP
        end

        def test_names(test, repo, head)
          source = repo.read(test, head) || ""
          source.scan(/^\s*test\s+["'](.+?)["']|^\s*def\s+(test_\w+)/).map { |a, b| a || b.tr("_", " ") }.first(Questions::MAX_TEST_NAMES)
        end

        def state(candidates, changes, intent, repo, head)
          budget = Questions::MAX_DIFF_CHARS
          change = changes.map do |c|
            excerpt = [c.removed_text.lines.map { |l| "-#{l}" }, c.added_text.lines.map { |l| "+#{l}" }].flatten.join
            excerpt = excerpt[0, [budget, 0].max]
            budget -= excerpt.size
            { path: c.path, status: c.status.to_s, diff: excerpt }
          end
          {
            intent: intent.to_s,
            change: change,
            candidates: candidates.map { |test| { path: test, tests: test_names(test, repo, head) } }
          }
        end

        def questions(count)
          asked = Array.new(count) { |index| ["t#{index}", Questions.exercises(index)] }.to_h
          asked.merge("most_direct" => Questions.most_direct(count), "whole_suite" => Questions.whole_suite)
        end

        def combine(picks, candidates, answers, map)
          by_test = picks.to_h { |pick| [pick.test, pick] }
          best = answers["most_direct"]
          direct = best && best["choice"] != Questions::NONE && best["confidence"].to_f >= Questions::MOST_DIRECT ? best["choice"] : nil

          candidates.each_with_index do |test, index|
            noul = answers.dig("t#{index}", "noul")
            next if noul.nil?

            pick = by_test[test]
            if pick.nil?
              next if noul < Questions::KEEP

              by_test[test] = Pick.new(test: test, score: noul * 0.8, reasons: ["Jev: exercises the change (#{noul.round(2)})"], seconds: map.seconds(test))
            else
              pick.score = pick.score >= EXACT ? pick.score : (pick.score + noul) / 2
              pick.reasons += ["Jev: #{noul.round(2)}"]
            end
            by_test[test].score = 1.0 + (by_test[test].score / 10) if by_test[test] && direct == "t#{index}"
          end
          by_test.values.sort_by { |pick| [-pick.score, pick.seconds || Float::INFINITY, pick.test] }
        end

        def report(response, candidates)
          {
            "model" => response.model,
            "input_tokens" => response.input_tokens,
            "candidates" => candidates.size,
            "whole_suite" => response.answers.dig("whole_suite", "noul").to_f >= Questions::WHOLE_SUITE
          }
        end
      end
    end
  end
end
