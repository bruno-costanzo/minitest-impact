# frozen_string_literal: true

# Required through RUBYOPT by `minitest-impact record`, before the application or Bundler load, so
# coverage sees every project file from its first line. Minitest 6 no longer loads plugins on its
# own, so a TracePoint waits for Minitest::Test to be defined and wraps every test from there. The
# same TracePoint switches SimpleCov off as soon as it is defined: Ruby allows one coverage setup
# per process, and an app that starts SimpleCov unconditionally would otherwise fail to boot.
require_relative "recorder"

if (dir = ENV["MINITEST_IMPACT_RECORD"])
  Minitest::Impact::Recorder.start(dir: dir, root: ENV.fetch("MINITEST_IMPACT_ROOT", Dir.pwd))

  hooked = []
  module_name = Module.instance_method(:name)
  trace = TracePoint.new(:class) do |event|
    name = module_name.bind_call(event.self)
    next if hooked.include?(name)

    case name
    when "Minitest::Test"
      require_relative "recording_hooks"
      event.self.prepend(Minitest::Impact::RecordingHooks)
    when "SimpleCov"
      require_relative "simplecov_off"
      event.self.singleton_class.prepend(Minitest::Impact::SimpleCovOff)
    else next
    end
    hooked << name
    trace.disable if hooked.size == 2
  end
  trace.enable
end
