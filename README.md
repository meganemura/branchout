# branchout

Coverage-guided, agent-driven input exploration. It is inspired by concolic execution, and it does not collect or solve symbolic constraints.

Concolic execution runs a program on a concrete input, records the path condition, and asks a solver for an input that takes a branch not yet seen. branchout does only the observation half. It runs one Ruby method on concrete inputs and prints the uncovered branch arms as a short frontier. A person or a coding agent, outside the tool, proposes the next inputs. The tool calls neither an SMT solver nor an LLM.

Running branchout needs no gems. It uses `Coverage`, Prism, json, and minitest from the Ruby install. The emitted RSpec files need the `rspec` gem to run. The development Gemfile lists minitest and rspec as development dependencies. The code targets the Ruby 3.3+ standard library. `ruby test/run_all.rb` and `bundle exec rspec spec/generated` both pass on Ruby 3.4.12 and Ruby 4.0.9, with the same demo counts. Ruby 3.3 itself was not executed here.

## Design

1. The target file is `require`d after `Coverage.setup(lines: true, branches: true)`. Load-time counts are discarded. Each input is `resume`, the call, `suspend`, then `Coverage.result(stop: false, clear: true)`. Only the entry method, and same-file callees reached by a bare call or `self.`, are kept.
2. An arm id looks like `if@line:column/then@line:column`, taken from the Coverage branch key. Columns are 0-based.
3. Condition text is the Prism predicate, or the `when` line. If the locations do not match, the source line is used.
4. A path is the sorted set of arms whose count is positive. A loop shows up as `*count`. Coverage does not record order.
5. The frontier is every arm with count 0. If some input executed that decision, the arm is `parent: reached`, with the simplest input that reached it (fewest taken arms, then smallest absolute numeric weight, then canonical JSON).
6. Literal mutation collects integers, floats, and strings from that slice and tries each one in each argument slot. Integers also include `0`, `1`, `-1`, and literal±1. Only the first two numeric arguments get a cartesian product, cut by `--mutate-cap`. String literals are not concatenated.
7. Random sampling uses a pure-Ruby Park-Miller generator. Integers are -3..12. Strings have length 0..3 over `abc01.-`. The seed is `--seed`.
8. Exceptions are caught and reported. A fault hidden inside an arm, such as division by zero, is separate from arm coverage.
9. Discovered inputs (entries from the inputs file, arm witnesses, and inputs that raised) are emitted as characterization tests. Emitters live in `lib/branchout/emitters/`. minitest and RSpec are available. The core does not require either gem.

The report has no timestamps. The same inputs, flags, and CRuby produce the same stdout bytes.

## Run

```sh
ruby bin/branchout explore examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.json \
  --strategy inputs --random 0 --seed 1

ruby bin/branchout baselines examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.json \
  --seed 1 --random 40

ruby bin/branchout explore examples/hidden_bug.rb HiddenBug.scale \
  --inputs examples/inputs/hidden_bug.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests spec/generated/hidden_bug_spec.rb

bundle install
bundle exec rspec spec/generated

ruby test/run_all.rb
```

`ENTRY` is `Const.method` or `Const#method`. The latter needs `new` with no required arguments.

Flags: `--inputs`, `--seed`, `--random`, `--mutate-cap`, `--strategy inputs,mutate,random`, `--timeout`, `--json`, `--json-out`, `--md-out`, `--emit-tests`, `--format minitest|rspec`. Without `--format`, a path ending in `_spec.rb` selects RSpec and anything else selects minitest.

Input file:

```json
{
  "types": ["int"],
  "inputs": [
    {"args": [0]},
    [114514]
  ]
}
```

If `types` is omitted, each parameter is inferred as int, float, string, array, or hash from how the method body uses it.

## Agent loop

The procedure is in [AGENTS.md](AGENTS.md). During search, keep `--strategy inputs --random 0 --seed 1`. For each `parent: reached` arm, the agent appends one input derived from `nearest` and reruns the same command. The tool does not edit the file.

The demos below were produced by following that procedure. No model API was called. The tool has no LLM backend.

Round 0 for the magic value (`examples/inputs/magic_value.seed.json`):

```
branchout explore
target: examples/magic_value.rb
entry: MagicValue.classify
seed: 1
strategies: inputs
random: 0
mutate_cap: 256
timeout: 1
inputs_ran: 1
mutate_ran: 0
random_ran: 0
executions: 1
arms_covered: 1
arms_total: 2
exceptions: 0

COVERED
id: if@5:4/else@8:6
loc: examples/magic_value.rb:8:6
cond: x == 114514
sense: cond-false
input: [0]

FRONTIER
id: if@5:4/then@6:6
loc: examples/magic_value.rb:6:6
cond: x == 114514
sense: cond-true
parent: reached
nearest: [0]
path: if@5:4/else@8:6

EXCEPTIONS
(none)
```

`sense: cond-true` means the next input is `[114514]`. Round 1 reports `arms_covered: 2` and `FRONTIER` `(none)`.

Inputs added in the other demos:

| Demo | Rounds | Final inputs | Result |
| --- | --- | --- | --- |
| `MagicValue.classify` | 1 | `[0]`, `[114514]` | 2/2 |
| `Arithmetic.classify` | 3 | `[0,0,0]`, `[138,0,0]`, `[114514,0,0]`, `[138,143,0]`, `[138,143,7]` | 7/8. The `then` of `x == 114514 && x == 0` stays uncovered |
| `VersionParser.parse` | 3 | `""`, `"0"`, `"-"`, `"0.0.0"`, `"0-rc1"`, `"0-beta1"` | 12/12 |
| `HiddenBug.scale` | 2 | `[0,0]`, `[11,11]`, `[100,11]`, `[24,12]` | 4/4. `[24,12]` raises `ZeroDivisionError` |

