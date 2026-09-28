# frozen_string_literal: true

module Minitest
  module Impact
    # Adds `bin/rails test:impact` to a Rails app that has the gem in its Gemfile.
    class Railtie < Rails::Railtie
      rake_tasks do
        require_relative "rake_task"
        RakeTask.new
      end
    end
  end
end
