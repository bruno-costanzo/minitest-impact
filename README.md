# minitest-impact

minitest-impact tells you which Minitest test files to run for a change.

It is for coding agents. An agent that runs the whole suite after each edit wastes minutes. With
this gem, the agent runs a small selection while it works. The whole suite still runs once, at
the end, before anything ships.

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

## How it works

1. **The map.** You run your suite once with the recorder. The recorder writes down which lines of
   your app each test file runs. For a change, the gem finds the changed methods. Then it selects
   the tests that ran those methods.
2. **The rules.** Some changes are not in the map: a new file, a locale key, a route, a migration,
   a fixture, a Stimulus controller, a file the app reads by path. Rules in
   `lib/minitest/impact/rules.rb` find the tests for these changes. Some files need the whole suite,
   for example `Gemfile.lock` and `test/test_helper.rb`.
3. **Jev (optional).** Jev is a small, cheap model from TypeSafe. It puts the most likely tests
   first. It does not remove tests. See [Jev](#jev).

Each selection has a confidence:

- **high**: the gem traced every changed file exactly.
- **medium**: the gem traced some file by name or by convention only.
- **low**: the gem could not trace some file, or the change needs the whole suite. Run the whole
  suite.

## Install

```ruby
# Gemfile
group :development, :test do
  gem "minitest-impact"
end
```

You need Ruby 3.3 or newer. The gem has no runtime dependencies.

## Record the map

```console
$ minitest-impact record -- bin/rails test
$ minitest-impact record -- sh -c 'bin/rails test; bin/rails test:system'
```

The map goes to `tmp/minitest-impact/map.json`. Use `--map PATH` to change it.

- Record from a clean working tree. The map keeps the commit it was recorded at.
- Recording takes 2 to 3 times as long as a normal run.
- Record again when the map gets old. A map that is some hundreds of commits old still works,
  because the gem finds methods by name, not by line number.
- SimpleCov is off while the recorder runs. Ruby allows one coverage setup per process. If
  another tool calls `Coverage.start`, turn it off when `MINITEST_IMPACT_RECORD` is set.
- You do not have to add the gem to the app's Gemfile. You can run it from a checkout:
  `ruby -I path/to/minitest-impact/lib path/to/minitest-impact/exe/minitest-impact record -- bin/rails test`.

## Select and run

```console
$ minitest-impact select                      # the uncommitted change
$ minitest-impact select --since main         # all changes since main
$ minitest-impact select --since main --format json
$ bin/rails test $(minitest-impact select --since main --format paths)
$ minitest-impact run --since main            # select, then run the selection
$ bin/rails test:impact SINCE=main            # the same, as a Rake task
```

- `--max N` keeps the N most likely test files.
- When the change needs the whole suite, `select --format paths` prints nothing and exits with
  status 10. `run` also exits with status 10. `test:impact` runs the whole suite.
- `run` and `test:impact` turn SimpleCov off, because a coverage minimum always fails on a few
  tests. If you use `--format paths` with your own runner, turn coverage off yourself.

## For coding agents

Add this to the agent's instructions (`CLAUDE.md`, `AGENTS.md`):

> While you work, run `bin/rails test:impact SINCE=main`. Do not run the whole suite. It runs
> after you finish.

Then make your harness do it: when the agent is done, run the whole suite and give the agent only
the failures.

## Jev

Set `TYPESAFE_API_KEY` to use [Jev](https://docs.typesafe.ai). Without a key, or with `--no-jev`,
the gem works offline with the map and the rules.

- Jev gets the change and up to 48 candidate test files in one request.
- Jev changes the order of the tests. It can add a test. It never removes a test.
- If Jev fails, the gem uses the selection from the map and reports the error.
- A request costs about $0.0004.
- The model version is pinned (`jev-1.13.0`). The thresholds are in
  `lib/minitest/impact/jev/questions.rb`. Tune them on your own history before you trust them
  ([EVALUATION.md](EVALUATION.md#tuning-jev)).

On one app, Jev put the test written for the change first in 61% of cases, against 39% without
it. It did not find a test that the map and the rules missed.

## Does it work?

We measured it on the history of two Rails apps. The full numbers and the method are in
[EVALUATION.md](EVALUATION.md). The main result, against the simplest strategy an agent can use
without a map ("run the test with the same name as each changed file, and the tests that name the
changed class"):

| | minitest-impact | Simple strategy |
|---|---:|---:|
| Piou Piou, 150 commits: all tests written for the change selected | 91% | 66% |
| Fizzy, 200 commits: all tests written for the change selected | 94% | 61% |
| Piou Piou, 13 real CI failures: failure found | 12 | 8 |

The gem selects more tests than the simple strategy. On these commits it ran 21% to 24% of the
suite time. The simple strategy ran 7% to 12%.

To measure it on your own app:

```console
$ minitest-impact eval --co-changed 200
$ ruby eval/ci_failures.rb --repo . --out cases.json
$ minitest-impact eval --cases cases.json
$ ruby -Ilib eval/baselines.rb --repo . --map map.json --results eval.json
```

## Limits

- Code that runs only at boot (initializers, `config/*.rb`) is not in the map. Rules cover some
  of it. For the rest, the confidence is low.
- The gem traces views by file, not by line.
- The map shows what tests ran before the change. It cannot show what a test will run after the
  change, for example a new branch or a new callback. This is why the whole suite must still run
  at the end.

## Prior art

Similar tools exist for RSpec ([Crystalball](https://github.com/toptal/crystalball),
[affected_tests](https://rubygems.org/gems/affected_tests),
[test_impact](https://rubygems.org/gems/test_impact)) and as hosted services (Datadog Test Impact
Analysis, CloudBees Smart Tests). We did not find one for Minitest that works offline.
[EVALUATION.md](EVALUATION.md#prior-art) says what we took from each.

## License

MIT.
