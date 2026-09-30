# frozen_string_literal: true

# Required through RUBYOPT by `minitest-impact run`, before the application loads. Coverage measured
# on a few selected tests says nothing, and an app's minimum-coverage check would turn a green run
# red; so SimpleCov does nothing for the run, as while recording.
module_name = Module.instance_method(:name)
trace = TracePoint.new(:class) do |event|
  next unless module_name.bind_call(event.self) == "SimpleCov"

  require_relative "simplecov_off"
  event.self.singleton_class.prepend(Minitest::Impact::SimpleCovOff)
  trace.disable
end
trace.enable
