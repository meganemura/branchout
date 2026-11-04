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
callees_not_counted: 0

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

NOT COUNTED
(none)
```

`sense: cond-true` on `x == 114514` is the arm `[0]` did not take. Append `[114514]` and rerun the same command. `examples/inputs/magic_value.json` is that file. It reports `arms_covered: 2` and `FRONTIER` `(none)`.

`ENTRY` is `Const.method` or `Const#method`. A method under `module_function` or in a module that calls `extend self` is `Const.method`. For `Const#method`, each input gets its own receiver from `Const.new`. If `initialize` takes arguments, put them in `new` on each input, in the same shape as an input: `{"args": [5], "new": [10]}` calls `Const.new(10).method(5)`. A `new` of keywords only may leave out `args`: `{"args": [5], "new": {"kwargs": {"main": 1}}}` calls `Const.new(main: 1).method(5)`. When the state the method reads comes from calls after `new`, list them in `setup`, in order: `{"args": [], "setup": [{"method": "add", "args": ["apple", 3]}]}` calls `add("apple", 3)` on the new receiver and then the method. Each step takes `method`, `args`, and `kwargs`. Coverage counts only the call to the method, not `new` or `setup`. When the target file defines `initialize`, `mutate` and `random` fill `new` from its parameters too. `--entry ENTRY` may replace the positional entry.

While searching, pass `--strategy inputs --random 0` and keep `--seed` fixed, so a new covered arm comes from an input you added. The search procedure is in [skills/branchout/SKILL.md](skills/branchout/SKILL.md).

| Flag | Default | Meaning |
| --- | --- | --- |
| `--inputs PATH` | none | JSON file of inputs |
| `--require PATH` | none | Load PATH before the target, for a target that needs the rest of its library. Repeatable. PATH's directory joins the end of the load path, after the gems, so `lib/name.rb` can `require "name/part"`, and `config/puma.rb` beside `config/environment.rb` does not hide the puma gem. Emitted tests require PATH too |
| `-I DIR` | none | Put DIR on the load path while exploring, as `ruby -I` does. Repeatable. With `--require-by-name`, a file under DIR is required by its name from DIR, such as a Rails model under `app/models` |
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
| `--pin-keys LIST` | | Comma list of keys. A returned Hash pins only these keys (`slice` in minitest, `include` in RSpec), so a key added later fails no test. Requires `--emit-tests` |
| `--require-by-name` | off | Emitted tests `require` the `--require` files and the target through the load path, named from the first `-I` directory or `--require` file's directory that holds each (`require "shop/cart"`). With neither, named from the nearest `lib` directory above the target, or the target's own directory. A file that no such directory holds is required by path, with a comment above it and a line on stderr that say so. A `# Load path: -I lib` comment above the requires names each directory the test needs on the load path; an RSpec file leaves out `spec` and `lib`, which rspec adds itself. Requires `--emit-tests` |
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

An entry may be a bare array. Keywords go in `kwargs`, constructor arguments go in `new`, and calls that build the receiver's state go in `setup`. A receiver that `new` cannot build, such as a saved record, is Ruby in `receiver`: `{"receiver": {"ruby": "Factories.loan(3)"}, "args": [{"ruby": "loan.amount"}]}`. The receiver takes the name the emitted test gives it, the class in snake case, so the arguments and `setup` can read from it. If type inference is wrong, set `"types"` to one of `int`, `float`, `string`, `array`, `hash`, or `bool` per positional parameter. A default value of `[]`, `{}`, `true`, or `false` gives its type, and `bool` makes mutation and random sampling try both `false` and `true`. Other top-level keys, such as `meta`, are ignored, and so is a `note` on an entry, which keeps the reason for that input beside it. An entry's `pin_keys` (`{"args": [3], "pin_keys": ["tax"]}`) replaces `--pin-keys` for that input's test, and `"pin_keys": []` pins its Hash whole. A value JSON cannot write, such as a record or an exception, is Ruby in `{"ruby": "..."}`, often a factory in a `--require` file: `{"args": [{"ruby": "Factories.loan(3)"}]}`. Each call evaluates it again at the top level, and the emitted tests write it as given (`Lending.approve(Factories.loan(3))`). A block the method takes goes in `block`, with braces: `{"args": [5], "block": "{ |amount| amount > 2 }"}`. A Hash argument whose one key is `"ruby"` is written as Ruby too: `{"ruby": "{\"ruby\" => \"3.4\"}"}`. Append entries. Do not delete or reorder them.

