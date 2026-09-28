# frozen_string_literal: true

require "rake"
require_relative "../impact"
require_relative "cli"

module Minitest
  module Impact
    # Defines `rake test:impact` (and so `bin/rails test:impact`): runs the tests the current
    # change selects. SINCE=REV sets the base (default HEAD), INTENT="..." describes the change.
    # When the change needs the whole suite, it runs `test` instead.
    class RakeTask
      include Rake::DSL

      def initialize(name = "test:impact")
        desc "Run the tests the current change is most likely to break (minitest-impact)"
        task(name) do
          args = ["run", "--since", ENV.fetch("SINCE", "HEAD")]
          args += ["--intent", ENV["INTENT"]] if ENV["INTENT"]
          status = CLI.start(args)
          if status == CLI::WHOLE_SUITE_EXIT
            Rake::Task["test"].invoke
          elsif !status.zero?
            abort
          end
        end
      end
    end
  end
end
