# frozen_string_literal: true

module Minitest
  module Impact
    module Jev
      # Every question and threshold sent to Jev, in one file so they can be reviewed together
      # (TypeSafe's agent skill). One narrow judgment per question, all asked over one state in one
      # request. Rules (which files need the whole suite, what a test file is) stay in Rules.
      module Questions
        # Candidates per request: 48 Nouls and a 49-option Choice keep the state and the longest
        # question well under jev-1.13's 32k-token bound.
        MAX_CANDIDATES = 48
        MAX_DIFF_CHARS = 12_000
        MAX_TEST_NAMES = 8

        # UNTUNED until `minitest-impact eval --jev` runs on labelled cases; see README, "Tuning".
        KEEP = 0.5
        MOST_DIRECT = 0.5
        WHOLE_SUITE = 0.8

        NONE = "none"

        module_function

        def exercises(index)
          {
            type: "noul",
            instructions: "Do the tests in `candidates[#{index}]` call, render or assert on something that `change` adds, edits or removes?",
            criteria: {
              true: "They exercise code, pages, routes, copy or data that the change modifies.",
              false: "They test other features. A shared word in the file names is not enough."
            }
          }
        end

        def most_direct(count)
          {
            type: "choice",
            instructions: "Which candidate test file was written to check the behaviour that `change` modifies?",
            criteria: Array.new(count) { |index| ["t#{index}", "The test file `candidates[#{index}]`."] }.to_h
              .merge(NONE => "None of the candidates checks this behaviour.")
          }
        end

        def whole_suite
          {
            type: "noul",
            instructions: "Does `change` modify something that every test depends on, such as test setup, gem versions or how the application boots?",
            criteria: {
              true: "Any test could fail because of this change.",
              false: "Only tests of particular features could fail."
            }
          }
        end
      end
    end
  end
end
