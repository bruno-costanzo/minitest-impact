# frozen_string_literal: true

require "test_helper"

class DiffTest < Minitest::Test
  DIFF = <<~DIFF
    diff --git a/lib/a.rb b/lib/a.rb
    index 1..2 100644
    --- a/lib/a.rb
    +++ b/lib/a.rb
    @@ -3,2 +3,2 @@ class A
    -  old
    -  older
    +  new
    +  newer
    @@ -10,0 +11,1 @@ class A
    +  inserted
    diff --git a/lib/new.rb b/lib/new.rb
    new file mode 100644
    --- /dev/null
    +++ b/lib/new.rb
    @@ -0,0 +1,2 @@
    +class New
    +end
    diff --git a/lib/gone.rb b/lib/gone.rb
    deleted file mode 100644
    --- a/lib/gone.rb
    +++ /dev/null
    @@ -1 +0,0 @@
    -class Gone; end
    diff --git a/lib/old_name.rb b/lib/new_name.rb
    similarity index 100%
    rename from lib/old_name.rb
    rename to lib/new_name.rb
  DIFF

  def test_parses_statuses_and_old_side_lines
    modified, added, deleted, renamed = Minitest::Impact::Diff.parse(DIFF)

    assert_equal :modified, modified.status
    assert_equal [3, 4, 10], modified.old_lines
    assert_equal [3, 4, 11], modified.new_lines
    assert_includes modified.added_text, "inserted"
    assert_includes modified.removed_text, "older"

    assert added.added?
    assert_nil added.old_path

    assert deleted.deleted?
    assert_equal [1], deleted.old_lines

    assert_equal :renamed, renamed.status
    assert_equal "lib/old_name.rb", renamed.old_path
    assert_equal "lib/new_name.rb", renamed.path
  end
end
