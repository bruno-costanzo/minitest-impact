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

  def reached_through_code(files, test:, runs:)
    files.each { |path, text| sandbox.write(path, text) }
    sandbox.write(test, "test \"it\" do\nend\n")
    base = sandbox.commit("reached through code")
    map = map_with(base, test => { runs => [1] })
    [base, map]
  end

  def test_a_file_the_code_reads_by_path_selects_the_tests_that_run_that_code
    base, map = reached_through_code({ "app/prompts/memory/instructions.txt.erb" => "Be brief.\n",
                                       "app/services/memory.rb" => "class Memory\n  PATH = \"app/prompts/memory/instructions.txt.erb\"\nend\n" },
                                     test: "test/services/memory_test.rb", runs: "app/services/memory.rb")
    sandbox.write("app/prompts/memory/instructions.txt.erb", "Be very brief.\n")

    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: map, base: base).call

    assert_equal ["test/services/memory_test.rb"], selection.tests
    assert_includes selection.picks.first.reasons, "reads app/prompts/memory/instructions.txt.erb through app/services/memory.rb"
    assert_equal :medium, selection.confidence
  end

  def test_a_text_file_the_code_reads_is_not_quiet
    base, map = reached_through_code({ "app/prompts/judge.txt" => "Judge.\n",
                                       "app/services/judge.rb" => "class Judge\n  PATH = Rails.root.join(\"app/prompts/judge.txt\")\nend\n" },
                                     test: "test/services/judge_test.rb", runs: "app/services/judge.rb")
    sandbox.write("app/prompts/judge.txt", "Judge harder.\n")

    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: map, base: base).call

    assert_equal ["test/services/judge_test.rb"], selection.tests
  end

  def test_a_file_the_code_names_by_its_file_name_selects_the_tests_that_run_that_code
    base, map = reached_through_code({ "lib/support/preview.js" => "1\n",
                                       "app/services/support.rb" => "class Support\n  FILES = { \"preview.js\" => \"public/preview.js\" }\nend\n" },
                                     test: "test/services/support_test.rb", runs: "app/services/support.rb")
    sandbox.write("lib/support/preview.js", "2\n")

    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: map, base: base).call

    assert_equal ["test/services/support_test.rb"], selection.tests
  end

  def test_a_file_in_a_folder_the_code_reads_selects_the_tests_that_run_that_code
    base, map = reached_through_code({ "app/prompts/agent/instructions.txt.erb" => "Go.\n",
                                       "app/services/hand_back.rb" => "class HandBack\n  PROMPTS = \"app/prompts/agent\"\nend\n" },
                                     test: "test/services/hand_back_test.rb", runs: "app/services/hand_back.rb")
    sandbox.write("app/prompts/agent/instructions.txt.erb", "Stop.\n")

    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: map, base: base).call

    assert_equal ["test/services/hand_back_test.rb"], selection.tests
    assert_includes selection.picks.first.reasons, "reads files under app/prompts/agent through app/services/hand_back.rb"
  end

  def test_a_config_key_selects_the_tests_that_run_the_code_reading_it
    base, map = reached_through_code({ "config/app.yml" => "shared:\n  technical: opus\n",
                                       "app/services/sandbox.rb" => "class Sandbox\n  def poll = settings[:sandbox_ready_poll_seconds]\nend\n",
                                       "app/services/technical.rb" => "class Technical\n  def technical = 1\nend\n" },
                                     test: "test/services/sandbox_test.rb", runs: "app/services/sandbox.rb")
    sandbox.write("config/app.yml", "shared:\n  technical: sonnet\n  sandbox_ready_poll_seconds: 0.5\n")

    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: map, base: base).call

    assert_equal ["test/services/sandbox_test.rb"], selection.tests
    assert_includes selection.picks.first.reasons, "reads sandbox_ready_poll_seconds from config/app.yml through app/services/sandbox.rb"
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
