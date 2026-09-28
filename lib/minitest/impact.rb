# frozen_string_literal: true

module Minitest
  module Impact
    class Error < StandardError; end
  end
end

require_relative "impact/version"
require_relative "impact/recorder"
require_relative "impact/map"
require_relative "impact/repo"
require_relative "impact/diff"
require_relative "impact/methods"
require_relative "impact/rules"
require_relative "impact/locale_keys"
require_relative "impact/jev/client"
require_relative "impact/jev/questions"
require_relative "impact/jev/ranker"
require_relative "impact/selector"
require_relative "impact/evaluation"
require_relative "impact/railtie" if defined?(Rails::Railtie)
