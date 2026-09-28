# frozen_string_literal: true

module Minitest
  module Impact
    # Prepended to Minitest::Test while recording, so the measurement starts before every other
    # before_setup (fixtures included) and ends after every other after_teardown.
    module RecordingHooks
      def before_setup
        Recorder.before_test
        super
      end

      def after_teardown
        super
      ensure
        file = self.class.instance_method(name).source_location&.first
        Recorder.after_test(test_file: file, name: "#{self.class.name}##{name}") if file
      end
    end
  end
end
