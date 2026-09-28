# frozen_string_literal: true

require "psych"

module Minitest
  module Impact
    # The full i18n keys ("sessions.new.title", without the locale) whose lines a change touched.
    module LocaleKeys
      def self.at(source, lines)
        return [] if source.nil? || lines.empty?

        wanted = lines.to_set
        keys = []
        document = Psych.parse(source)
        walk(document&.root, [], keys, wanted)
        keys.uniq
      rescue Psych::SyntaxError
        []
      end

      def self.walk(node, path, keys, wanted)
        return unless node.is_a?(Psych::Nodes::Mapping)

        node.children.each_slice(2) do |key, value|
          next unless key.is_a?(Psych::Nodes::Scalar)

          full = path + [key.value]
          if value.is_a?(Psych::Nodes::Mapping)
            walk(value, full, keys, wanted)
          else
            span = (key.start_line + 1)..(value.end_line + 1)
            keys << full.drop(1).join(".") if span.any? { |line| wanted.include?(line) } && full.size > 1
          end
        end
      end
      private_class_method :walk
    end
  end
end
