# Developing branchout

The usage loop for a coding agent that is driving branchout lives in [skills/branchout/SKILL.md](skills/branchout/SKILL.md). Copy or symlink that directory into the agent's skills folder when using the tool from another project (see the README). This file is for changing this repository.

## Setup

Ruby 3.3 or newer. `explore` uses the standard library. Development gems are minitest and rspec:

```sh
bundle install
```

## Tests

```sh
ruby test/run_all.rb
bundle exec rspec spec/generated
```

`test/run_all.rb` loads `test/test_*.rb` and `test/generated/*_test.rb`. Coverage is process-global, so the CLI tests start `bin/branchout` in a subprocess.

`test/generated/` and `spec/generated/` are checked-in characterization tests for `examples/`. Regenerate one by re-running `explore` with `--strategy inputs --random 0 --seed 1` and `--emit-tests` pointed at `test/generated/<name>_test.rb` (`--format minitest`) or `spec/generated/<name>_spec.rb` (`--format rspec`). `test/test_examples.rb` checks `reports/*.txt` and `reports/*_baselines.txt` against a fresh run.

## Invariants

- Do not add an LLM client, an API key, or an external command. The agent stays outside the process.
- The same inputs, flags, and CRuby must produce the same stdout. No timestamps. Paths are relative to the working directory.
- The tool does not rewrite an inputs file.
- Do not put secrets in inputs, fixtures, or reports.