Arithmetic goes one decision at a time: `(x * 3 + 7) % 1000 == 421` (`x = 138`), then `y == x + 5` (`y = 143`), then `z == 7`. The version parser goes from a non-empty string, to a hyphen and a three-part number, then to `rc` and `beta`. The hidden bug first makes both arguments greater than 10, then tries `a - b * 2 >= 50` and `a == b * 2`.

Stdout from each round is in `reports/transcripts/`.

## Baselines

`baselines` was run with `--seed 1 --random 40 --mutate-cap 256`. The agent column is the final inputs file. The random and mutate columns do not run those inputs. An execution count below 40 means duplicate samples were dropped.

| Target | random | mutate | agent |
| --- | --- | --- | --- |
| magic_value (2 arms) | 15 runs, 1 covered, 0 exceptions | 6 runs, 2 covered, 0 exceptions | 2 runs, 2 covered, 0 exceptions |
| arithmetic (8 arms) | 40 runs, 2 covered, 0 exceptions | 256 runs, 2 covered, 0 exceptions | 5 runs, 7 covered, 0 exceptions |
| version_parser (12 arms) | 20 runs, 8 covered, 0 exceptions | 12 runs, 8 covered, 0 exceptions | 6 runs, 12 covered, 0 exceptions |
| hidden_bug (4 arms) | 37 runs, 1 covered, 0 exceptions | 196 runs, 4 covered, 0 exceptions | 4 runs, 4 covered, 1 exception |

`114514` is a source literal, so mutation covers both magic-value arms. It is outside the random domain.

Random and mutation on arithmetic cover only the two arms taken when the congruence is false. `138` is not a literal or a literal±1.

On the version parser they stop at empty, non-release, and a hyphen whose tag is neither `rc` nor `beta`. The four missing arms are the `then` of `tag.start_with?("rc")`, the `then` of `tag.start_with?("beta")`, the `then` of `release?(text)`, and `parts.length == 3` being true.

Mutation of the hidden bug covers all four arms by cartesian product. No pool pair has `a == 2 * b` with both values greater than 10, so it records no exception. Only the agent's fourth input raises `divided by 0`. Full arm coverage is not the same as finding the fault.

Raw tables are `reports/*_baselines.txt`. Frontiers are `reports/*.txt`, `reports/*.json`, and `reports/*.md`.

## Characterization tests

`test/generated/` is minitest. `spec/generated/` is RSpec. Both pin the return value, or the exception class and message, for the final inputs.

```sh
ruby test/generated/hidden_bug_test.rb
bundle exec rspec spec/generated/hidden_bug_spec.rb
```

The RSpec form is `expect(HiddenBug.scale(0, 0)).to eq(:out_of_range)` and `expect { HiddenBug.scale(24, 12) }.to raise_error(ZeroDivisionError, "divided by 0")`.

`HiddenBug.scale(24, 12)` raises `ZeroDivisionError` with `"divided by 0"`. `HiddenBug.scale(11, 11)` returns `-91` (`1000 / -11`).

## Determinism

Ids, frontier arms, exceptions, and baseline rows are sorted. JSON key order is fixed by the writer, and strings are escaped as `\uXXXX`. `-0.0` in an input becomes `0.0`. Compact output has no timestamps and no absolute paths. Paths are relative to the working directory.

## Limitations

- The target really runs. Stdout and stderr are discarded. Files, globals, and the network are not. This is not a sandbox.
- A method that depends on time, randomness, or I/O will not produce a stable report.
- A path is a set of arms, not an order. Collapsing to uncovered arms avoids path explosion, and it also hides two orders that take the same arms. `*count` is only the loop count.
- Coverage branches are `if`, `unless`, `case`, `while`, `until`, `&.`, and pattern `in`. `&&` and `||` are not arms. `while` has only a body arm; a condition that ran but did not enter the body is recovered from the line count. A modifier `unless` can put `then` and `else` at the same location; the arm name in the id distinguishes them.
- Calls other than a bare call or `self.` in the same file are not followed. `send` and other files are out of scope.
- `Timeout.timeout` does not stop every kind of block. If the timeout backtrace has no target line, `loc` is the method definition line.
- An unsatisfiable condition stays on the frontier. Arithmetic's `x == 114514 && x == 0` is one.
- The random and mutation domains above are intentionally narrow. A wider domain would hit solutions by chance and blur the table.
- Coverage is process-global. The tests start the CLI in a subprocess.

## Next steps

Discovered values can seed property tests. The `hegeltest` gem, a Ruby binding for the Hegel engine, draws values with `Hegel.test` and replays failures through `reproduce_failure` and the example database (`database_key`). Feed branchout's inputs.json in as initial failures, or evaluate those arguments once at the start of the property. That is the role Hypothesis-style Crosshair fills with a solver. Here the frontier and the agent's proposals fill it.

For just-in-time catching tests, run the same inputs on base and head and keep only the ones whose return value or exception differs. Uncovered arms, and the nearest input that reached them, are the seeds. That stands in for shadow symbolic execution steering inputs toward the changed path.

Narrow the target with SimpleCov's per-test coverage. After `SimpleCov.start { track_tests }`, `simplecov affected --base main` lists tests that touch the change. Limit `explore` to methods those tests hit, so the agent is not asked to read unrelated arms.

The surrounding work is ConcoLLMic (an LLM assisting a concolic solver), AutoBug, and the literal-as-comparison-operand writeup at [zenn.dev/termoshtt/articles/concolic-execution](https://zenn.dev/termoshtt/articles/concolic-execution). Those put a solver next to concrete execution. This repository puts the agent outside the tool, in the solver's place.

Japanese documentation: [README.ja.md](README.ja.md).
