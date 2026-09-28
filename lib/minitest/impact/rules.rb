# frozen_string_literal: true

module Minitest
  module Impact
    # Every rule that is a fact about Rails and Minitest layouts, in one place, so a reader can
    # check them without reading the selector. Nothing here asks a model.
    module Rules
      TEST_ROOT = "test/"
      TEST_FILE = %r{\Atest/.*_test\.rb\z}
      FIXTURE = %r{\Atest/fixtures/(.+)\.yml\z}

      # A change here can break any test, so the full suite is the only honest selection.
      WHOLE_SUITE = %w[
        Gemfile Gemfile.lock gems.rb gems.locked .ruby-version .tool-versions mise.toml
        test/test_helper.rb config/application.rb config/boot.rb config/environment.rb
        config/environments/test.rb config/database.yml
      ].freeze

      # A change to a base test class reaches every test under a directory.
      BASE_CLASSES = {
        "test/application_system_test_case.rb" => "test/system/"
      }.freeze

      # Files no test runs. Selected only when a test reads the file by path.
      QUIET = [%r{\A(?:docs|tmp|log)/}, /\.md\z/, %r{\A\.github/}, /\ALICENSE/, /\.txt\z/, %r{\A\.claude/}, /\A\.gitignore\z/].freeze

      ROUTES = "config/routes.rb"
      LOCALE = %r{\Aconfig/locales/.+\.ya?ml\z}
      MIGRATION = %r{\Adb/(migrate/.+\.rb|schema\.rb|.+_schema\.rb)\z}
      VIEW = %r{\Aapp/views/(.+?)/(_?)([^/]+?)\.[^/]+\z}
      STIMULUS = %r{\Aapp/javascript/controllers/(.+)_controller\.[jt]s\z}
      AUTOLOADED = %r{\A(?:app/[^/]+|lib)/(.+)\.rb\z}

      # Weights: how sure a reason is that a test file exercises the change (0..1).
      WEIGHT = {
        changed_test: 1.0,
        method: 1.0,
        deleted_file: 0.95,
        conventional_test: 0.9,
        reads_path: 0.85,
        asserts_key: 0.85,
        view: 0.85,
        mentions_constant: 0.7,
        file: 0.7,
        via_file: 0.6,
        untested_method: 0.3
      }.freeze

      module_function

      def test_file?(path) = TEST_FILE.match?(path)
      def whole_suite?(path) = WHOLE_SUITE.include?(path)
      def quiet?(path) = QUIET.any? { |pattern| pattern.match?(path) }
      def ruby?(path) = path.end_with?(".rb")

      # app/models/billing/invoice.rb => test/models/billing/invoice_test.rb
      # lib/tasks/x.rb => test/lib/tasks/x_test.rb, test/tasks/x_test.rb
      def conventional_tests(path)
        case path
        when %r{\Aapp/(.+)\.rb\z} then ["test/#{Regexp.last_match(1)}_test.rb"]
        when %r{\Alib/(.+)\.rb\z} then ["test/lib/#{Regexp.last_match(1)}_test.rb", "test/#{Regexp.last_match(1)}_test.rb"]
        when VIEW
          ["test/controllers/#{Regexp.last_match(1)}_controller_test.rb"]
        else []
        end
      end

      # Zeitwerk's naming: app/models/billing/invoice.rb => Billing::Invoice
      def constant_for(path)
        match = AUTOLOADED.match(path)
        return unless match

        rel = match[1].delete_prefix("concerns/")
        rel.split("/").map { |part| camelize(part) }.join("::")
      end

      def camelize(word) = word.split("_").map(&:capitalize).join

      def singularize(word)
        case word
        when /ies\z/ then word.sub(/ies\z/, "y")
        when /(ss|us)\z/ then word
        when /(s|x|z|ch|sh)es\z/ then word.sub(/es\z/, "")
        when /s\z/ then word.chomp("s")
        else word
        end
      end

      # Tables a migration or schema diff touches.
      def tables_in(text)
        text.scan(/(?:create_table|drop_table|add_column|remove_column|change_column|rename_column|add_index|remove_index|add_reference|remove_reference|change_table|add_foreign_key|change_column_default|change_column_null)\s*\(?\s*[:"'](\w+)/).flatten.uniq
      end

      # The create_table block of schema.rb that holds +line+.
      def schema_table_at(source, line)
        source.lines.first(line).reverse_each do |text|
          return Regexp.last_match(1) if text =~ /create_table\s+"(\w+)"/
        end
        nil
      end

      # Controllers a routes diff names.
      def controllers_in_routes(text)
        names = text.scan(/\bresources?\s+:(\w+)/).flatten.map { |name| name }
        names += text.scan(/to:\s*["']([\w\/]+)#/).flatten
        names += text.scan(/controller:\s*[:"']([\w\/]+)/).flatten
        names.uniq.map { |name| "app/controllers/#{name}_controller.rb" }
      end

      # Candidate view files for a lazy key such as "sessions.new.title".
      def views_for_key(key, files)
        parts = key.split(".")
        return [] if parts.size < 2

        dir = parts[0..-3].join("/")
        template = parts[-2]
        files.select do |file|
          file.start_with?("app/views/#{dir}/") &&
            File.basename(file).split(".").first.delete_prefix("_") == template &&
            File.dirname(file) == "app/views/#{dir}"
        end
      end

      def stimulus_identifier(name) = name.tr("_", "-").gsub("/", "--")
    end
  end
end
