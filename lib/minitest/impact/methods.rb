# frozen_string_literal: true

require "prism"

module Minitest
  module Impact
    # The methods of a Ruby file and the lines each spans, named with their namespace
    # ("Billing::Invoice#total", "Billing::Invoice.build"). Naming a method lets a changed line in
    # one version of a file find the same method in the version the map was recorded against,
    # even after the lines around it moved.
    class Methods
      Definition = Struct.new(:name, :first_line, :last_line) do
        def lines = (first_line..last_line)
        # The body, without the `def` and `end` lines: those run when the file loads, not when a
        # test calls the method. A one-line method runs on its only line.
        def body = last_line - first_line >= 2 ? ((first_line + 1)..(last_line - 1)) : lines
      end

      def self.of(source)
        return new([]) if source.nil?

        result = Prism.parse(source)
        definitions = []
        walk(result.value, [], definitions)
        new(definitions)
      end

      def self.walk(node, namespace, out)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          inner = namespace + [node.constant_path.slice]
          node.body && walk(node.body, inner, out)
          return
        when Prism::SingletonClassNode
          node.body && walk(node.body, namespace + ["<<self"], out)
          return
        when Prism::DefNode
          separator = node.receiver ? "." : "#"
          separator = "." if namespace.last == "<<self"
          owner = namespace.reject { |part| part == "<<self" }.join("::")
          out << Definition.new("#{owner}#{separator}#{node.name}", node.location.start_line, node.location.end_line)
        end
        node.compact_child_nodes.each { |child| walk(child, namespace, out) }
      end
      private_class_method :walk

      attr_reader :definitions

      def initialize(definitions)
        @definitions = definitions
      end

      # The innermost method containing +line+, or nil for class-body code.
      def enclosing(line)
        definitions.select { |definition| definition.lines.cover?(line) }.min_by { |definition| definition.lines.size }
      end

      def named(name) = definitions.find { |definition| definition.name == name }
    end
  end
end
