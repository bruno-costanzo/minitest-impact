# frozen_string_literal: true

require "json"
require "optparse"
require "tmpdir"

module Minitest
  module Impact
    # minitest-impact record | select | run | eval
    class CLI
      WHOLE_SUITE_EXIT = 10

      def self.start(argv, out: $stdout, err: $stderr, env: ENV) = new(out: out, err: err, env: env).call(argv)

      def initialize(out:, err:, env:)
        @out = out
        @err = err
        @env = env
      end

      def call(argv)
        command = argv.shift
        case command
        when "record" then record(argv)
        when "select" then select(argv)
        when "run" then run(argv)
        when "eval" then evaluate(argv)
        else
          @out.puts(USAGE)
          command.nil? || %w[-h --help help].include?(command) ? 0 : 1
        end
      rescue Error, OptionParser::ParseError => error
        @err.puts("minitest-impact: #{error.message}")
        1
      end

      USAGE = <<~TEXT
        Usage:
          minitest-impact record [--map PATH] -- COMMAND...   Run your suite and record the coverage map
          minitest-impact select [--since REV] [options]      Print the tests a change should run
          minitest-impact run    [--since REV] [options]      Select, then run them with bin/rails test
          minitest-impact eval   (--cases FILE | --co-changed N) [--jev] [--granularity method|file]
                                                               Measure selection on history

        Select options:
          --since REV       compare against REV (default HEAD: the uncommitted change)
          --head REV        compare REV instead of the working tree
          --intent TEXT     what the change is for, in words (used by Jev only)
          --map PATH        coverage map (default #{Map::DEFAULT_PATH})
          --format FORMAT   text (default), json or paths
          --max N           keep the N most likely test files
          --no-jev          map and rules only, even with TYPESAFE_API_KEY set

        Exit status 10 from select/run with --format paths means: run the whole suite.
      TEXT

      private

      def record(argv)
        map_path = Map::DEFAULT_PATH
        if argv.first == "--map"
          argv.shift
          map_path = argv.shift
        end
        argv.shift if argv.first == "--"
        raise Error, "record needs a command, e.g. minitest-impact record -- bin/rails test" if argv.empty?

        repo = Repo.new
        Dir.mktmpdir("minitest-impact") do |dir|
          lib = File.expand_path("../..", __dir__)
          bootstrap = File.join(__dir__, "record_bootstrap.rb")
          env = {
            "MINITEST_IMPACT_RECORD" => dir,
            "MINITEST_IMPACT_ROOT" => repo.root,
            "RUBYOPT" => ["-I#{lib}", "-r#{bootstrap}", @env["RUBYOPT"]].compact.join(" ")
          }
          ok = system(env, *argv)
          map = Map.merge(File.join(dir, Recorder::PARTS), commit: repo.head)
          raise Error, "no test recorded anything; is the command a Minitest run?" if map.tests.empty?

          map.save(map_path)
          dirty = !repo.git("status", "--porcelain", "--untracked-files=no").empty?
          @err.puts("minitest-impact: the working tree has changes; the map describes them, not #{repo.head[0, 10]}") if dirty
          @out.puts("Recorded #{map.tests.size} test files at #{repo.head[0, 10]} into #{map_path}")
          ok ? 0 : 1
        end
      end

      def select_options(argv)
        options = { since: "HEAD", format: "text", map: Map::DEFAULT_PATH, jev: true }
        OptionParser.new do |parser|
          parser.on("--since REV") { |v| options[:since] = v }
          parser.on("--head REV") { |v| options[:head] = v }
          parser.on("--intent TEXT") { |v| options[:intent] = v }
          parser.on("--map PATH") { |v| options[:map] = v }
          parser.on("--format FORMAT", %w[text json paths]) { |v| options[:format] = v }
          parser.on("--max N", Integer) { |v| options[:max] = v }
          parser.on("--[no-]jev") { |v| options[:jev] = v }
        end.parse!(argv)
        options
      end

      def selection(options)
        raise Error, "no coverage map at #{options[:map]}; run: minitest-impact record -- bin/rails test" unless File.exist?(options[:map])

        repo = Repo.new
        ranker = options[:jev] ? jev_ranker : nil
        selection = Selector.new(repo: repo, map: Map.load(options[:map]), base: options[:since], head: options[:head],
                                 intent: options[:intent], ranker: ranker).call
        selection.picks = selection.picks.first(options[:max]) if options[:max]
        selection
      end

      def jev_ranker
        client = Jev::Client.from_env(@env)
        client && Jev::Ranker.new(client: client)
      end

      def select(argv)
        options = select_options(argv)
        result = selection(options)
        case options[:format]
        when "json" then @out.puts(JSON.pretty_generate(result.to_h))
        when "paths"
          return WHOLE_SUITE_EXIT if result.whole_suite

          result.tests.each { |test| @out.puts(test) }
        else print_text(result)
        end
        0
      end

      def run(argv)
        result = selection(select_options(argv))
        print_text(result)
        return WHOLE_SUITE_EXIT if result.whole_suite
        return 0 if result.tests.empty?

        runner = File.exist?("bin/rails") ? ["bin/rails", "test"] : ["ruby", "-Itest", "-e", "ARGV.each { |f| require File.expand_path(f) }"]
        system(*runner, *result.tests) ? 0 : 1
      end

      def print_text(result)
        @out.puts("Confidence: #{result.confidence}#{result.whole_suite ? " (run the whole suite)" : ""}")
        result.warnings.each { |warning| @out.puts("Warning: #{warning}") }
        @out.puts("Jev: #{result.jev.map { |k, v| "#{k}=#{v}" }.join(" ")}") if result.jev
        result.resolutions.each do |resolution|
          @out.puts("  #{resolution.how.to_s.ljust(12)} #{resolution.path}#{resolution.note ? "  (#{resolution.note})" : ""}")
        end
        @out.puts(result.picks.empty? ? "No tests selected." : "#{result.picks.size} test files, most likely first:")
        result.picks.each do |pick|
          @out.puts(format("  %.2f  %s  - %s", pick.score, pick.test, pick.reasons.first(2).join("; ")))
        end
      end

      def evaluate(argv)
        options = { map: Map::DEFAULT_PATH, jev: false, format: "text", granularity: :method }
        OptionParser.new do |parser|
          parser.on("--cases FILE") { |v| options[:cases] = v }
          parser.on("--co-changed N", Integer) { |v| options[:co_changed] = v }
          parser.on("--map PATH") { |v| options[:map] = v }
          parser.on("--[no-]jev") { |v| options[:jev] = v }
          parser.on("--format FORMAT", %w[text json]) { |v| options[:format] = v }
          parser.on("--granularity LEVEL", %w[method file]) { |v| options[:granularity] = v.to_sym }
        end.parse!(argv)
        repo = Repo.new
        map = Map.load(options[:map])
        cases = if options[:cases]
                  JSON.parse(File.read(options[:cases]))
                elsif options[:co_changed]
                  Evaluation.co_changed_cases(repo, map, limit: options[:co_changed])
                else
                  raise Error, "eval needs --cases FILE or --co-changed N"
                end
        results = Evaluation.new(repo: repo, map: map, ranker: options[:jev] ? jev_ranker : nil, granularity: options[:granularity]).run(cases)
        summary = Evaluation.summary(results)
        if options[:format] == "json"
          @out.puts(JSON.pretty_generate("summary" => summary, "cases" => results.map { |r| r.to_h.merge(recall: r.recall, precision: r.precision) }))
        else
          results.each do |r|
            @out.puts(format("%-12s caught=%-5s recall=%.2f precision=%.2f selected=%d/%d %s", r.id, r.caught?, r.recall, r.precision,
                             r.selected.size, r.suite_size, r.confidence))
          end
          @out.puts(JSON.pretty_generate(summary))
        end
        0
      end
    end
  end
end
