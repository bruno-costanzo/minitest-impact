# frozen_string_literal: true

require "test_helper"

class RulesTest < Minitest::Test
  Rules = Minitest::Impact::Rules

  def test_conventional_tests_follow_the_rails_layout
    assert_equal ["test/models/billing/invoice_test.rb"], Rules.conventional_tests("app/models/billing/invoice.rb")
    assert_equal ["test/lib/tools/x_test.rb", "test/tools/x_test.rb"], Rules.conventional_tests("lib/tools/x.rb")
    assert_equal ["test/controllers/sessions_controller_test.rb"], Rules.conventional_tests("app/views/sessions/new.html.erb")
    assert_empty Rules.conventional_tests("config/piou.yml")
  end

  def test_constants_follow_zeitwerk
    assert_equal "Billing::Invoice", Rules.constant_for("app/models/billing/invoice.rb")
    assert_equal "Trackable", Rules.constant_for("app/models/concerns/trackable.rb")
    assert_nil Rules.constant_for("config/routes.rb")
  end

  def test_singularize_covers_table_names
    assert_equal %w[user category address status box], %w[users categories addresses status boxes].map { |w| Rules.singularize(w) }
  end

  def test_tables_and_controllers_from_diffs
    assert_equal %w[invoices users], Rules.tables_in("create_table :invoices do |t|\nadd_column :users, :name, :string")
    assert_equal "invoices", Rules.schema_table_at(%(create_table "invoices" do |t|\n  t.string "number"\n), 2)
    assert_equal ["app/controllers/invoices_controller.rb", "app/controllers/admin/users_controller.rb"],
                 Rules.controllers_in_routes(%(resources :invoices\nget "x", to: "admin/users#index"))
  end

  def test_lazy_keys_find_their_views
    files = %w[app/views/sessions/new.html.erb app/views/sessions/_form.html.erb app/views/other/new.html.erb]

    assert_equal ["app/views/sessions/new.html.erb"], Rules.views_for_key("sessions.new.title", files)
    assert_equal ["app/views/sessions/_form.html.erb"], Rules.views_for_key("sessions.form.submit", files)
    assert_empty Rules.views_for_key("title", files)
  end

  def test_file_classes
    assert Rules.whole_suite?("Gemfile.lock")
    assert Rules.quiet?("docs/01-vision.md")
    assert Rules.test_file?("test/models/user_test.rb")
    refute Rules.test_file?("test/test_helper.rb")
    assert_equal "chat-input", Rules.stimulus_identifier("chat_input")
  end
end
