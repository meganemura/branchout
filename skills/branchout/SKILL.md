---
name: branchout
description: "Explore concrete inputs that reach uncovered Ruby branch arms and emit minitest or RSpec characterization tests. Use when adding tests for under-covered Ruby branches, when exploring inputs that reach an uncovered if/unless/case/while arm, or when a Ruby method's branch coverage is still incomplete."
compatibility: Requires Ruby 3.3+ and the branchout executable. Running emitted RSpec needs the rspec gem.
---

# branchout

branchout runs one Ruby method on concrete inputs and prints the branch arms still uncovered. It does not solve constraints, call a model, or edit the inputs file. You read the frontier, append inputs, and rerun the same command.

## Install

Ruby 3.3 or newer. Exploring uses Coverage, Prism, and json from the standard library. No gem is required to explore.

The executable is `bin/branchout`. Put that `bin` directory on `PATH`, or run `ruby /path/to/branchout/bin/branchout` with the same arguments. A project may instead depend on the gem with a path or git source and call `bundle exec branchout`.

Emitted minitest files run under `ruby` (minitest ships with Ruby). Emitted RSpec files need the `rspec` gem.

## Explore

Keep literal mutation and random sampling off, so new coverage comes only from inputs you add.

```sh
branchout explore TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --strategy inputs \
  --random 0 \
  --seed 1
```

`ENTRY` is `Const.method` for a class or module method, including one under `module_function` or in a module that calls `extend self`, or `Const#method` for an instance method. The instance form builds a new receiver for each input with `Const.new`. When `initialize` takes arguments, put them in `new` on every input. `--entry ENTRY` may replace the positional entry.

`--strategy` is a comma list of `inputs`, `mutate`, and `random` (default: all three). `--random` defaults to 16 and `--seed` to 0. During the search, pass `--strategy inputs --random 0` and keep `--seed` fixed. The same inputs, flags, and CRuby produce the same stdout.

Other flags: `--require PATH`, `--mutate-cap N` (default 256), `--timeout SEC` (default 1, must be > 0), `--json` (JSON on stdout instead of text), `--json-out PATH`, `--md-out PATH`.

## Inputs JSON

Start from one seed. [inputs.example.json](inputs.example.json) shows every accepted key. A real seed is usually just `inputs`; set `types` only when inference is wrong, one entry per positional parameter.

```json
{
  "inputs": [
    {"args": [0]}
  ]
}
```

- An entry is `{"args": [...]}` or a bare array. Keywords go in `kwargs`: `{"args": [0], "kwargs": {"flag": true}}`.
- For `Const#method`, constructor arguments go in `new`, in the same shape as an entry: `{"args": [5], "new": [10]}` calls `Const.new(10).method(5)`. Inputs differ by `new` too, so a method with no parameters is explored by varying `new`. `mutate` and `random` cannot fill `new`, so keep `--strategy inputs` for such a class.
- When the method reads state that later calls build, such as `cart.add(...)` before `cart.total`, list those calls in `setup`, in order: `{"args": [], "setup": [{"method": "add", "args": ["apple", 3]}]}`. Each step has `method` and optional `args` and `kwargs`. Coverage counts only the entry call. An exception raised in a setup call is still reported, with `loc` on that line. The emitted test names the receiver after the class (`cart = Shop::Cart.new`) and repeats the calls.
- Seeds: `[0]` int, `[0.0]` float, `[""]` string, `[[]]` array, `[{}]` hash, `[false]` bool.
- `"types"` values are `int`, `float`, `string`, `array`, `hash`, or `bool`. A default of `[]`, `{}`, `true`, or `false` already gives the type. The array length must match the positional parameters. Extra top-level keys such as `meta` are ignored.
- Values may be null, booleans, numbers, strings, arrays, and objects. `-0.0` is stored as `0.0`.
- Append. Do not delete or reorder entries. Leave a failed attempt in the file so you do not retry it blindly.

The target file must load and define the entry. When it needs the rest of its library (a constant from another file), pass the library's entry file with `--require PATH`, repeatable. It loads before the target, and emitted tests require it too. The method's own stdout and stderr are discarded.

An instance method of a library class, with constructor arguments in each input's `new`:

```sh
branchout explore lib/foo/model.rb 'Foo::Model#value' \
  --require lib/foo.rb \
  --inputs path/to/inputs.json \
  --strategy inputs --random 0
```

Run from the project root. `loc` and `target` print relative to the current directory, and absolute paths otherwise.

## Reading the frontier

Stdout is the contract. Sections are `COVERED`, `FRONTIER`, and `EXCEPTIONS`. Ids are sorted. There is no timestamp.

