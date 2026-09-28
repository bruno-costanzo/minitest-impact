# frozen_string_literal: true

require "fileutils"
require "json"
require "set"
require "time"

module Minitest
  module Impact
    # The coverage map: for each test file, the project lines its tests executed, plus how long it
    # took. Stored as JSON with line numbers folded into ranges ("3-7,12"), so a Rails app's map
    # stays a few hundred kilobytes.
    class Map
      FORMAT = 1
      DEFAULT_PATH = "tmp/minitest-impact/map.json"

      TestEntry = Struct.new(:seconds, :count, :files, keyword_init: true)

      attr_reader :commit, :recorded_at, :tests

      def self.load(path)
        data = JSON.parse(File.read(path))
        raise Error, "#{path} is map format #{data["format"]}, this version reads #{FORMAT}" unless data["format"] == FORMAT

        tests = data.fetch("tests").to_h do |test, entry|
          files = entry.fetch("files").transform_values { |ranges| Ranges.parse(ranges) }
          [test, TestEntry.new(seconds: entry["seconds"].to_f, count: entry["count"].to_i, files: files)]
        end
        new(commit: data["commit"], recorded_at: data["recorded_at"], tests: tests)
      end

      # Folds the per-process parts a recording wrote into one map.
      def self.merge(parts_dir, commit:)
        tests = Hash.new { |hash, key| hash[key] = TestEntry.new(seconds: 0.0, count: 0, files: Hash.new { |h, k| h[k] = Set.new }) }
        Dir[File.join(parts_dir, "*.ndjson")].sort.each do |part|
          File.foreach(part) do |line|
            record = JSON.parse(line)
            entry = tests[record.fetch("test")]
            entry.seconds += record["seconds"].to_f
            entry.count += 1
            record.fetch("lines").each { |file, lines| entry.files[file].merge(lines) }
          end
        end
        new(commit: commit, recorded_at: Time.now.utc.iso8601, tests: tests.to_h { |test, entry| [test, freeze_entry(entry)] })
      end

      def self.freeze_entry(entry)
        TestEntry.new(seconds: entry.seconds.round(3), count: entry.count, files: entry.files.to_h { |f, l| [f, l.to_a.sort] })
      end
      private_class_method :freeze_entry

      def initialize(commit:, recorded_at:, tests:)
        @commit = commit
        @recorded_at = recorded_at
        @tests = tests
      end

      def save(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(to_h))
      end

      def to_h
        {
          "format" => FORMAT,
          "commit" => commit,
          "recorded_at" => recorded_at,
          "tests" => tests.sort.to_h do |test, entry|
            [test, { "seconds" => entry.seconds, "count" => entry.count,
                     "files" => entry.files.sort.to_h { |file, lines| [file, Ranges.dump(lines)] } }]
          end
        }
      end

      def test_files = tests.keys

      def known_file?(path) = by_file.key?(path)

      # test file => executed lines of +path+
      def tests_for(path) = by_file.fetch(path, {})

      # Share of all test files that touch +path+: near 1 for a base class every test loads, near 0
      # for a file only its own tests reach.
      def spread(path)
        return 0.0 if tests.empty?

        tests_for(path).size.to_f / tests.size
      end

      def seconds(test) = tests[test]&.seconds

      private

      def by_file
        @by_file ||= tests.each_with_object(Hash.new { |h, k| h[k] = {} }) do |(test, entry), index|
          entry.files.each { |file, lines| index[file][test] = lines }
        end.tap { |index| index.default_proc = nil }
      end
    end

    # "1-3,7" <-> [1, 2, 3, 7]
    module Ranges
      def self.dump(lines)
        lines.sort.slice_when { |a, b| b != a + 1 }.map { |run| run.size == 1 ? run.first.to_s : "#{run.first}-#{run.last}" }.join(",")
      end

      def self.parse(text)
        text.split(",").flat_map do |part|
          first, last = part.split("-").map(&:to_i)
          last ? (first..last).to_a : [first]
        end
      end
    end
  end
end
