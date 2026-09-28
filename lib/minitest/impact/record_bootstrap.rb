# frozen_string_literal: true

# Required through RUBYOPT by `minitest-impact record`, before the application or Bundler load, so
# coverage sees every project file from its first line. Minitest 6 no longer loads plugins on its
# own, so a TracePoint waits for Minitest::Test to be defined and wraps every test from there.
require_relative "recorder"

if (dir = ENV["MINITEST_IMPACT_RECORD"])
  Minitest::Impact::Recorder.start(dir: dir, root: ENV.fetch("MINITEST_IMPACT_ROOT", Dir.pwd))

  trace = TracePoint.new(:class) do |event|
    next unless event.self.name == "Minitest::Test"

    trace.disable
    require_relative "recording_hooks"
    event.self.prepend(Minitest::Impact::RecordingHooks)
  end
  trace.enable
end