- `id` is `kind@line:column/arm@line:column`. Columns are 0-based, matching Coverage and Prism. A loop count greater than 1 is appended as `*count`.
- `loc` is `file:line:column`. Open that line. `cond` is the predicate, or the `when` / `in` line. Longer text is cut at 160 characters.
- `sense` selects the arm: `cond-true` (`if` then, `unless` else), `cond-false` (`if` else, `unless` then), `arm-matched` (that `when` or `in`), `arm-else` (case else), `body-entered` (`while` or `until` body), `receiver-present` / `receiver-nil` (`&.`). Anything else is `taken`.
- `parent: reached` means some input executed the decision. Flip these first. `parent: not-reached` means the parent has not run and `nearest` is `null`. Reach the parent first.
- `nearest` reached the decision with the fewest taken arms, then the smallest weight (absolute numeric size, plus string and container length), then the smallest canonical JSON. With no keywords and no `new` it prints as the args array (`[0,1]`), which pastes into `args`. With keywords, `new`, or `setup` it prints as `{"args":[...],"kwargs":{...}}`, plus `"new"` and `"setup"` when set, which pastes back as an entry.
- `path` is the sorted set of arms `nearest` took. Order is not recorded. An empty set prints `(none)`; a missing path prints `null`.
- `COVERED` uses `input` for the witness of that arm. `EXCEPTIONS` lists `class`, `loc`, `input`, and `message`. An empty frontier can still have exceptions, and a covered method can still raise.

`--json` is the same report (`version`, counts, `covered`, `frontier`, `exceptions`). Each frontier object has `id`, `loc`, `cond`, `sense`, `parent`, `nearest` (`{"args","kwargs"}`, plus `"new"` and `"setup"` when set, or null), and `path`.

## Rounds

1. Run the explore command.
2. Read uncovered arms with `parent: reached`, in id order.
3. If you have not yet added an input meant to flip that arm, add one. Copy `nearest` and change it only enough to satisfy `cond` and `sense`. `&&` and `||` are not separate arms.
4. If a covered arm divides by a non-constant denominator, indexes out of range, or `raise`s, and you have not yet added an input that fires that fault while staying in the arm, add one.
5. Save and rerun the same command.
6. Stop when `FRONTIER` is `(none)` and no fault remains to aim at, or every remaining `parent: reached` arm has already been tried and did not flip (unsatisfiable, such as `x == 1 && x == 0`), or you have completed 8 rounds.

In one round, add inputs only for arms that are reached now and for faults you can see now. Do not batch `parent: not-reached` arms before their parent has run.

## Emit tests

When you stop, emit characterization tests. Each one pins a discovered input's return value, or the exception class and message. A `NameError` or `NoMethodError` is pinned by its class and `error.name`, so the test passes on Ruby 3.3 and 3.4+ alike. A return value with no Ruby literal, such as a `Set` or a `Struct`, is pinned by its class only.

```sh
branchout explore TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests test/generated/name_test.rb \
  --format minitest \
  --json-out reports/name.json \
  --md-out reports/name.md
```

```sh
branchout explore TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests spec/generated/name_spec.rb \
  --format rspec
```

`--format` is `minitest` or `rspec` and requires `--emit-tests`. `--emit-tests` is valid only with `explore`. Without `--format`, a path ending in `_spec.rb` selects RSpec and any other path selects minitest.

Verify the files run:

```sh
ruby test/generated/name_test.rb
rspec spec/generated/name_spec.rb
```

Optional, and not part of the search: compare the inputs file with random sampling and literal mutation.

```sh
branchout baselines TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --seed 1 --random 40
```

`baselines` prints three rows: `random` only, `mutate` only, and `agent` (the inputs file only). Random integers are -3..12. Random strings have length 0..3 over `abc01.-`. Mutation tries each source literal and literal±1 in each slot, then a cartesian product of the first two numeric slots, cut by `--mutate-cap` (default 256). It does not solve a congruence or concatenate string literals. Full arm coverage is not the same as finding a fault inside an arm.

## Use with the other tools

Emitted minitest files work as jitcatch candidate tests. jitcatch copies each candidate into `.jitcatch/` of a base and a head checkout, so emit to that path inside a checkout of the base revision. Then `require_relative` resolves in both checkouts.

```sh
git -C REPO archive BASE | tar -x -C base-checkout
cd base-checkout
branchout explore lib/foo.rb Foo.parse --inputs inputs.json \
  --strategy inputs --random 0 --emit-tests .jitcatch/foo_parse_test.rb
cp .jitcatch/foo_parse_test.rb TESTS_DIR/
jitcatch run --repo REPO BASE HEAD TESTS_DIR
```

A test that passes on base and fails on head is a changed return value or exception for that input. Read the `# covers:` line above the assertion to see which arms the input took.

## Pitfalls

- The target really runs. Files, globals, and the network are not sandboxed.
- A method that depends on time, randomness, or I/O will not stay stable across runs.
- A path is a set of arms, not an order. Two orders that take the same arms look the same. A modifier `unless` can put `then` and `else` at the same `loc`; the arm name in the id distinguishes them.
- Only a bare call, a `self.` call, and a call on a bare `new(...)` in the same file are followed. `def self.apply(doc) = new(doc).apply` reaches `initialize` and `#apply`. `send`, another receiver, and other files are out of scope. When the entry reaches no arm, `explore` warns on stderr; target the method that branches.
- Emitted tests pin other exception messages exactly. A message that differs between Ruby versions fails on a Ruby other than the one that emitted it.
- `Timeout.timeout` does not stop every block. If the timeout backtrace has no target line, `loc` is the method definition line.
- An unsatisfiable condition stays on the frontier. Stop trying it.
- Coverage is process-global. Run the CLI in its own process.
- Do not put secrets in inputs or reports. The tool will not rewrite the inputs file.
