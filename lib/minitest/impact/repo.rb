# frozen_string_literal: true

require "open3"

module Minitest
  module Impact
    # Reads a git repository either as its working tree (rev nil) or as it was at a commit, so the
    # same selection runs on an agent's uncommitted change and on a commit from history.
    class Repo
      attr_reader :root

      def initialize(root = Dir.pwd)
        @root = File.expand_path(root)
        @cache = {}
      end

      def git(*args, allow_failure: false)
        out, err, status = Open3.capture3("git", "-C", root, *args)
        raise Error, "git #{args.join(" ")} failed: #{err.strip}" unless status.success? || allow_failure

        status.success? ? out : nil
      end

      def head = git("rev-parse", "HEAD").strip

      def commit?(rev) = !git("cat-file", "-e", "#{rev}^{commit}", allow_failure: true).nil?

      def resolve(rev) = git("rev-parse", rev).strip

      def merge_base(a, b) = git("merge-base", a, b, allow_failure: true)&.strip

      # Contents of +path+ at +rev+, or in the working tree when rev is nil. nil when absent.
      def read(path, rev = nil)
        @cache.fetch([path, rev]) do
          @cache[[path, rev]] =
            if rev
              git("show", "#{rev}:#{path}", allow_failure: true)
            else
              full = File.join(root, path)
              File.file?(full) ? File.read(full) : nil
            end
        end
      end

      def files(rev = nil)
        @cache.fetch([:files, rev]) do
          @cache[[:files, rev]] =
            if rev
              git("ls-tree", "-r", "--name-only", rev).split("\n")
            else
              git("ls-files", "--cached", "--others", "--exclude-standard").split("\n").select { |f| File.file?(File.join(root, f)) }
            end
        end
      end

      # Files under +paths+ whose text contains the fixed string +needle+.
      def grep(needle, paths:, rev: nil)
        return [] if needle.to_s.strip.empty?

        args = ["grep", "-l", "-F", "-e", needle]
        args << "--untracked" unless rev
        args << rev if rev
        args += ["--", *paths]
        out = git(*args, allow_failure: true).to_s
        out.split("\n").map { |line| rev ? line.delete_prefix("#{rev}:") : line }
      end

      # Unified diff with no context between +base+ and +head+ (working tree when head is nil).
      # Untracked files are listed as additions too, since an agent's new file is part of its change.
      def diff(base, head = nil)
        range = head ? [base, head] : [base]
        text = git("diff", "--no-color", "--no-ext-diff", "-M", "--unified=0", *range)
        return text if head

        untracked = git("ls-files", "--others", "--exclude-standard").split("\n")
        text + untracked.map { |path| "diff --git a/#{path} b/#{path}\nnew file mode 100644\n--- /dev/null\n+++ b/#{path}\n" }.join
      end
    end
  end
end
