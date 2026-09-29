# minitest-impact

Pick the Minitest test files a change is most likely to break, or that were written to verify it,
so a coding agent runs a handful of tests inside its loop instead of the whole suite. The full
suite stays the final gate: this gem decides what to run *while working*, never what is allowed
to ship.

```console
$ minitest-impact select --since main
Confidence: medium
  exact        app/models/invoice.rb
  convention   config/locales/es.yml  (keys: invoices.show.title)
4 test files, most likely first:
  1.00  test/models/invoice_test.rb  - runs Invoice#total; is the test for app/models/invoice.rb
  0.95  test/controllers/invoices_controller_test.rb  - uses the key invoices.show.title
  ...
```

It works in three layers; the third is optional:

1. **A coverage map, exact and free.** One recording run of your suite notes which project lines
   every test file executed (Ruby's `Coverage`, with `eval: true` so ERB views count too). Given a
   diff, a changed line is traced to the method around it, the method is found by name in the
   recorded version of the file (so moved lines still match), and the tests that ran that method
   are selected. A change outside any method (a constant, a `validates`, a `has_many`) selects
   every test that loaded the file, weighted down when the file is loaded by nearly everything.
2. **Rules for what the map cannot see**, all in `lib/minitest/impact/rules.rb`: new files (the
   conventional test path, and tests that mention the new constant), locale keys (tests that use
   the key, views that render it), routes (their controllers), migrations and `schema.rb` (the
   models of the changed tables), fixtures, Stimulus controllers (the views that use them), files a
   test reads by path, and files that need the whole suite (`Gemfile.lock`, `test_helper.rb`, boot
   configuration).
3. **Jev, optionally**, when the map and the rules are not enough: some file could not be traced,
   or the selection is too large to run in a loop. See [Jev](#jev) below.

The output is an ordered list of test files, each with its reasons, and an overall confidence:

- **high**: every changed file was traced exactly: a changed test, a changed method the map saw
  run, or a file no test reads.
- **medium**: some file was traced by the whole file or by convention.
- **low**: some file could not be traced, or the change needs the whole suite. Run the suite.

## Install

```ruby
# Gemfile
group :development, :test do
  gem "minitest-impact"
end
```

Ruby 3.3 or newer (it uses the Prism parser from the standard library). No runtime dependencies.

## Record the map

```console
$ minitest-impact record -- bin/rails test
$ minitest-impact record -- sh -c 'bin/rails test; bin/rails test:system'
```

`record` runs the command with `RUBYOPT` loading a small recorder before your app boots, so
nothing changes in your test helper. Each test process (Rails' forked parallel workers included)
appends one JSON line per test to its own file; when the command ends they are merged into
`tmp/minitest-impact/map.json` (`--map PATH` to change it), stamped with the commit it describes.

- **Turn SimpleCov off while recording** (`SimpleCov.start unless ENV["MINITEST_IMPACT_RECORD"]`,
  or your app's own switch). Ruby allows one coverage setup per process.
- Recording is 2 to 3 times slower than a normal run on a Rails app, because every test reads
  and clears the coverage counters. Record on a quiet machine, or in CI, and refresh the map
  when it drifts: a map a few hundred commits old still works, because methods are matched by name.
- Record from a clean working tree; the map is stamped with `HEAD`.

## Select and run

```console
$ minitest-impact select                      # the uncommitted change
$ minitest-impact select --since main         # everything since main
$ minitest-impact select --since main --format json
$ bin/rails test $(minitest-impact select --since main --format paths)
$ minitest-impact run --since main            # select, then bin/rails test the selection
$ bin/rails test:impact SINCE=main            # the same, as a Rake task (added by a Railtie)
```

`--format paths` exits with status 10, and prints nothing, when the change needs the whole suite.
`run` and `test:impact` run the whole suite themselves in that case. `--max N` keeps the N most
likely files.

### For coding agents

Put this in the agent's instructions (`CLAUDE.md`, `AGENTS.md`):

> While you work, run `bin/rails test:impact SINCE=main` instead of the whole suite. Do not run
> the whole suite yourself: it runs after you finish.

Then make that true in your harness: run the full suite as code once the agent says it is done,
and feed back only the failures. On "Confidence: low", `test:impact` already runs the whole suite.

## Jev

[Jev](https://docs.typesafe.ai) is TypeSafe's fast, cheap classifier: it answers typed questions
(yes/no, choice, score) about a state, with calibrated probabilities.

This layer is **not measured yet**: the numbers below were taken without it, and its thresholds
ship untuned (see [Tuning](#tuning)). Treat it as experimental until you have measured it on your
own history.

- Rules stay in code. Jev never decides what a test file is, which files need the whole suite,
  or anything else a path can tell.
- One request per selection, one narrow question per judgment. The state is the change (paths, a
  trimmed diff, your `--intent`) and up to 48 candidate test files with their test names. The
  questions: one yes/no per candidate ("do these tests call, render or assert on something the
  change modifies?"), one choice of the candidate most directly written for the change, with a
  "none" option, and one yes/no for "does every test depend on this?".
- The candidates come from a fast search, and Jev only re-ranks them: the map's selection plus
  test files whose paths and test names share words with the change.
- Exact map hits are never dropped. Jev can add tests, drop weak non-exact ones and reorder, but a
  test the map saw run the changed method stays.
- The thresholds live in one file (`lib/minitest/impact/jev/questions.rb`) and the model version
  is pinned (`jev-1.13.0`), because a threshold tuned on one version does not carry over.

Set `TYPESAFE_API_KEY` to turn it on (`TYPESAFE_BASE_URL` for another endpoint,
`MINITEST_IMPACT_JEV_MODEL` to move the pin). Without a key, or with `--no-jev`, everything runs
offline on the map and the rules. If Jev fails, the map's selection is used and the error is
reported; the agent's loop never breaks on it.

Cost: Jev bills input tokens only, $0.042 per million (docs.typesafe.ai/models). A request with
48 candidates and a 12,000-character diff is under 10,000 tokens: about $0.0004.

### Tuning

The thresholds ship **untuned** (0.5 to keep a candidate, 0.5 confidence for the "most direct"
choice, 0.8 for "whole suite"). Tune them on your own history before trusting them:

```console
$ minitest-impact eval --cases cases.json --jev --format json
```

and move the constants in `questions.rb` to the values that give the recall you need at the
smallest selection.

## Measure it on your history

```console
$ minitest-impact eval --co-changed 200          # commits that changed code and its tests together
$ ruby eval/ci_failures.rb --repo . --out cases.json   # failed CI runs, via the gh CLI
$ minitest-impact eval --cases cases.json
```

Two kinds of labelled cases:

- **Tests a change broke** (`eval/ci_failures.rb`): for each failed GitHub Actions run on the
  default branch, the change since the last green run, and the test files the failed jobs
  reported. A test already failing in the run before is not counted again.
- **Tests written for a change** (`--co-changed N`): commits that changed code and existing test
  files together. The selector sees only the code; the tests the commit edited are the answer.

Reported per case and on average: whether any expected test was selected (`caught`), whether all
were (`all_caught`), recall, precision, and the share of the suite selected.

### First numbers: one Rails app, map only (2026-09-28)

Measured on Piou Piou, a Rails 8.1 app, with the map recorded at one commit: 396 test files (2,673
unit and 88 system tests), 580 KB of JSON (72 KB gzipped). The evaluation made no Jev calls.

| Cases | Caught (any expected test selected) | All caught | Recall | Precision | Share of suite selected | Share of suite time |
|---|---:|---:|---:|---:|---:|---:|
| 150 commits that changed code and tests together, method-level | 94.0% | 90.7% | 0.93 | 0.17 | 12.1% | 24.0% |
| The same 150, file-level | 94.0% | 90.7% | 0.93 | 0.15 | 12.3% | 24.4% |
| 17 failed CI runs on main | 70.6% | 64.7% | 0.68 | 0.07 | 38.5% | 42.2% |
| The same, without 4 runs where only a flaky system test failed | 92.3% (12 of 13) | 84.6% (11 of 13) | 0.88 | 0.10 | 50.2% | 55.1% |

How to read them:

- Six of the 13 real CI breaks changed `Gemfile.lock`, `test_helper.rb` or boot configuration,
  so the rules selected the whole suite. That is correct but costly, and it is why the share
  selected rises to 50% once the flaky runs are left out. On the other seven, the selection was
  7.5% of the suite.
- The one real break missed: a `config/piou.yml` change that failed
  `test/services/sandbox_container_test.rb`, which reads the setting through the app and never
  names the file.
- Method-level tracing barely beats file-level on this history. Most changes land in small,
  focused files, where the two agree.

## Prior art

Nothing did most of this for Minitest, offline, when this gem was written (September 2026):

| Project | What it is | What this gem took |
|---|---|---|
| [Crystalball](https://github.com/toptal/crystalball) (and GitLab's fork) | Coverage-map test selection for RSpec | The shape: record per-test coverage, predict from the diff; views, locales and schema as separate strategies |
| [affected_tests](https://rubygems.org/gems/affected_tests), [test_impact](https://rubygems.org/gems/test_impact) | 2026 map-based selectors, RSpec only | `Coverage.result(clear: true)` per test; exit code for "run everything"; a staleness warning |
| [fast_cov](https://github.com/Gusto/fast_cov) | A C-extension file tracker that leaves `Coverage` to SimpleCov | A candidate recorder backend if recording beside SimpleCov matters more than line numbers |
| [Datadog Test Impact Analysis](https://docs.datadoghq.com/tests/test_impact_analysis/) | Minitest support, but the decision needs Datadog's service | Nothing adopted |
| [Launchable / CloudBees Smart Tests](https://docs.cloudbees.com/docs/cloudbees-smart-tests/latest/features/predictive-test-selection) | Predictive selection as a service | Nothing adopted |
| Google TAP (Memon et al., 2017), Facebook's predictive test selection (Machalica et al., 2019), Ekstazi (Gligoric et al., 2015) | Research | File-level dynamic selection is safe and cheap; most failures are close to the change |
| [`jev`](https://rubygems.org/gems/jev) 0.2.0 | A Ruby client for Jev | Not used yet: it always sends `jev-latest` to one fixed URL, and thresholds need a pinned version |

## Limits

- Code that runs only at boot (initializers, `config/*.rb`) is not in the map; a change there is
  traced by rules or reported as low confidence.
- Views are traced by file, not by line: compiled templates' line numbers are not the ERB's.
- Line coverage cannot see what a test *would* run after the change (a new branch, a new
  callback). That is what the conventional test and Jev are for, and why the full suite stays the
  final gate.

## License

MIT.
