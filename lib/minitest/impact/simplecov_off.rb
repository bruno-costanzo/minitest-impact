# frozen_string_literal: true

module Minitest
  module Impact
    # Prepended to SimpleCov while recording. The recorder owns Coverage for the whole run, so
    # `SimpleCov.start` does nothing: no second coverage setup, no report and no minimum-coverage
    # exit status measured against counters the recorder clears after every test.
    module SimpleCovOff
      def start(*) = nil
    end
  end
end
