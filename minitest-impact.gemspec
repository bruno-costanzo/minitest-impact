# frozen_string_literal: true

require_relative "lib/minitest/impact/version"

Gem::Specification.new do |spec|
  spec.name = "minitest-impact"
  spec.version = Minitest::Impact::VERSION
  spec.authors = ["Bruno Costanzo"]
  spec.summary = "Pick the Minitest tests a change is most likely to break, from a coverage map and, optionally, Jev."
  spec.description = <<~TEXT
    Records which lines each Minitest test file executes, then, given a git diff, selects the test
    files that ran the changed methods, plus the ones Rails conventions point to for views, copy,
    routes and migrations. With a TypeSafe key, Jev re-ranks the selection and covers what the map
    cannot see. Made for coding agents that should run a few tests in their loop and leave the full
    suite to the final gate.
  TEXT
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "exe/*", "eval/*.rb", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["minitest-impact"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
