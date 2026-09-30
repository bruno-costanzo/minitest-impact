# Changelog

## 0.2.0 (2026-09-30)

- Record an app from outside its bundle: the recorder loads `json` only when it first writes, so an
  app that pins another `json` still boots, and `SimpleCov.start` does nothing while recording.
- `run` switches SimpleCov off while it runs the selection.
- Record projects that live under a `tmp` directory (Linux's temporary directories, some CI
  workspaces); before, every file was skipped.
- Trace files the application reads by path; Jev only ranks, it never drops an exact map hit.
- `run` exits 10 without running anything when the change needs the whole suite.
- `eval/baselines.rb` scores simple strategies on the same cases, and the README reports them for
  Piou Piou and Fizzy.

## 0.1.0 (2026-09-29)

- First release.
