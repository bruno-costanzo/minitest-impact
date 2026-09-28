# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/impact"
require "minitest/impact/cli"
require "minitest/autorun"
require "webmock/minitest"
require "fileutils"
require "tmpdir"
require "open3"

WebMock.disable_net_connect!

module RepoHelpers
  # A throwaway git repository. Files are written, then committed with #commit.
  class Sandbox
    attr_reader :root

    def initialize
      @root = Dir.mktmpdir("minitest-impact-test")
      git("init", "-q", "-b", "main")
      git("config", "user.email", "test@example.com")
      git("config", "user.name", "Test")
      git("config", "commit.gpgsign", "false")
    end

    def write(path, text)
      full = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end

    def delete(path) = File.delete(File.join(root, path))

    def commit(message = "change")
      git("add", "-A")
      git("commit", "-q", "-m", message)
      git("rev-parse", "HEAD").strip
    end

    def git(*args)
      out, err, status = Open3.capture3("git", "-C", root, *args)
      raise "git #{args.join(" ")}: #{err}" unless status.success?

      out
    end

    def repo = Minitest::Impact::Repo.new(root)

    def cleanup = FileUtils.rm_rf(root)
  end

  def sandbox
    @sandbox ||= Sandbox.new
  end

  def after_teardown
    super
  ensure
    @sandbox&.cleanup
  end

  def map_with(commit, tests)
    entries = tests.to_h do |test, files|
      [test, Minitest::Impact::Map::TestEntry.new(seconds: 1.0, count: 1, files: files)]
    end
    Minitest::Impact::Map.new(commit: commit, recorded_at: "2026-09-28T00:00:00Z", tests: entries)
  end
end

class Minitest::Test
  prepend RepoHelpers
end
