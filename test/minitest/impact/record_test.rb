# frozen_string_literal: true

require "test_helper"

# Records a real Minitest run in a child process, through the same RUBYOPT bootstrap an app gets.
class RecordTest < Minitest::Test
  def setup
    sandbox.write("lib/calc.rb", <<~RUBY)
      class Calc
        def add(a, b)
          a + b
        end

        def sub(a, b)
          a - b
        end
      end
    RUBY
    sandbox.write("test/add_test.rb", <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/calc"

      class AddTest < Minitest::Test
        def test_add = assert_equal(3, Calc.new.add(1, 2))
      end
    RUBY
    sandbox.write("test/sub_test.rb", <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/calc"

      class SubTest < Minitest::Test
        def test_sub = assert_equal(1, Calc.new.sub(2, 1))
      end
    RUBY
    sandbox.commit("calc")
  end

  def test_records_the_lines_each_test_file_ran_and_selects_by_method
    out = StringIO.new
    status = Dir.chdir(sandbox.root) do
      Minitest::Impact::CLI.start(["record", "--", "ruby", "-e", "Dir['test/*_test.rb'].each { |f| require File.expand_path(f) }"],
                                  out: out, err: StringIO.new)
    end

    assert_equal 0, status
    assert_match(/Recorded 2 test files/, out.string)
    map = Minitest::Impact::Map.load(File.join(sandbox.root, Minitest::Impact::Map::DEFAULT_PATH))
    assert_equal [3], map.tests["test/add_test.rb"].files["lib/calc.rb"]
    assert_equal [7], map.tests["test/sub_test.rb"].files["lib/calc.rb"]

    File.write(File.join(sandbox.root, "lib/calc.rb"), File.read(File.join(sandbox.root, "lib/calc.rb")).sub("a - b", "b - a"))
    paths = StringIO.new
    Dir.chdir(sandbox.root) { Minitest::Impact::CLI.start(%w[select --format paths], out: paths, err: StringIO.new) }
    assert_equal "test/sub_test.rb\n", paths.string
  end

  def test_a_project_under_a_tmp_directory_is_still_recorded
    recorder = Minitest::Impact::Recorder
    root = recorder.instance_variable_get(:@root)
    recorder.instance_variable_set(:@root, "/tmp/build/app")

    assert recorder.project_file?("/tmp/build/app/lib/calc.rb")
    refute recorder.project_file?("/tmp/build/app/tmp/cache/x.rb")
    refute recorder.project_file?("/tmp/build/app/vendor/bundle/gem.rb")
    refute recorder.project_file?("/tmp/build/other/lib/calc.rb")
  ensure
    recorder.instance_variable_set(:@root, root)
  end

  def test_record_without_a_command_or_tests_fails
    err = StringIO.new
    assert_equal 1, Dir.chdir(sandbox.root) { Minitest::Impact::CLI.start(["record"], out: StringIO.new, err: err) }
    assert_equal 1, Dir.chdir(sandbox.root) { Minitest::Impact::CLI.start(%w[record -- true], out: StringIO.new, err: err) }
    assert_match(/no test recorded anything/, err.string)
  end
end