```sh
ruby bin/branchout explore examples/hidden_bug.rb HiddenBug.scale \
  --inputs examples/inputs/hidden_bug.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests spec/generated/hidden_bug_spec.rb \
  --format rspec
```

That run covers 4 of 4 arms and records `ZeroDivisionError` (`divided by 0`) for `[24,12]`. The emitted file pins each return value, or the exception class and message, a message over several lines as it was raised. A `NameError` or `NoMethodError` is pinned by its class and missing name (`error.name`), because Ruby 3.4 reworded their messages. A message that quotes a backtrace frame (`lib/x.rb:3:in 'Box.run'`) is matched by a Regexp that accepts the frame's label in either form, because Ruby 3.4 changed labels from `` `run' `` to `'Box.run'`. So is a returned String that quotes one, such as a `raised in:` line. A `Set` is pinned by its members (`Set[1, 2]`). A return value with no Ruby literal, such as an `Object`, is pinned by its class only. In RSpec a `Struct` or `Data` value is pinned by its class and members, and an Array or Hash that holds one item by item (`match([a_kind_of(Rule).and(have_attributes(action: "borrow"))])`); minitest pins a `Struct` by its class only. An expected Hash keeps the value's own key order, so a failure diff lines up key by key. A private or protected entry, and a private `new`, are called through `send`, as `explore` called them. A class or module that `private_constant` hides is reached through `const_get` (`Shop.const_get(:Ledger)`), and the RSpec describe names it as a string. A minitest test is named after its input and outcome, such as `test_24_12_raises_zero_division_error`. Inputs whose names would be the same are named by the values that differ between them, such as `test_status_timeout__error_class_timeout_returns_ok`, so adding an input can rename those. Strings that share their start are named from the words where they part. Ruby source that shares its start, such as two factory calls in `receiver`, keeps the word before they part (`test_limit_100_returns_ok`). A name is cut between words, a blank string shows as `blank`, and a Hash argument is named by its values. A collection in a Hash argument is named by its key and size (`groups_3`, `tags_empty`), and an Array of collections by its size (`array_of_2`). An Array that holds scalars and collections says each scalar and the keys of each Hash (`returns [:ok, a Hash of id, name]`, `returns_ok_hash__id__name`). A number of more than 15 digits is named by its first three digits and its power of ten (`123e46`). A key that ends another leaf's path too keeps the keys above it (`items_id` beside `id`). A Hash outcome is named by the fewest leaves, nested ones too, that tell its siblings apart (`returns__due_cents_0__discount_100`), the same leaves in both formats, or by its keys when it has no sibling. A test emitted outside the target's directory tree requires the target by absolute path, unless `--require-by-name` is given and an `-I` or `--require` directory holds it. A target that a `--require` file already loads gets no require of its own.

An RSpec file describes the constant, then `.method` or `#method`. The receiver is a `let`, each setup call a `before`, and inputs that start with the same receiver, calls, or argument values share a `context`. An example says its outcome first, then the argument values of its own, so `rspec --format documentation` reads like a spec. A value inside an argument is named by its path (`args[0].value is 7`). A context says only the values that tell it from its siblings. No text is longer than 80 characters: a longer example says only the values that tell it apart, by their deepest key (`when status is "timeout"`), or by the keys above it too when another leaf ends in the same key (`when result.status is "timeout"`), and a long String is cut where it parts from its siblings. An example still over 80 characters cuts its outcome, not those values (`returns ["require \"shop\"",... when target_path is "app/cart.rb"`). An outcome over 40 characters that is a String or an Array of scalars shows its start, then is cut (`returns ["require_relative \"../lib/shop/cart...`). A text with a double quote is written in single quotes, so it needs no escape, even when a String value in it shows its own backslashes (`'returns 1 when x is "say \"hi\""'`).

```text
Arithmetic
  .classify
    returns :miss when x is 0, y is 0 and z is 0
    returns :miss when x is 114514, y is 0 and z is 0
    when x is 138
      returns :x_only when y is 0 and z is 0
      when y is 143
        returns :need_z when z is 0
        returns :hit when z is 7
```

A method that takes no argument in any input becomes the `subject`. An input that raised keeps its setup calls inside the `expect` block, so a raise from setup is still pinned. A minitest path uses `--format minitest` and runs with `ruby`. An RSpec file needs the `rspec` gem.

