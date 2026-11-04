# Developing branchout

The usage loop for a coding agent that is driving branchout lives in [skills/branchout/SKILL.md](skills/branchout/SKILL.md). Copy or symlink that directory into the agent's skills folder when using the tool from another project (see the README). This file is for changing this repository.

## Setup

Ruby 3.3 or newer. `explore` uses the standard library. Development gems are minitest, rspec, and hegeltest. hegeltest needs Ruby 3.4 or newer, so on Ruby 3.3 leave its group out:

```sh
bundle install
BUNDLE_WITHOUT=property bundle install   # Ruby 3.3
```

## Tests

```sh
ruby test/run_all.rb
bundle exec rspec spec/generated
```

In a checkout whose gems live only in the bundle, as in CI, run both under `bundle exec`. On Ruby 4.0 set `BUNDLE_VERSION=system` for `bundle install` and `bundle exec`. Otherwise bundler switches to the 2.6.9 that `Gemfile.lock` names, that bundler warns about Ruby 4.0's RubyGems constants in every Ruby the tests start, and the CLI tests that require an empty stderr fail. `.github/workflows/ci.yml` runs both on Ruby 3.3 (without the property group) and 4.0, and on 4.0 runs `CLITest` once more with `BRANCHOUT_TEST_SPAWN=1`.

`test/run_all.rb` loads `test/test_*.rb` and `test/generated/*_test.rb`. Coverage is process-global, so each CLI test runs branchout in a process of its own: `test/support/cli.rb` forks it from a server that loaded branchout before any test ran, which saves the Ruby and prism boot of each run. Where fork does not exist, or with `BRANCHOUT_TEST_SPAWN=1`, each run spawns `bin/branchout` instead. `test/test_properties.rb` holds the hegeltest properties of the pure parts and of report determinism. On Ruby 3.3 it reports one skip.

`test/generated/` and `spec/generated/` are checked-in characterization tests for `examples/`. Regenerate one by re-running `explore` with `--strategy inputs --random 0 --seed 1` and `--emit-tests` pointed at `test/generated/<name>_test.rb` (`--format minitest`) or `spec/generated/<name>_spec.rb` (`--format rspec`). `test/test_examples.rb` checks `reports/<name>.*`, `test/generated/`, and `spec/generated/` against a fresh run of each example. Regenerate them together when output changes.

## Invariants

- Do not add an LLM client, an API key, or an external command. The agent stays outside the process.
- The same inputs, flags, and CRuby must produce the same stdout. No timestamps. Paths are relative to the working directory.
- The tool does not rewrite an inputs file.
- Do not put secrets in inputs, fixtures, or reports.
