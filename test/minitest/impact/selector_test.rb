# frozen_string_literal: true

require "test_helper"

class SelectorTest < Minitest::Test
  INVOICE = <<~RUBY
    class Invoice
      TAX = 2

      def total
        10 * TAX
      end

      def number
        "N1"
      end

      def unused
        nil
      end
    end
  RUBY

  def setup
    sandbox.write("app/models/invoice.rb", INVOICE)
    sandbox.write("app/views/invoices/show.html.erb", "<%= t(\".title\") %>\n")
    sandbox.write("app/controllers/invoices_controller.rb", "class InvoicesController\nend\n")
    sandbox.write("lib/other.rb", "class Other\nend\n")
    sandbox.write("test/models/invoice_test.rb", "test \"total\" do\nend\n")
    sandbox.write("test/controllers/invoices_controller_test.rb", "test \"show\" do\nend\n")
    sandbox.write("test/other_test.rb", "test \"other\" do\n  Other.new\n  I18n.t(\"shared.ok\")\nend\n")
    sandbox.write("config/locales/es.yml", "es:\n  invoices:\n    show:\n      title: Factura\n  shared:\n    ok: Bien\n")
    sandbox.write("docs/notes.md", "notes\n")
    @base = sandbox.commit("base")
    @map = map_with(@base,
                    "test/models/invoice_test.rb" => { "app/models/invoice.rb" => [5, 9], "test/models/invoice_test.rb" => [1] },
                    "test/controllers/invoices_controller_test.rb" => { "app/models/invoice.rb" => [9], "app/controllers/invoices_controller.rb" => [1],
                                                                          "app/views/invoices/show.html.erb" => [1] },
                    "test/other_test.rb" => { "lib/other.rb" => [1] })
  end

  def select(**options)
    Minitest::Impact::Selector.new(repo: sandbox.repo, map: @map, base: @base, **options).call
  end

  def edit(path, from, to)
    full = File.join(sandbox.root, path)
    File.write(full, File.read(full).sub(from, to))
  end

  def test_a_changed_method_selects_the_tests_that_ran_it
    edit("app/models/invoice.rb", "10 * TAX", "20 * TAX")

    selection = select

    assert_equal ["test/models/invoice_test.rb"], selection.tests
    assert_includes selection.picks.first.reasons, "runs Invoice#total"
    assert_equal :high, selection.confidence
  end

  def test_a_method_found_by_name_after_the_lines_moved
    sandbox.write("app/models/invoice.rb", "# a new comment\n# and another\n#{INVOICE}")
    head = sandbox.commit("move")
    edit("app/models/invoice.rb", "\"N1\"", "\"N2\"")

    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: @map, base: head).call

    assert_equal ["test/controllers/invoices_controller_test.rb", "test/models/invoice_test.rb"], selection.tests.sort
  end

  def test_a_class_body_change_selects_every_test_that_loaded_the_file
    edit("app/models/invoice.rb", "TAX = 2", "TAX = 3")

    selection = select

    assert_equal ["test/controllers/invoices_controller_test.rb", "test/models/invoice_test.rb"], selection.tests.sort
    assert_equal :medium, selection.confidence
  end

  def test_a_method_no_test_runs_falls_back_to_the_file_with_little_weight
    edit("app/models/invoice.rb", "    nil", "    false")

    selection = select

    assert_equal "test/models/invoice_test.rb", selection.tests.first
    assert(selection.resolutions.any? { |r| r.note.to_s.include?("no test runs Invoice#unused") })
  end

  def test_a_changed_test_selects_itself
    sandbox.write("test/other_test.rb", "test \"other again\" do\nend\n")

    assert_equal ["test/other_test.rb"], select.tests
  end

  def test_gem_changes_need_the_whole_suite
    sandbox.write("Gemfile.lock", "GEM\n")

    selection = select

    assert selection.whole_suite
    assert_equal :low, selection.confidence
  end

  def test_a_new_file_is_traced_by_the_tests_that_mention_its_constant
    sandbox.write("lib/other/report.rb", "class Other::Report\nend\n")
    sandbox.write("test/other_test.rb", "test \"other\" do\n  Other::Report.new\nend\n")
    sandbox.commit("test first")
    head_base = sandbox.git("rev-parse", "HEAD").strip
    sandbox.write("lib/other/report.rb", "class Other::Report\n  def x = 1\nend\n")
    sandbox.write("lib/brand_new.rb", "class BrandNew\nend\n")

    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: @map, base: head_base).call

    assert_includes selection.tests, "test/other_test.rb"
    assert_equal "BrandNew", selection.resolutions.find { |r| r.path == "lib/brand_new.rb" }.note
    assert_equal :low, selection.confidence
  end

  def test_docs_no_test_reads_select_nothing
    sandbox.write("docs/notes.md", "more notes\n")

    selection = select

    assert_empty selection.tests
    assert_equal :high, selection.confidence
  end

  def test_a_changed_locale_key_selects_tests_that_assert_it_and_views_that_render_it
    edit("config/locales/es.yml", "ok: Bien", "ok: Muy bien")
    edit("config/locales/es.yml", "title: Factura", "title: Recibo")

    selection = select

    assert_equal ["test/controllers/invoices_controller_test.rb", "test/other_test.rb"], selection.tests.sort
  end

  def test_a_view_the_map_saw_rendered_selects_its_tests
    edit("app/views/invoices/show.html.erb", "title", "heading")

    assert_equal ["test/controllers/invoices_controller_test.rb"], select.tests
  end

  def test_excluded_paths_are_ignored
    sandbox.write("test/other_test.rb", "changed\n")

    assert_empty select(exclude: ->(path) { path.start_with?("test/") }).tests
  end

  def test_a_map_from_another_repository_warns_and_matches_by_file
    @map = map_with("0" * 40, @map.tests.transform_values(&:files))
    edit("app/models/invoice.rb", "10 * TAX", "20 * TAX")

    selection = select

    assert_match(/does not have/, selection.warnings.first)
    assert_equal 2, selection.tests.size
  end
end
