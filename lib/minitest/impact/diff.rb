# frozen_string_literal: true

module Minitest
  module Impact
    # One file in a change. Line numbers are on the old side of the diff, because the coverage
    # map was recorded against old code; an insertion is placed on the line it follows.
    ChangedFile = Struct.new(:path, :old_path, :status, :old_lines, :new_lines, :added_text, :removed_text, keyword_init: true) do
      def added? = status == :added
      def deleted? = status == :deleted
      def text = [removed_text, added_text].join("\n")
    end

    module Diff
      HUNK = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

      # Parses `git diff --unified=0` output.
      def self.parse(text)
        files = []
        current = nil
        text.each_line do |line|
          line = line.chomp
          case line
          when /\Adiff --git a\/(.+) b\/(.+)\z/
            current = ChangedFile.new(path: Regexp.last_match(2), old_path: Regexp.last_match(1), status: :modified,
                                      old_lines: [], new_lines: [], added_text: +"", removed_text: +"")
            files << current
          when /\Anew file mode/ then current.status = :added
          when /\Adeleted file mode/ then current.status = :deleted
          when /\Arename from (.+)\z/ then current.old_path = Regexp.last_match(1)
          when /\Arename to (.+)\z/ then current.status = :renamed if current.status == :modified
          when HUNK
            start = Regexp.last_match(1).to_i
            count = (Regexp.last_match(2) || "1").to_i
            current.old_lines.concat(count.zero? ? [[start, 1].max] : (start...(start + count)).to_a)
            new_start = Regexp.last_match(3).to_i
            new_count = (Regexp.last_match(4) || "1").to_i
            current.new_lines.concat((new_start...(new_start + new_count)).to_a)
          when /\A\+\+\+ |\A--- / then next
          when /\A\+(.*)\z/ then current&.added_text&.<<(Regexp.last_match(1) + "\n")
          when /\A-(.*)\z/ then current&.removed_text&.<<(Regexp.last_match(1) + "\n")
          end
        end
        files.each { |file| file.old_path = nil if file.status == :added }
      end
    end
  end
end
