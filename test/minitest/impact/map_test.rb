# frozen_string_literal: true

require "test_helper"

class MapTest < Minitest::Test
  def test_ranges_fold_and_unfold_line_numbers
    assert_equal "1-3,7,9-10", Minitest::Impact::Ranges.dump([7, 1, 2, 3, 9, 10])
    assert_equal [1, 2, 3, 7, 9, 10], Minitest::Impact::Ranges.parse("1-3,7,9-10")
    assert_equal [], Minitest::Impact::Ranges.parse("")
  end

  def test_merge_folds_every_process_part_into_one_entry_per_test_file
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "1.ndjson"), [
        { test: "test/a_test.rb", seconds: 0.5, lines: { "lib/a.rb" => [1, 2] } },
        { test: "test/b_test.rb", seconds: 0.25, lines: { "lib/b.rb" => [4] } }
      ].map(&:to_json).join("\n") + "\n")
      File.write(File.join(dir, "2.ndjson"), { test: "test/a_test.rb", seconds: 0.5, lines: { "lib/a.rb" => [2, 3] } }.to_json + "\n")

      map = Minitest::Impact::Map.merge(dir, commit: "abc")

      assert_equal({ "lib/a.rb" => [1, 2, 3] }, map.tests["test/a_test.rb"].files)
      assert_equal 2, map.tests["test/a_test.rb"].count
      assert_in_delta 1.0, map.seconds("test/a_test.rb")
    end
  end

  def test_save_and_load_round_trip_and_answer_by_file
    map = map_with("abc", "test/a_test.rb" => { "lib/a.rb" => [1, 2] }, "test/b_test.rb" => { "lib/a.rb" => [5], "lib/b.rb" => [1] })
    Dir.mktmpdir do |dir|
      path = File.join(dir, "map.json")
      map.save(path)
      loaded = Minitest::Impact::Map.load(path)

      assert_equal "abc", loaded.commit
      assert_equal({ "test/a_test.rb" => [1, 2], "test/b_test.rb" => [5] }, loaded.tests_for("lib/a.rb"))
      assert_in_delta 1.0, loaded.spread("lib/a.rb")
      assert_in_delta 0.5, loaded.spread("lib/b.rb")
      refute loaded.known_file?("lib/c.rb")
    end
  end

  def test_load_refuses_another_format
    Dir.mktmpdir do |dir|
      path = File.join(dir, "map.json")
      File.write(path, { format: 99, tests: {} }.to_json)

      assert_raises(Minitest::Impact::Error) { Minitest::Impact::Map.load(path) }
    end
  end
end
