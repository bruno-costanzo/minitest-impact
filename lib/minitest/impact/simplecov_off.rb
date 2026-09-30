# frozen_string_literal: true

module Minitest
  module Impact
    # Prepended to SimpleCov while recording and during `run`. `SimpleCov.start` does nothing: no
    # second coverage setup beside the recorder's, no report, and no minimum-coverage exit status
    # measured on counters the recorder clears or on a handful of selected tests.
    module SimpleCovOff
      def start(*) = nil
    end
  end
end
