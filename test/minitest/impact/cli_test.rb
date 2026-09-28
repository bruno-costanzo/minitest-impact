# frozen_string_literal: true

require "test_helper"
require "minitest/impact/rake_task"

class CLITest < Minitest::Test
  def setup
    sandbox.write("lib/a.rb", "class A\n  def x\n    1\n  end\nend\n")
    sandbox.write("test/a_test.rb", "require \"minitest/autorun\"\nclass ATest < Minitest::Test\n  def test_a = assert(true)\nend\n")
    sandbox.write("docs/a.md", "a\n")
    @base = sandbox.commit
    map_with(@base, "test/a_test.rb" => { "lib/a.rb" => [3] }).save(File.join(sandbox.root, Minitest::Impact::Map::DEFAULT_PATH))
  end

  def cli(*args)
    out = StringIO.new
    err = StringIO.new
    status = Dir.chdir(sandbox.root) { Minitest::Impact::CLI.start(args, out: out, err: err, env: {}) }
    [status, out.string, err.string]
  end

  def test_select_prints_text_json_and_paths
    File.write(File.join(sandbox.root, "lib/a.rb"), "class A\n  def x\n    2\n  end\nend\n")

    status, text, = cli("select")
    assert_equal 0, status
    assert_match(/Confidence: high/, text)
    assert_match(%r{1\.00  test/a_test\.rb  - runs A#x}, text)

    _, json, = cli("select", "--format", "json", "--max", "1")
    assert_equal ["test/a_test.rb"], JSON.parse(json)["tests"].map { |t| t["test"] }

    _, paths, = cli("select", "--format", "paths", "--since", @base, "--no-jev")
    assert_equal "test/a_test.rb\n", paths
  end

  def test_whole_suite_exits_10_in_paths_mode_and_run
    File.write(File.join(sandbox.root, "Gemfile.lock"), "GEM\n")

    assert_equal 10, cli("select", "--format", "paths").first
    assert_equal 10, cli("run").first
  end

  def test_run_runs_the_selected_tests_or_nothing
    File.write(File.join(sandbox.root, "docs/a.md"), "b\n")
    status, out, = cli("run")
    assert_equal 0, status
    assert_match(/No tests selected/, out)

    File.write(File.join(sandbox.root, "lib/a.rb"), "class A\n  def x\n    2\n  end\nend\n")
    assert_equal 0, cli("run").first
  end

  def test_eval_measures_recall_on_co_changed_commits
    File.write(File.join(sandbox.root, "lib/a.rb"), "class A\n  def x\n    2\n  end\nend\n")
    File.write(File.join(sandbox.root, "test/a_test.rb"), File.read(File.join(sandbox.root, "test/a_test.rb")) + "# more\n")
    sandbox.commit("code and test")

    status, out, = cli("eval", "--co-changed", "5", "--format", "json")

    assert_equal 0, status
    summary = JSON.parse(out)["summary"]
    assert_equal 1, summary["cases"]
    assert_in_delta 1.0, summary["recall"]

    cases = File.join(sandbox.root, "cases.json")
    File.write(cases, [{ id: "x", base: @base, head: "HEAD", expected: ["test/a_test.rb"] }].to_json)
    _, text, = cli("eval", "--cases", cases)
    assert_match(/caught=true/, text)
    _, text, = cli("eval", "--cases", cases, "--granularity", "file")
    assert_match(/caught=true/, text)
  end

  def test_errors_and_help
    assert_equal 0, cli("--help").first
    assert_equal 1, cli("nonsense").first
    status, _, err = cli("eval")
    assert_equal 1, status
    assert_match(/--cases/, err)
    File.delete(File.join(sandbox.root, Minitest::Impact::Map::DEFAULT_PATH))
    assert_match(/no coverage map/, cli("select")[2])
  end

  def test_rake_task_defines_test_impact
    Rake.application = Rake::Application.new
    Minitest::Impact::RakeTask.new

    assert Rake::Task.task_defined?("test:impact")
  end
end
