# frozen_string_literal: true

require "test_helper"

class LocaleKeysTest < Minitest::Test
  YAML_SOURCE = <<~YAML
    es:
      sessions:
        new:
          title: Entrar
          submit: Continuar
      shared:
        ok: Bien
  YAML

  def test_returns_full_keys_without_the_locale_for_changed_lines
    assert_equal ["sessions.new.submit"], Minitest::Impact::LocaleKeys.at(YAML_SOURCE, [5])
    assert_equal ["sessions.new.title", "shared.ok"], Minitest::Impact::LocaleKeys.at(YAML_SOURCE, [4, 7])
  end

  def test_empty_for_no_lines_or_broken_yaml
    assert_empty Minitest::Impact::LocaleKeys.at(YAML_SOURCE, [])
    assert_empty Minitest::Impact::LocaleKeys.at("es: [", [1])
  end
end
