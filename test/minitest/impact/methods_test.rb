# frozen_string_literal: true

require "test_helper"

class MethodsTest < Minitest::Test
  SOURCE = <<~RUBY
    module Billing
      class Invoice
        TAX = 0.2

        def total
          amount * (1 + TAX)
        end

        def self.build = new

        class << self
          def import(rows)
            rows.map { build }
          end
        end
      end
    end
  RUBY

  def test_names_methods_with_their_namespace
    methods = Minitest::Impact::Methods.of(SOURCE)

    assert_equal ["Billing::Invoice#total", "Billing::Invoice.build", "Billing::Invoice.import"], methods.definitions.map(&:name)
  end

  def test_finds_the_method_around_a_line_and_nil_in_a_class_body
    methods = Minitest::Impact::Methods.of(SOURCE)

    assert_equal "Billing::Invoice#total", methods.enclosing(6).name
    assert_nil methods.enclosing(3)
    assert_equal 6..6, methods.named("Billing::Invoice#total").body
    assert_equal 9..9, methods.named("Billing::Invoice.build").body
  end

  def test_nil_source_has_no_methods
    assert_empty Minitest::Impact::Methods.of(nil).definitions
  end
end
