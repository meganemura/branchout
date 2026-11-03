# branchout

branchout runs one Ruby method on concrete inputs and prints the branch arms those inputs did not take.

A coding agent adding tests can see that a branch was missed and still not know which comparison failed, or which input came closest. branchout prints that frontier: the condition, the direction that selects the arm, and the nearest input that reached the decision. The agent appends an input and reruns the same command. branchout does not edit the inputs file. When the search stops, it writes a minitest or RSpec example that pins each discovered return value or exception.

The method follows concolic testing ([DART](https://doi.org/10.1145/1065010.1065036), [CUTE](https://doi.org/10.1145/1094811.1094816)) and LLM-guided concolic work such as [ConcoLLMic](https://concollmic.github.io/). branchout is inspired by concolic testing but does no symbolic solving. The agent proposes inputs from the branch frontier.

## Usage

Run this from the repository root. The seed file holds one input, `[0]`.

```sh
ruby bin/branchout explore examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.seed.json \
  --strategy inputs \
  --random 0 \
  --seed 1
```

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

`sense: cond-true` on `x == 114514` is the arm `[0]` did not take. Append `[114514]` and rerun the same command. `examples/inputs/magic_value.json` is that file. It reports `arms_covered: 2` and `FRONTIER` `(none)`.

`ENTRY` is `Const.method` or `Const#method`. A method under `module_function` is `Const.method`. For `Const#method`, each input gets its own receiver from `Const.new`. If `initialize` takes arguments, put them in `new` on each input, in the same shape as an input: `{"args": [5], "new": [10]}` calls `Const.new(10).method(5)`. `--entry ENTRY` may replace the positional entry.

While searching, pass `--strategy inputs --random 0` and keep `--seed` fixed, so a new covered arm comes from an input you added. The search procedure is in [skills/branchout/SKILL.md](skills/branchout/SKILL.md).

| Flag | Default | Meaning |
| --- | --- | --- |
| `--inputs PATH` | none | JSON file of inputs |
| `--require PATH` | none | Load PATH before the target, for a target that needs the rest of its library. Repeatable. Emitted tests require it too |
| `--seed N` | `0` | RNG seed |
| `--random N` | `16` | Number of random samples |
| `--mutate-cap N` | `256` | Literal-mutation budget |
| `--strategy LIST` | `inputs,mutate,random` | Comma-separated strategies, in the order below |
| `--timeout SEC` | `1` | Per-input timeout. Must be > 0 |
| `--json` | off | Print JSON on stdout instead of the text report |
| `--json-out PATH` | | Write the JSON report |
| `--md-out PATH` | | Write the text report as Markdown |
| `--emit-tests PATH` | | Write characterization tests. `explore` only |
| `--format NAME` | `minitest` | `minitest` or `rspec`. Requires `--emit-tests`. If omitted, a path ending in `_spec.rb` selects RSpec |
| `--entry ENTRY` | the positional argument | `Const.method` or `Const#method` |

| Strategy | What it runs |
| --- | --- |
| `inputs` | Entries in the inputs file. Duplicate canonical JSON is dropped |
| `mutate` | Each source literal, tried in each argument slot. Integers also include `0`, `1`, `-1`, and literal±1. Floats also include `0.0`, `1.0`, `-1.0`, and ±1. Strings also include `""`, `"a"`, the literal without its last character, and the literal plus `"1"`. When the first two positional parameters are numeric, those slots also get a cartesian product, cut by `--mutate-cap`. String literals are not concatenated |
| `random` | Seeded Park-Miller samples. Integers are -3..12. Strings have length 0..3 over `abc01.-` |

```sh
ruby bin/branchout baselines examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.json \
  --seed 1 --random 40
```

`baselines` runs `random`, `mutate`, and `agent` (the inputs file only) as separate rows. The random and mutate rows do not run the inputs file. On this target, `random` executes 15 inputs and covers 1 of 2 arms, `mutate` executes 6 and covers both, and `agent` executes 2 and covers both.

An inputs file starts as one seed:

```json
{
  "inputs": [
    {"args": [0]}
  ]
}
```

An entry may be a bare array. Keywords go in `kwargs`, and constructor arguments go in `new`. If type inference is wrong, set `"types"` to one of `int`, `float`, `string`, `array`, or `hash` per positional parameter. Other top-level keys, such as `meta`, are ignored. Append entries. Do not delete or reorder them.

```sh
ruby bin/branchout explore examples/hidden_bug.rb HiddenBug.scale \
  --inputs examples/inputs/hidden_bug.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests spec/generated/hidden_bug_spec.rb \
  --format rspec
```

That run covers 4 of 4 arms and records `ZeroDivisionError` (`divided by 0`) for `[24,12]`. The emitted file pins each return value, or the exception class and message. A return value with no Ruby literal, such as a `Set` or a `Struct`, is pinned by its class only. A minitest path uses `--format minitest` and runs with `ruby`. An RSpec file needs the `rspec` gem.

## How it builds the frontier

branchout loads the `--require` files and then the target after `Coverage.setup(lines: true, branches: true)` and discards the counts from loading. For each input it resumes coverage, calls the method, suspends coverage, and reads `Coverage.result`. It keeps the entry method and same-file callees reached by a bare call or `self.`.

An arm id is `kind@line:column/arm@line:column`, from the Coverage branch key. Columns are 0-based. `cond` is the Prism predicate. For a `when` or `in` arm it is that line. If the locations do not match, the source line is used.

The frontier is every arm whose count is 0. `parent: reached` means some input executed that decision. `nearest` is the one that reached it with the fewest taken arms, then the smallest weight (absolute numeric size, plus string and container length), then the smallest canonical JSON. `path` is the sorted set of arms that input took. Coverage does not record order. A loop count greater than 1 is written as `*count`.

`sense` is the direction that selects the arm: `cond-true` (`if` then, `unless` else), `cond-false` (`if` else, `unless` then), `arm-matched` (that `when` or `in`), `arm-else`, `body-entered` (`while` or `until` body), `receiver-present`, or `receiver-nil` (`&.`).

Exceptions are listed apart from arm coverage. A covered arm can still raise. The same inputs, flags, and CRuby produce the same stdout. The report has no timestamps. Paths are relative to the working directory.

## Install

Ruby 3.3 or newer. Exploring uses Coverage, Prism, and json from the standard library. From this checkout, run `ruby bin/branchout`, or put `bin` on `PATH`. Emitted minitest files run under `ruby`. Emitted RSpec files need the `rspec` gem.

Install the [branchout skill](skills/branchout/SKILL.md) with the [`skills`](https://github.com/vercel-labs/skills) CLI (Node.js 22.20 or later). This repository is private, so these commands need GitHub access.

```sh
npx skills add meganemura/branchout
```

```sh
npx skills add meganemura/branchout --skill branchout
```

```sh
npx skills add meganemura/branchout -g
```

```sh
npx skills add meganemura/branchout -a cursor
```

`--skill` selects this skill, `-g` installs it for every project, and `-a` targets one agent.

To copy or symlink it instead:

```sh
mkdir -p .agents/skills
ln -s /path/to/branchout/skills/branchout .agents/skills/branchout
```

`.claude/skills/` and `.cursor/skills/` work the same way.

## Limits

- The target runs. Its stdout and stderr are discarded. Files, globals, and the network are not sandboxed.
- A method that depends on time, randomness, or I/O will not produce a stable report.
- A path is a set of arms, not an order. `&&` and `||` are not arms. `while` and `until` record a body arm; a condition that ran but did not enter the body is recovered from the line count.
- A modifier `unless` can put `then` and `else` at the same location. The arm name in the id distinguishes them.
- Calls other than a bare call or `self.` in the same file are not followed. `def self.apply(x) = new.check(x)` has no arms, and `explore` warns on stderr; target `Const#check` instead.
- `Timeout.timeout` does not stop every block. If the timeout backtrace has no target line, `loc` is the method definition line.
- An unsatisfiable condition stays on the frontier. In `examples/arithmetic.rb`, `x == 114514 && x == 0` is one.
- The random and mutation domains above are narrow on purpose.
- Coverage is process-global. Run the CLI in its own process.

## Development

These commands are for a source checkout.

```sh
bundle install
ruby test/run_all.rb
bundle exec rspec spec/generated
```

`test/run_all.rb` loads `test/test_*.rb` and `test/generated/*_test.rb`. `spec/generated/` is the emitted RSpec for `examples/`. The CLI tests start `bin/branchout` in a subprocess because coverage is process-global.

## License

No license has been chosen yet.

---

[Japanese](README.ja.md)
