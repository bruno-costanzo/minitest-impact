# Evaluation

This file has the numbers behind the README's "Does it work?" section: how we built the cases, the
results on two apps, and the comparison with simple strategies.

## How the cases are built

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

## First numbers: one Rails app, map only (2026-09-28)

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

## With Jev (2026-09-30)

The same app two days later, with a map recorded at one commit (371 test files), the rules for
files and config keys the application reads, and Jev as a ranker. "First" and "in the top 5" count
the cases where an expected test was ranked there; `--format json` lists `selected` in rank order.

| 150 commits that changed code and tests together | Caught | All caught | Recall | First | In the top 5 | Share of suite selected | Share of suite time |
|---|---:|---:|---:|---:|---:|---:|---:|
| Map and the older rules | 95.3% | 91.3% | 0.94 | 39% | 79% | 11.3% | 19.5% |
| Map and the older rules, Jev allowed to drop picks | 94.0% | 88.0% | 0.92 | 55% | 82% | 9.4% | 16.5% |
| Map and the current rules | 97.3% | 95.3% | 0.97 | 39% | 81% | 13.0% | 21.8% |
| Map, the current rules and Jev as a ranker | 97.3% | 95.3% | 0.97 | 61% | 85% | 13.0% | 21.9% |

How to read them:

- The rules for what the application reads recovered 6 of the 15 tests the older rules missed,
  all of them prompts and templates read through a service. They also select 18% more files.
- Jev's gain is the order. An agent running `--max 5` gets the test written for its change in 85%
  of cases, against 81% without it.
- Of the 9 tests still missed, 3 belong to a commit that added a config key and its tests, with no
  application code reading it yet: nothing but those tests could have pointed at them. Two are
  architecture tests that read the whole source tree. The rest follow a seeds change, an importmap
  change, a one-word config key (`technical`, too common to search for), and one change spread
  over an agent, two jobs and a model.
- Jev answered in about 4.7 seconds per selection, one request each.
- Only 8 failed CI runs fit the newer map, too few to report.

## A second app: Fizzy (2026-09-30)

[Fizzy](https://github.com/basecamp/fizzy), Basecamp's open-source Rails app, with the map
recorded at `a703bf1de` (2026-09-29): 261 test files (1,703 unit tests; the system tests were not
recorded), 686 KB of JSON (62 KB gzipped), on SQLite in a Docker container. Recording took 44
seconds against 39 for a plain run. The evaluation made no Jev calls.

| Cases | Caught | All caught | Recall | Precision | Share of suite selected | Share of suite time |
|---|---:|---:|---:|---:|---:|---:|
| 200 commits that changed code and tests together (December 2025 to September 2026), method-level | 95.5% | 93.5% | 0.95 | 0.30 | 13.1% | 20.7% |

How to read them:

- 6 cases changed a file that needs the whole suite. 43 ended with "Confidence: low"; an agent
  that runs the suite on those, as `test:impact` does, gets 95.5% all caught at 35% of suite time.
- 13 cases missed a test. 5 of them selected nothing: a new Action Text patch in `lib/rails_ext`,
  a service worker view, a SQLite search adapter that no longer exists at the map's commit, a
  partial changed with the SaaS lockfile, and a commit whose only code change was
  `test/test_helper.rb`, which the evaluation hides from the selector along with the tests. A
  `config/routes.rb` change selected its controllers but not `test/routes_test.rb`.
- No failed CI runs could be used. GitHub keeps Actions logs for 90 days; the 15 failed runs on
  `main` whose logs were still there failed installing packages or gems, or on a flaky system
  test in the SaaS bundle. None reported a failing unit test.

## Against simpler strategies

`eval/baselines.rb` replays the same cases with two strategies a coding agent can follow with
no map: **conventional**, the changed tests plus the test named after each changed file
(`app/models/invoice.rb` to `test/models/invoice_test.rb`), and **mentions**, the tests that name
the constant a changed file defines. Both keep the gem's whole-suite rule, which needs no map.

```console
$ ruby -Ilib eval/baselines.rb --repo ../app --map map.json --results eval.json [--cases cases.json]
```

| Cases | Strategy | Caught | All caught | Recall | Precision | Share of suite selected | Share of suite time |
|---|---|---:|---:|---:|---:|---:|---:|
| Piou Piou, 150 commits | minitest-impact | 94.0% | 90.7% | 0.93 | 0.17 | 12.1% | 24.0% |
| | conventional | 78.0% | 50.7% | 0.66 | 0.53 | 2.8% | 4.0% |
| | mentions | 78.0% | 62.0% | 0.72 | 0.18 | 6.4% | 12.4% |
| | both | 81.3% | 66.0% | 0.76 | 0.21 | 6.4% | 12.4% |
| Piou Piou, 17 failed CI runs | minitest-impact | 70.6% | 64.7% | 0.68 | 0.07 | 38.5% | 42.2% |
| | conventional, mentions or both | 47.1% | 47.1% | 0.47 | 0.02 | 36.3% | 37.3% |
| Fizzy, 200 commits | minitest-impact | 95.5% | 93.5% | 0.95 | 0.30 | 13.1% | 20.7% |
| | conventional | 68.5% | 50.0% | 0.60 | 0.54 | 3.6% | 4.4% |
| | mentions | 68.5% | 54.0% | 0.62 | 0.40 | 5.1% | 6.3% |
| | both | 75.5% | 61.0% | 0.69 | 0.46 | 5.2% | 6.6% |

How to read them:

- On commits, the map found every test a change needed in 25 (Piou Piou) and 32 (Fizzy) more
  cases in 100 than the best simple strategy, at twice its test time on Piou Piou and three times
  on Fizzy.
- The simple strategies are more precise. When a change touches one model and its test, they
  pick that test; the map also picks the controllers and jobs that ran the changed method.
- Of the 13 real CI breaks on Piou Piou (the 4 other runs failed on a flaky system test), the map
  caught 12 and every simple strategy 8, at about 40% of suite time for all: six of them needed
  the whole suite.

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

## Tuning Jev

The thresholds ship **untuned** (0.5 to keep a candidate, 0.5 confidence for the "most direct"
choice, 0.8 for "whole suite"). Tune them on your own history before trusting them:

```console
$ minitest-impact eval --cases cases.json --jev --format json
```

and move the constants in `questions.rb` to the values that give the recall you need at the
smallest selection.