## Inside a test suite (Rails)

Most methods of a Rails app run only inside its suite, with the app booted, the database, factories, and a transaction per test. `Branchout.explore` runs from inside a test and returns the report the CLI prints.

```ruby
# Gemfile
group :test do
  gem "branchout", require: false
end
```

In `spec/rails_helper.rb` or `test/test_helper.rb`, right after the line that loads `config/environment`:

```ruby
require_relative "../config/environment"
require "branchout/coverage" if ENV["BRANCHOUT"]
```

By then Rails and the gems are loaded, and the models load later, on first use, so Coverage instruments only the app's code. Set up before Rails, it instruments every gem too: a Rails suite's model tests then took about 25% longer, and after `config/environment` the difference was within noise. When the test environment eager-loads (`config.eager_load`, which Rails sets from `ENV["CI"]`), the models load inside `config/environment`, and explore refuses them; run without eager loading. In a suite without Rails, make it the first line of the helper, before the app's files load.

```ruby
# spec/models/loan_explore_spec.rb
require "rails_helper"
require "branchout"

RSpec.describe Loan do
  it "explores approve", if: ENV["BRANCHOUT"] do
    officer = {ruby: "{name: 'Grace', senior: false}"}
    puts Branchout.explore("Loan#approve", within: self, emit_tests: "spec/models/loan_approve_spec.rb", inputs: [
      {receiver: {ruby: "build(:loan, amount: 500)"}, args: [officer]},
      {receiver: {ruby: "create(:loan, :approved)"}, args: [officer]}
    ])
  end
end
```

```sh
BRANCHOUT=1 bundle exec rspec spec/models/loan_explore_spec.rb
```

The inputs are the entries of an inputs file, or the file's path. Their Ruby runs in the test (`within: self`), so it reaches the suite's factories, fixtures, and helpers. When ActiveRecord is loaded, each input runs in a savepoint that is rolled back: no input sees the rows another wrote, and the test's rows stay as they were. `around:` replaces that, as a lambda that takes the input as a block. The strategy is `inputs` only unless `strategies:` says otherwise, and `timeout:` is 1 second unless set (`nil` turns it off). `target:`, `emit_tests:`, `format:`, `json:`, `pin_keys:`, `requires:`, `seed:`, `random:`, and `mutate_cap:` mean what the CLI flags mean. In minitest the same call goes in a test of an `ActiveSupport::TestCase`, run with `BRANCHOUT=1 bin/rails test`.

The emitted test requires the helper the suite loaded (`rails_helper`, else `test_helper`, else `spec_helper`) by name. A suite that loaded none of them names its helper in `requires:`, or `emit_tests:` is refused. It does not require the model, which the app loads. A minitest test inherits from the exploring test's base class, such as `ActiveSupport::TestCase`. rspec puts the project's `spec` and `lib` on the load path itself, so the `# Load path:` comment of an RSpec file does not name them. Run it as any other test, without `BRANCHOUT`.

Coverage counts a file only when the file loads after `branchout/coverage`. A target that loaded earlier is refused, not loaded again, because loading a model again declares its validations a second time. Coverage that another tool, such as SimpleCov, started is refused too. An input's Ruby must not read a local of the exploring example, and an input that reads a `let` or `subject` is refused: the emitted file has neither, and a `let` read first inside an input would be made in its rolled-back savepoint and kept for the next input.

The CLI can load the app with `RAILS_ENV=test` and `--require config/environment.rb`, but then each input's rows stay in the test database, later inputs see them, and the test's helpers are not there.

## How it builds the frontier

branchout loads the `--require` files and then the target after `Coverage.setup(lines: true, branches: true)` and discards the counts from loading. A target that a `--require` file already loaded, with `require` or with `Kernel#load` as Rails loads an initializer, is not loaded again. For each input it resumes coverage, calls the method, suspends coverage, and reads `Coverage.result`. It keeps the entry method and same-file callees reached by a bare call or `self.`. A class method that builds its own instance, as in `def self.apply(doc) = new(doc).apply`, is followed into `initialize` and the instance method it calls, also through `tap(&:parse)` or `then(&:parse)`.

