# frozen_string_literal: true

require "coverage"

module Minitest
  module Impact
    # Records which project lines each test executes. Loaded through RUBYOPT before the
    # application boots (see `minitest-impact record`), so it depends on the standard library only,
    # and loads no gem there: json, a default gem, would be activated at its newest installed version
    # and the app's bundle would then refuse to boot on any other. It is required at the first write,
    # after the bundle chose its version.
    #
    # Each test appends one JSON line to a file named after its process, so forked parallel
    # workers never share a file handle; `Map.merge` folds the parts into one map afterwards.
    module Recorder
      PARTS = "parts"

      class << self
        attr_reader :root, :dir, :mode

        def start(dir:, root: Dir.pwd)
          return if @started

          @root = File.expand_path(root)
          @dir = File.expand_path(dir)
          Dir.mkdir(File.join(@dir, PARTS)) unless Dir.exist?(File.join(@dir, PARTS))
          @mode = begin_coverage
          @started = true
        end

        def started? = @started == true

        def before_test
          if mode == :clear
            Coverage.result(stop: false, clear: true)
          else
            @baseline = Coverage.peek_result
          end
          @clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def after_test(test_file:, name:)
          seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @clock
          lines = executed_lines
          write(test: relative(test_file), name: name, seconds: seconds.round(4), lines: lines)
        end

        # Judged on the path inside the project: a project that itself lives under a `tmp`
        # directory (Linux's temporary directories, some CI workspaces) must still be recorded.
        def project_file?(path)
          path.start_with?("#{root}/") &&
            !"/#{relative(path)}".match?(%r{/(vendor|tmp|node_modules)/})
        end

        def relative(path) = path.delete_prefix("#{root}/")

        private

        # Coverage can be set up once per process. When another tool (SimpleCov) got there first,
        # clearing its counters would corrupt its report, so each test is measured as the
        # difference between two snapshots instead: slower, but harmless to the other tool.
        def begin_coverage
          if Coverage.running?
            :peek
          else
            Coverage.setup(lines: true, eval: true)
            Coverage.resume
            :clear
          end
        end

        def executed_lines
          now = mode == :clear ? Coverage.result(stop: false, clear: true) : Coverage.peek_result
          now.each_with_object({}) do |(path, data), acc|
            next unless project_file?(path)

            counts = data.is_a?(Hash) ? data[:lines] : data
            next unless counts

            before = mode == :peek ? line_counts(@baseline[path]) : nil
            hit = []
            counts.each_with_index do |count, index|
              next unless count&.positive?
              next if before && before[index].to_i >= count

              hit << index + 1
            end
            acc[relative(path)] = hit unless hit.empty?
          end
        end

        def line_counts(data)
          return [] unless data

          data.is_a?(Hash) ? (data[:lines] || []) : data
        end

        def write(record)
          require "json"
          File.open(File.join(dir, PARTS, "#{Process.pid}.ndjson"), "a") do |file|
            file.puts(JSON.generate(record))
          end
        end
      end
    end
  end
end
