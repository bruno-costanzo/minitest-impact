# frozen_string_literal: true

require "set"

module Minitest
  module Impact
    # One test file in a selection, with every reason it was picked.
    Pick = Struct.new(:test, :score, :reasons, :seconds, keyword_init: true) do
      def to_h = { "test" => test, "score" => score.round(3), "reasons" => reasons, "seconds" => seconds }
    end

    # What a selection decided about one changed file.
    Resolution = Struct.new(:path, :how, :note, keyword_init: true)

    Selection = Struct.new(:picks, :whole_suite, :resolutions, :jev, :warnings, keyword_init: true) do
      def tests = picks.map(&:test)

      def unresolved = resolutions.select { |resolution| resolution.how == :unresolved }

      # high: every changed file was traced exactly (a changed test, a changed method the map saw
      # run, or a file no test reads). medium: some file was traced by file or by convention. low:
      # some file could not be traced, or the change needs the whole suite.
      def confidence
        return :low if whole_suite || resolutions.any? { |r| r.how == :unresolved }
        return :medium if resolutions.any? { |r| %i[file convention].include?(r.how) }

        :high
      end

      def to_h
        {
          "confidence" => confidence.to_s,
          "whole_suite" => whole_suite,
          "tests" => picks.map(&:to_h),
          "files" => resolutions.map { |r| { "path" => r.path, "how" => r.how.to_s, "note" => r.note } },
          "jev" => jev,
          "warnings" => warnings
        }
      end
    end

    # Picks the test files a change is most likely to break or that verify it. Everything here is
    # deterministic: the coverage map, method names, and the layout rules in Rules. A Jev ranker,
    # when one is given, then re-ranks and extends the result (see Jev::Ranker).
    class Selector
      # granularity: :method (default) traces changed lines to methods; :file selects every test
      # that loaded a changed file, as Crystalball and Ekstazi do. Kept to measure one against the other.
      def initialize(repo:, map:, base:, head: nil, intent: nil, ranker: nil, exclude: nil, granularity: :method)
        @repo = repo
        @map = map
        @base = base
        @head = head
        @intent = intent
        @ranker = ranker
        @exclude = exclude
        @granularity = granularity
        @hits = Hash.new { |hash, key| hash[key] = [] }
        @resolutions = []
        @warnings = []
        @whole_suite = false
      end

      def changes
        @changes ||= Diff.parse(@repo.diff(@base, @head)).reject { |change| @exclude&.call(change.path) }
      end

      def call
        warn_if_stale
        changes.each { |change| resolve(change) }
        picks = rank
        jev = nil
        if @ranker && needs_ranker?(picks)
          picks, jev = @ranker.call(picks: picks, changes: changes, intent: @intent, repo: @repo, map: @map, head: @head)
          @whole_suite ||= jev&.dig("whole_suite") == true
        end
        Selection.new(picks: picks, whole_suite: @whole_suite, resolutions: @resolutions, jev: jev, warnings: @warnings)
      end

      private

      def needs_ranker?(picks)
        @resolutions.any? { |r| %i[unresolved file convention].include?(r.how) } || picks.size > Jev::Questions::MAX_CANDIDATES
      end

      def warn_if_stale
        return if @map.commit.nil? || @repo.commit?(@map.commit)

        @warnings << "the map was recorded at #{@map.commit}, which this repository does not have; matching by file only"
      end

      def hit(test, kind, reason)
        return unless @map.tests.key?(test) || head_has?(test)

        @hits[test] << [Rules::WEIGHT.fetch(kind), reason]
      end

      def head_has?(path) = head_files.include?(path)

      def head_files = @head_files ||= @repo.files(@head).to_set

      def resolved(change, how, note = nil)
        @resolutions << Resolution.new(path: change.path, how: how, note: note)
      end

      # Several independent reasons make a test more likely, never less: 1 - Π(1 - w).
      def rank
        @hits.select { |test, _| head_has?(test) }.map do |test, reasons|
          score = 1 - reasons.map(&:first).reduce(1.0) { |acc, weight| acc * (1 - weight) }
          Pick.new(test: test, score: score, reasons: reasons.map(&:last).uniq, seconds: @map.seconds(test))
        end.sort_by { |pick| [-pick.score, pick.seconds || Float::INFINITY, pick.test] }
      end

      def resolve(change)
        path = change.path
        return resolve_whole_suite(change) if Rules.whole_suite?(path)
        return resolve_base_class(change) if Rules::BASE_CLASSES.key?(path)
        return resolve_test(change) if Rules.test_file?(path)

        case path
        when Rules::FIXTURE then resolve_fixture(change, Regexp.last_match(1))
        when Rules::LOCALE then resolve_locale(change)
        when Rules::MIGRATION then resolve_migration(change)
        when Rules::STIMULUS then resolve_stimulus(change, Regexp.last_match(1))
        when Rules::ROUTES then resolve_routes(change)
        else resolve_file(change)
        end
      end

      def resolve_whole_suite(change)
        @whole_suite = true
        resolved(change, :whole_suite, "every test depends on it")
      end

      def resolve_base_class(change)
        dir = Rules::BASE_CLASSES.fetch(change.path)
        tests = (@map.test_files + head_files.to_a).uniq.select { |test| test.start_with?(dir) && Rules.test_file?(test) }
        tests.each { |test| hit(test, :file, "inherits #{change.path}") }
        resolved(change, :file, "every test under #{dir}")
      end

      def resolve_test(change)
        return resolved(change, :quiet, "deleted test") if change.deleted?

        hit(change.path, :changed_test, "the change edits this test")
        resolved(change, :exact)
      end

      def resolve_fixture(change, name)
        found = tests_mentioning("#{name}(:")
        found.each { |test| hit(test, :reads_path, "uses the #{name} fixtures") }
        model = "app/models/#{Rules.singularize(name.split("/").last)}.rb"
        via = map_tests(model, :via_file, "tests #{model}, whose fixtures changed")
        resolved(change, found.any? || via ? :convention : :unresolved, "fixtures #{name}")
      end

      def resolve_locale(change)
        keys = LocaleKeys.at(@repo.read(change.path, @head), change.new_lines) |
               LocaleKeys.at(@repo.read(change.old_path || change.path, @base), change.deleted? || change.status == :modified ? change.old_lines : [])
        found = false
        keys.each do |key|
          tests_mentioning(key).each do |test|
            hit(test, :asserts_key, "uses the key #{key}")
            found = true
          end
          @repo.grep(key, paths: %w[app lib], rev: @head).each do |file|
            found = true if map_tests(file, :via_file, "renders #{key} through #{file}")
          end
          Rules.views_for_key(key, head_files.to_a).each do |view|
            found = true if resolve_view_like(view, "renders #{key} (lazy lookup) in #{view}")
          end
        end
        resolved(change, found ? :convention : :unresolved, keys.empty? ? "no key found in the change" : "keys: #{keys.first(5).join(", ")}")
      end

      def resolve_migration(change)
        source = @repo.read(change.path, @head) || ""
        tables = Rules.tables_in(change.text)
        if change.path.end_with?("schema.rb")
          tables |= change.new_lines.filter_map { |line| Rules.schema_table_at(source, line) }
        end
        found = tables.any? do |table|
          model = "app/models/#{Rules.singularize(table)}.rb"
          by_map = map_tests(model, :via_file, "tests #{model}, whose table #{table} changed")
          by_name = conventional(model)
          by_map || by_name
        end
        resolved(change, found ? :convention : :unresolved, tables.empty? ? "no table found" : "tables: #{tables.join(", ")}")
      end

      def resolve_stimulus(change, name)
        identifier = Rules.stimulus_identifier(name)
        views = @repo.grep(identifier, paths: %w[app/views app/components app/helpers], rev: @head)
        found = views.any? { |view| resolve_view_like(view, "uses the #{identifier} Stimulus controller through #{view}") }
        resolved(change, found ? :convention : :unresolved, "Stimulus #{identifier}")
      end

      def resolve_routes(change)
        found = Rules.controllers_in_routes(change.text).any? do |controller|
          map_tests(controller, :via_file, "reaches #{controller}, whose routes changed") | conventional(controller)
        end
        resolved(change, found ? :convention : :unresolved, "routes")
      end

      def resolve_file(change)
        reads = tests_mentioning(change.path)
        reads.each { |test| hit(test, :reads_path, "reads #{change.path}") }
        lookup = change.old_path || change.path

        # A file the change adds cannot be in a map recorded before it; if the map knows it anyway
        # (a map newer than the change, as when replaying history), using it would be hindsight.
        if @map.known_file?(lookup) && !change.added?
          resolve_mapped(change, lookup)
        elsif change.path.start_with?("app/views/")
          found = resolve_view_like(change.path, nil)
          resolved(change, found || reads.any? ? :convention : :unresolved)
        elsif Rules.ruby?(change.path) && Rules.constant_for(change.path)
          resolve_by_name(change, reads.any?)
        elsif reads.any?
          resolved(change, :exact, "tests read it by path")
        elsif Rules.quiet?(change.path)
          resolved(change, :quiet, "no test reads it")
        else
          resolved(change, :unresolved, "not in the map and no rule matches")
        end
      end

      # A file the map saw run. Changed lines inside methods select the tests that ran those
      # methods; lines outside any method (class bodies, macros, constants) select every test that
      # loaded the file.
      def resolve_mapped(change, lookup)
        if @granularity == :file && !change.deleted? && Rules.ruby?(lookup)
          map_tests(lookup, :file, "loads #{lookup}")
          conventional(lookup)
          return resolved(change, :file)
        end
        if change.deleted? || !Rules.ruby?(lookup)
          map_tests(lookup, change.deleted? ? :deleted_file : :view, change.deleted? ? "loaded #{lookup}, now deleted" : "rendered #{lookup}")
          conventional(lookup)
          return resolved(change, change.deleted? ? :exact : :file)
        end

        old_methods = Methods.of(@repo.read(lookup, @base))
        map_version = map_source(lookup)
        map_methods = map_version ? Methods.of(map_version) : nil
        outside = false
        untested = []
        names = change.old_lines.map { |line| old_methods.enclosing(line)&.name }
        outside = true if names.include?(nil) || change.old_lines.empty?
        names.compact.uniq.each do |name|
          definition = map_methods&.named(name)
          next outside = true unless definition

          body = definition.body.to_set
          tests = @map.tests_for(lookup).select { |_test, lines| lines.any? { |line| body.include?(line) } }
          untested << name if tests.empty?
          tests.each_key { |test| hit(test, :method, "runs #{name}") }
        end
        conventional(lookup)
        if outside
          map_tests(lookup, :file, "loads #{lookup}")
          resolved(change, :file, "changed outside a method the map knows")
        elsif untested.any?
          map_tests(lookup, :untested_method, "loads #{lookup}; no test runs #{untested.join(", ")}")
          resolved(change, :file, "no test runs #{untested.join(", ")}")
        else
          resolved(change, :exact)
        end
      end

      def resolve_by_name(change, found)
        constant = Rules.constant_for(change.path)
        found |= conventional(change.path)
        tests_mentioning(constant).each do |test|
          hit(test, :mentions_constant, "mentions #{constant}")
          found = true
        end
        @repo.grep(constant, paths: %w[app lib], rev: @head).each do |file|
          next if file == change.path

          found = true if map_tests(file, :via_file, "reaches #{constant} through #{file}")
        end
        resolved(change, found ? :convention : :unresolved, constant)
      end

      def resolve_view_like(view, reason)
        return map_tests(view, :view, reason || "renders #{view}") if @map.known_file?(view)

        match = Rules::VIEW.match(view)
        return false unless match

        found = conventional(view)
        dir = match[1]
        controller = dir.end_with?("_mailer") ? "app/mailers/#{dir}.rb" : "app/controllers/#{dir}_controller.rb"
        found |= map_tests(controller, :via_file, reason || "renders #{view} through #{controller}")
        partial = "#{dir}/#{match[3]}"
        if match[2] == "_"
          @repo.grep(partial, paths: %w[app], rev: @head).each do |file|
            found = true if map_tests(file, :via_file, reason || "renders the partial #{partial} through #{file}")
          end
        end
        found
      end

      # Selects every test the map says loaded +file+; true when there was any. A file every test
      # loads (a base class) tells little, so its weight shrinks with how widely it is loaded.
      def map_tests(file, kind, reason)
        tests = @map.tests_for(file)
        return false if tests.empty?

        weight = Rules::WEIGHT.fetch(kind) * (1 - (0.5 * @map.spread(file)))
        tests.each_key { |test| @hits[test] << [weight, reason] }
        true
      end

      def conventional(path)
        found = false
        Rules.conventional_tests(path).each do |test|
          next unless @map.tests.key?(test) || head_has?(test)

          hit(test, :conventional_test, "is the test for #{path}")
          found = true
        end
        found
      end

      def tests_mentioning(needle)
        @repo.grep(needle, paths: [Rules::TEST_ROOT], rev: @head).select { |file| Rules.test_file?(file) }
      end

      def map_source(path)
        return nil if @map.commit.nil? || !@repo.commit?(@map.commit)

        @repo.read(path, @map.commit)
      end
    end
  end
end