A method in another file is not counted, so its arms are not in `arms_total`. When a check moves from a subclass's method into a parent class's helper, the total gets smaller while the logic stays the same. `NOT COUNTED` names each such callee: a method that the counted code calls by a bare call or `self.` and that Ruby finds in another file, such as a parent class or a mixin, and a method it calls on an object it builds with `Const.new`, kept in a local (`journal = Ledger.new`) or in an instance variable that a method of the class sets (`@ledger = Ledger.new` in `initialize`). Each entry has `callee` (`Register#required_sku`), `loc` (the file and line of its `def`), and `arms` (the branch arms in that `def`, or `unknown` when its file loaded before coverage started or the method has no `def`, as with `define_method`). Explore the callee as its own entry to cover those arms. Methods of an installed gem or of Ruby's own library are not listed, because an app cannot move a check into one: a Rails model calls dozens of them, such as an association reader or `update!`. Methods written in C, Ruby's own prelude methods, attribute readers and writers, methods with no arms, and calls on an object whose class the code does not show are not listed.

An arm id is `kind@line:column/arm@line:column`, from the Coverage branch key. Columns are 0-based. `cond` is the Prism predicate. For a `when` or `in` arm it is that line. If the locations do not match, the source line is used.

The frontier is every arm whose count is 0. `parent: reached` means some input executed that decision. `nearest` is the one that reached it with the fewest taken arms, then the smallest weight (absolute numeric size, plus string and container length), then the smallest canonical JSON. `path` is the sorted set of arms that input took. Coverage does not record order. A loop count greater than 1 is written as `*count`.

`sense` is the direction that selects the arm: `cond-true` (`if` then, `unless` else), `cond-false` (`if` else, `unless` then), `arm-matched` (that `when` or `in`), `arm-else`, `body-entered` (`while` or `until` body), `receiver-present`, or `receiver-nil` (`&.`).

Exceptions are listed apart from arm coverage. A covered arm can still raise. The same inputs, flags, and CRuby produce the same stdout. An input equal to an earlier one runs once, and stderr says how many repeated. The report has no timestamps. Paths are relative to the working directory.

## Install

Ruby 3.3 or newer. Exploring uses Coverage, Prism, and json from the standard library. Add `gem "branchout", group: :test, require: false` to a Gemfile and run `bundle exec branchout`, or, from this checkout, run `ruby bin/branchout`, or put `bin` on `PATH`. Emitted minitest files run under `ruby`. Emitted RSpec files need the `rspec` gem. Outside a bundle, `bin/branchout` activates the newest installed prism that every installed gem accepts, so a target that requires minitest 6 (prism ~> 1.5) still loads when a newer prism is installed.

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

- The target runs. Its stdout and stderr, at load time and in each call, are discarded. Files, globals, and the network are not sandboxed.
- The target loads into branchout's own process. A target or `--require` file that loads another checkout of branchout is refused, because it would replace the tool's classes. To explore branchout's own code, run that checkout's `bin/branchout`. When an argument names one of its own files, it sets coverage up before it loads itself, so that coverage measures the file without loading it again. A file that loaded before coverage was set up, such as one of Ruby's own library, is refused: loading it again would define its classes a second time, and an object built from the first ones would no longer be one of them.
- The entry must be defined in the target file, under its constant or under a superclass declared in the same file. An inherited entry follows the subclass's overrides, as Ruby does.
- A method that depends on time, randomness, or I/O will not produce a stable report.
- A path is a set of arms, not an order. `&&` and `||` are not arms. `while` and `until` record a body arm; a condition that ran but did not enter the body is recovered from the line count.
- A modifier `unless` can put `then` and `else` at the same location. The arm name in the id distinguishes them.
- Only a bare call, a `self.` call, and a call on a bare `new(...)` in the same file are followed. A call on another receiver, such as `Other.new.check(x)`, is not. When the entry reaches no arm, `explore` warns on stderr; target the method that branches instead. `--emit-tests` still pins each input's return value or error.
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

`test/run_all.rb` loads `test/test_*.rb` and `test/generated/*_test.rb`. The property tests use hegeltest, which needs Ruby 3.4 or newer. On Ruby 3.3, run `BUNDLE_WITHOUT=property bundle install`, and they report one skip. `spec/generated/` is the emitted RSpec for `examples/`. Coverage is process-global, so each CLI test runs branchout in a process of its own, forked from a preloaded server where fork exists.

## License

MIT

---

[Japanese](README.ja.md)
