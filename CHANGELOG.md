# Changelog

## [Unreleased]

First release. branchout runs a Ruby method on many inputs, shows the branch arms that no input took, and writes tests that pin what the method does now. It never calls a model: an agent reads the frontier and proposes the next inputs.

- `branchout explore TARGET ENTRY` runs `Const.method` or `Const#method` on the inputs of a JSON file, plus literal mutations and seeded random samples. The report lists the input that took each arm, and the frontier: each arm no input took, with its condition, the direction that selects it, and the nearest input that reached it. The same inputs and flags print the same report, as text or as `--json`.
- `--emit-tests PATH` writes characterization tests for the inputs, as minitest or as RSpec (`--format rspec`). Each test pins the return value, or the error class and message, and starts with the arms its input took.
- `Branchout.explore` runs inside a test suite, so inputs can use the suite's factories and fixtures. In a Rails app each input runs in a savepoint that is rolled back.
- `branchout baselines` compares random samples, mutations, and the inputs file as separate rows.
- An agent skill in `skills/branchout/`.
- Ruby 3.3 or newer. No runtime dependency.
- A report prints an exception message as Ruby wrote it, on one line: only line breaks become spaces, so the blank String a `FrozenError` quotes keeps its spaces.
- `Branchout.explore` takes `requires:` as one path in a String too, as the README and its refusal write it.
- `--verbose` with `--json`, and `verbose: true` with `json: true`, are refused: the JSON report always holds every arm and the run settings.
- An input whose own Ruby raises before the entry runs, such as a bare `create` in a suite without `FactoryBot::Syntax::Methods`, stops explore with a message that names the input. Before, its error was listed as the entry's and pinned in the emitted test.
- Each input runs a second time, in a suite only when the first run was rolled back. A value made anew on each run, such as a generated UUID id, a factory sequence, or a `SecureRandom` token, is no longer pinned: a returned Hash pins only the keys that were the same both times, a value that differed as a whole gets no test, an error whose message differed is pinned by its class, and stderr names each such input. Before, the emitted test failed on its first run.
