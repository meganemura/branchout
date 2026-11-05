# branchout

branchout runs a Ruby method on many inputs, shows the branch arms that no input took, and writes RSpec or minitest examples that pin what the method does now.

## Quick start in your Rails app

These steps add branchout to a Rails app that tests with RSpec and factories, and explore one model method inside the suite, with the app booted and the test database.

Pick a first target: a model method with two to five `if`, `unless`, or `case` arms that returns a value, on a model that has a factory. A method that a recent commit changed is a good start. `git log -5 --oneline -- app/models` lists those commits.

1. Add the gem to the test group of your Gemfile, and install it:

```ruby
group :test do
  gem "branchout", require: false
end
```

```sh
bundle install
```

2. Write one spec file that explores the method. Replace `Loan`, `approve`, the factory call, the argument, and the two file names with yours. The receiver and each argument are Ruby source in a String:

```ruby
# spec/models/loan_explore_spec.rb
require "branchout/coverage" if ENV["BRANCHOUT"]
require "rails_helper"
require "branchout"

RSpec.describe Loan, type: :model do
  it "explores approve", if: ENV["BRANCHOUT"] do
    clerk = {ruby: "{name: 'Grace', senior: false}"}
    puts Branchout.explore("Loan#approve", within: self, emit_tests: "spec/models/loan_approve_spec.rb", inputs: [
      {receiver: {ruby: "create(:loan)"}, args: [clerk]}
    ])
  end
end
```

The first line starts coverage before `rails_helper` boots the app, so that branchout can count the arms of the model's file. A helper that starts SimpleCov can stay as it is: branchout takes over coverage for this run. Without `BRANCHOUT` the example is skipped, so the file can stay in the suite. Each input runs in a savepoint that is rolled back, so no input sees the rows of another.

3. Run it:

```sh
BRANCHOUT=1 bundle exec rspec spec/models/loan_explore_spec.rb
```

### What you will see

This output is from a small sample app, where the method is:

```ruby
  def approve(officer)
    return :already if state == "approved"
    return :over_limit if borrower.approved_cents + amount_cents > borrower.limit_cents
    return :needs_senior if amount_cents > 10_000 && !officer.fetch(:senior)

    update!(state: "approved", approved_by: officer.fetch(:name))
    :approved
  end
```

```text
branchout explore app/models/loan.rb Loan#approve
covered: 3 of 6 arms by 1 input
raised: none
tests: spec/models/loan_approve_spec.rb

FRONTIER (add an input like the nearest above each arm, changed as the arm says)
nearest: {"args":[{"ruby":"{name: 'Grace', senior: false}"}],"receiver":{"ruby":"create(:loan)"}}
app/models/loan.rb:7:4 makes `state == "approved"` true
app/models/loan.rb:8:4 makes `borrower.approved_cents + amount_cents > borrower.limit_cents` true
app/models/loan.rb:9:4 makes `amount_cents > 10_000 && !officer.fetch(:senior)` true

OPERATORS (coverage does not see which side ran; vary each left side)
app/models/loan.rb:9:50 && in `amount_cents > 10_000 && !officer.fetch(:senior)`

Pass verbose: true for every covered arm and the run settings.
.

Finished in 0.28375 seconds (files took 2.14 seconds to load)
1 example, 0 failures
```

The one input took 3 of the 6 arms. Each line under `FRONTIER` is an arm that no input took, at its file, line, and column, and says what an input must do to take it. `nearest` is the input that came closest, so copy it and change it as the line says. `OPERATORS` names an `&&` whose sides coverage does not count, so give inputs that make its left side true and false. The run also wrote `spec/models/loan_approve_spec.rb`, which pins what each input returned.

### Next: close the frontier

Add one input for each `FRONTIER` entry, and run step 3 again. In the sample app a borrower's limit is 20,000 cents:

```ruby
# spec/models/loan_explore_spec.rb
require "branchout/coverage" if ENV["BRANCHOUT"]
require "rails_helper"
require "branchout"

RSpec.describe Loan, type: :model do
  it "explores approve", if: ENV["BRANCHOUT"] do
    clerk = {ruby: "{name: 'Grace', senior: false}"}
    puts Branchout.explore("Loan#approve", within: self, emit_tests: "spec/models/loan_approve_spec.rb", inputs: [
      {receiver: {ruby: "create(:loan)"}, args: [clerk]},
      {receiver: {ruby: "create(:loan, :approved)"}, args: [clerk]},
      {receiver: {ruby: "create(:loan, amount_cents: 25_000)"}, args: [clerk]},
      {receiver: {ruby: "create(:loan, amount_cents: 15_000)"}, args: [clerk]}
    ])
  end
end
```

```sh
BRANCHOUT=1 bundle exec rspec spec/models/loan_explore_spec.rb
```

```text
branchout explore app/models/loan.rb Loan#approve
covered: 6 of 6 arms by 4 inputs
raised: none
tests: spec/models/loan_approve_spec.rb

FRONTIER
(none)

OPERATORS (coverage does not see which side ran; vary each left side)
app/models/loan.rb:9:50 && in `amount_cents > 10_000 && !officer.fetch(:senior)`

Pass verbose: true for every covered arm and the run settings.
.

Finished in 0.35302 seconds (files took 0.98271 seconds to load)
1 example, 0 failures
```

Every arm is covered. The emitted spec runs as any other spec, without `BRANCHOUT`:

```sh
bundle exec rspec spec/models/loan_approve_spec.rb --format documentation
```

```text
Loan
  #approve
    with create(:loan)
      returns :approved
    with create(:loan, :approved)
      returns :already
    with create(:loan, amount_cents: 15_000)
      returns :needs_senior
    with create(:loan, amount_cents: 25_000)
      returns :over_limit

Finished in 0.04388 seconds (files took 0.93715 seconds to load)
4 examples, 0 failures
```

Commit the emitted spec: it fails when what the method returns changes. Keep the explore spec for the next round, or delete it. A coding agent runs the same loop: it reads `FRONTIER`, appends an input, and reruns. [skills/branchout/SKILL.md](skills/branchout/SKILL.md) is that procedure, and [Inside a test suite](#inside-a-test-suite) has every option of `Branchout.explore`.

## Try it without an app

The CLI explores a method that loads without an app, such as a module under `lib/`, from its file.

Install the gem, and RSpec to run what it writes:

```sh
gem install branchout rspec
```

In an empty folder, write a method with a few branches:

```sh
cat > shipping.rb <<'RUBY'
module Shipping
  def self.fee(weight, express: false)
    raise ArgumentError, "weight must be positive" unless weight.positive?

    base = weight <= 2 ? 5 : 5 + (weight - 2) * 2
    express ? base * 2 : base
  end
end
RUBY
```

Explore it and write the specs:

```sh
branchout explore shipping.rb Shipping.fee --emit-tests shipping_spec.rb
```

```text
branchout explore shipping.rb Shipping.fee
covered: 5 of 6 arms by 13 inputs
raised: 3 inputs
tests: shipping_spec.rb

FRONTIER (add an input like the nearest above each arm, changed as the arm says)
nearest: [1]
shipping.rb:6:14 makes `express` true

EXCEPTIONS
ArgumentError at shipping.rb:3: weight must be positive
  inputs: [-1], [-2], [0]

Pass --verbose for every covered arm and the run settings.
```

branchout ran 13 inputs that it made from the method's own literals and from a seeded sample. They took 5 of the 6 arms. `FRONTIER` is the arm that no input took: `express` was never true, so add an input like `nearest` that makes it true. `EXCEPTIONS` lists the inputs that raised. `--verbose` also prints the input that took each covered arm.

The emitted spec pins each return value and each error:

```sh
cat shipping_spec.rb
```

```ruby
# frozen_string_literal: true

# Generated by branchout 0.1.0. Characterization specs for discovered inputs.
# target: shipping.rb
# entry: Shipping.fee

require_relative "./shipping.rb"

RSpec.describe Shipping do
  describe ".fee" do
    it "raises ArgumentError when weight is -1" do
      # covers:
      #   line 3: unless weight.positive? -> then
      expect { Shipping.fee(-1) }.to raise_error(ArgumentError, "weight must be positive")
    end

    it "raises ArgumentError when weight is -2" do
      # covers:
      #   line 3: unless weight.positive? -> then
      expect { Shipping.fee(-2) }.to raise_error(ArgumentError, "weight must be positive")
    end

    it "raises ArgumentError when weight is 0" do
      # covers:
      #   line 3: unless weight.positive? -> then
      expect { Shipping.fee(0) }.to raise_error(ArgumentError, "weight must be positive")
    end

    it "returns 5 when weight is 1" do
      # covers:
      #   line 3: unless weight.positive? -> else
      #   line 5: weight <= 2 ? 5 : 5 + (weight - 2) * 2 -> then
      #   line 6: express ? base * 2 : base -> else
      expect(Shipping.fee(1)).to eq(5)
    end

    it "returns 7 when weight is 3" do
      # covers:
      #   line 3: unless weight.positive? -> else
      #   line 5: weight <= 2 ? 5 : 5 + (weight - 2) * 2 -> else
      #   line 6: express ? base * 2 : base -> else
      expect(Shipping.fee(3)).to eq(7)
    end
  end
end
```

```sh
rspec shipping_spec.rb
```

```text
.....

Finished in 0.00334 seconds (files took 0.07131 seconds to load)
5 examples, 0 failures

```

Next, close the frontier. Write an input that takes the missing arm into an inputs file, and run the same command with `--inputs`:

```sh
cat > inputs.json <<'JSON'
{"inputs": [{"args": [3], "kwargs": {"express": true}}]}
JSON
branchout explore shipping.rb Shipping.fee --inputs inputs.json --emit-tests shipping_spec.rb
```

```text
branchout explore shipping.rb Shipping.fee
covered: 6 of 6 arms by 14 inputs
raised: 3 inputs
tests: shipping_spec.rb

FRONTIER
(none)

EXCEPTIONS
ArgumentError at shipping.rb:3: weight must be positive
  inputs: [-1], [-2], [0]

Pass --verbose for every covered arm and the run settings.
```

```sh
rspec shipping_spec.rb --format documentation
```

```text
Shipping
  .fee
    raises ArgumentError when weight is -1
    raises ArgumentError when weight is -2
    raises ArgumentError when weight is 0
    returns 5 when weight is 1
    returns 14 when weight is 3 and express is true

Finished in 0.00228 seconds (files took 0.07051 seconds to load)
5 examples, 0 failures
```

Every arm is covered now. The emitted spec keeps each input of the inputs file, and one input for each other arm and each error. Keep the spec beside the code: it fails when the method's behavior changes. A coding agent runs the same loop: it reads `FRONTIER`, appends an input, and reruns. [skills/branchout/SKILL.md](skills/branchout/SKILL.md) is that procedure.

## CLI reference

A coding agent adding tests can see that a branch was missed and still not know which comparison failed, or which input came closest. branchout prints that frontier: the condition, the direction that selects the arm, and the nearest input that reached the decision. The agent appends an input and reruns the same command. branchout does not edit the inputs file. When the search stops, it writes a minitest or RSpec example that pins each discovered return value or exception.

The method follows concolic testing ([DART](https://doi.org/10.1145/1065010.1065036), [CUTE](https://doi.org/10.1145/1094811.1094816)) and LLM-guided concolic work such as [ConcoLLMic](https://concollmic.github.io/). branchout is inspired by concolic testing but does no symbolic solving. The agent proposes inputs from the branch frontier.

From a checkout of this repository, `ruby bin/branchout` runs the same command as `branchout`. The seed file holds one input, `[0]`. `--verbose` prints the whole report: the run settings and counts, then `COVERED` (the input that took each arm), `FRONTIER` (each arm no input took, with `path`, the arms `nearest` took), `EXCEPTIONS` (one record for each input that raised), `NOT COUNTED`, and `OPERATORS`. Without it, the report keeps the counts, the `FRONTIER` arms that an input reached, one line each under the `nearest` input to change, one line for each decision that no input reached, and one line for each error, as in [Try it without an app](#try-it-without-an-app). `--json` holds every field of the whole report.

```sh
ruby bin/branchout explore examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.seed.json \
  --strategy inputs \
  --random 0 \
  --seed 1 \
  --verbose
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
operators_not_counted: 0

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

OPERATORS
(none)
```

`sense: cond-true` on `x == 114514` is the arm `[0]` did not take. Append `[114514]` and rerun the same command. `examples/inputs/magic_value.json` is that file. It reports `arms_covered: 2` and `FRONTIER` `(none)`.

`ENTRY` is `Const.method` or `Const#method`. A method under `module_function` or in a module that calls `extend self` is `Const.method`. For `Const#method`, each input gets its own receiver from `Const.new`. If `initialize` takes arguments, put them in `new` on each input, in the same shape as an input: `{"args": [5], "new": [10]}` calls `Const.new(10).method(5)`. A `new` of keywords only may leave out `args`: `{"args": [5], "new": {"kwargs": {"main": 1}}}` calls `Const.new(main: 1).method(5)`. When the state the method reads comes from calls after `new`, list them in `setup`, in order: `{"args": [], "setup": [{"method": "add", "args": ["apple", 3]}]}` calls `add("apple", 3)` on the new receiver and then the method. Each step takes `method`, `args`, and `kwargs`. Coverage counts only the call to the method, not `new` or `setup`. When the target file defines `initialize`, `mutate` and `random` fill `new` from its parameters too. `--entry ENTRY` may replace the positional entry.

While searching, pass `--strategy inputs --random 0` and keep `--seed` fixed, so a new covered arm comes from an input you added. The search procedure is in [skills/branchout/SKILL.md](skills/branchout/SKILL.md).

| Flag | Default | Meaning |
| --- | --- | --- |
| `--inputs PATH` | none | JSON file of inputs |
| `--require PATH` | none | Load PATH before the target, for a target that needs the rest of its library. Repeatable. PATH's directory joins the end of the load path, after the gems, so `lib/name.rb` can `require "name/part"`, and `config/puma.rb` beside `config/environment.rb` does not hide the puma gem. A PATH that names no file under the working directory is a feature, as `ruby -r` reads it: `--require shop -I lib` loads `lib/shop.rb`, and a name that no `-I` directory holds is looked up on the load path. Emitted tests require PATH too |
| `-I DIR` | none | Put DIR on the load path while exploring, as `ruby -I` does. Repeatable. With `--require-by-name`, a file under DIR is required by its name from DIR, such as a Rails model under `app/models` |
| `--seed N` | `0` | RNG seed |
| `--random N` | `16` | Number of random samples |
| `--mutate-cap N` | `256` | Literal-mutation budget |
| `--strategy LIST` | `inputs,mutate,random` | Comma-separated strategies, in the order below |
| `--timeout SEC` | `1` | Per-input timeout. Must be > 0 |
| `--verbose` | off | Print the whole text report: the run settings, every covered arm, and each frontier arm's `path`. `explore` only. Refused with `--json`, which always holds all of it |
| `--json` | off | Print JSON on stdout instead of the text report |
| `--json-out PATH` | | Write the JSON report |
| `--md-out PATH` | | Write the text report that `--verbose` prints, as Markdown |
| `--emit-tests PATH` | | Write characterization tests. `explore` only |
| `--format NAME` | `minitest` | `minitest` or `rspec`. Requires `--emit-tests`. If omitted, a path ending in `_spec.rb` selects RSpec |
| `--pin-keys LIST` | | Comma list of keys. A returned Hash pins only these keys (`slice` in minitest, `include` in RSpec), so a key added later fails no test. Requires `--emit-tests` |
| `--require-by-name` | off | Emitted tests `require` the `--require` files and the target through the load path, named from the first `-I` directory or `--require` file's directory that holds each (`require "shop/cart"`). With neither, named from the nearest `lib` directory above the target, or the target's own directory. A file that no such directory holds is required by path, with a comment above it and a line on stderr that say so. A `# Load path: -I lib` comment above the requires names each directory the test needs on the load path; an RSpec file leaves out `spec` and `lib`, which rspec adds itself. Requires `--emit-tests`. A test emitted under a `.jitcatch` directory gets this without the flag: jitcatch copies it into each checkout, and its rerun line loads it where it was written, so a `require_relative` would load another file from each place |
| `--entry ENTRY` | the positional argument | `Const.method` or `Const#method` |

| Strategy | What it runs |
| --- | --- |
| `inputs` | Entries in the inputs file. Duplicate canonical JSON is dropped |
| `mutate` | Each source literal, tried in each argument slot. Integers also include `0`, `1`, `-1`, and literal±1. Floats also include `0.0`, `1.0`, `-1.0`, and ±1. Strings also include `""`, `"a"`, the literal without its last character, and the literal plus `"1"`. When the first two positional parameters are numeric, those slots also get a cartesian product, cut by `--mutate-cap`. String literals are not concatenated. The literals are those of the entry and of each method it calls in the same file, and a constant the file sets to a literal (`HOLD = "sanctions"`) counts as that literal. A slot's type comes from the same methods: an argument passed to a helper takes the type the helper's use of its parameter gives (`held?(reason)` with `def held?(text) = text == HOLD` makes `reason` a String), and `doc["key"]` or `doc.dig(:key)` makes `doc` a Hash |
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

An entry may be a bare array. Keywords go in `kwargs`, constructor arguments go in `new`, and calls that build the receiver's state go in `setup`. A receiver that `new` cannot build, such as a saved record, is Ruby in `receiver`: `{"receiver": {"ruby": "Factories.loan(3)"}, "args": [{"ruby": "loan.amount"}]}`. The receiver takes the name the emitted test gives it, the class in snake case, so the arguments and `setup` can read from it. If type inference is wrong, set `"types"` to one of `int`, `float`, `string`, `array`, `hash`, or `bool` per positional parameter. A default value of `[]`, `{}`, `true`, or `false` gives its type, and `bool` makes mutation and random sampling try both `false` and `true`. Other top-level keys, such as `meta`, are ignored, and so is a `note` on an entry, which keeps the reason for that input beside it. An entry's `pin_keys` (`{"args": [3], "pin_keys": ["tax"]}`) replaces `--pin-keys` for that input's test, and `"pin_keys": []` pins its Hash whole. A value JSON cannot write, such as a record or an exception, is Ruby in `{"ruby": "..."}`, often a factory in a `--require` file: `{"args": [{"ruby": "Factories.loan(3)"}]}`. Each call evaluates it again at the top level, and the emitted tests write it as given (`Lending.approve(Factories.loan(3))`). A block the method takes goes in `block`, with braces: `{"args": [5], "block": "{ |amount| amount > 2 }"}`. A Hash argument whose one key is `"ruby"` is written as Ruby too: `{"ruby": "{\"ruby\" => \"3.4\"}"}`. A String that names a path under the emitted test's project (the nearest directory above the test with a `Gemfile`, a gemspec, or `.git`) is written from the test's own directory, `File.expand_path("../fixtures/files/rates.csv", __dir__)`, so the test passes in any checkout of the project, a jitcatch copy too. Its name and description say the path from the project root (`spec/fixtures/files/rates.csv`). A path under the temporary or the home directory and outside the project stays as written, and stderr names it: one that exists, since the test passes only on this machine, and one that does not, since the test still holds this machine's directories. Put such a path under the project, for example in `spec/fixtures/files`. A returned value or an error message that holds a path under the project names the project root from the test's own directory too (`"No such file or directory @ rb_sysopen - #{File.expand_path("..", __dir__)}/spec/fixtures/none.csv"`). One that holds a path of this machine outside the project stays as written, and stderr names it. A test name or description says a path under the temporary or the home directory by its file alone, so it is the same on every machine. Append entries. Do not delete or reorder them.

```sh
ruby bin/branchout explore examples/hidden_bug.rb HiddenBug.scale \
  --inputs examples/inputs/hidden_bug.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests spec/generated/hidden_bug_spec.rb \
  --format rspec
```

That run covers 4 of 4 arms and records `ZeroDivisionError` (`divided by 0`) for `[24,12]`. The emitted file pins each return value, or the exception class and message, a message over several lines as it was raised. Each test starts with a `# covers:` list of the arms its input took, one per line, as the condition's line, the condition as written, and the arm (`line 20: unless rate.is_a?(Numeric) -> else`, `line 9: elsif tag.start_with?("beta") -> then`). A ternary is written whole (`line 10: label ? :noted : :plain -> then`), and a `case` arm sits on its own `when`, `in`, or `else` line, which names it (`line 6: when 1, 2 then :low`). A `NameError` or `NoMethodError` is pinned by its class and missing name (`error.name`), because Ruby 3.4 reworded their messages. A message that quotes a backtrace frame (`lib/x.rb:3:in 'Box.run'`) is matched by a Regexp that accepts the frame's label in either form, because Ruby 3.4 changed labels from `` `run' `` to `'Box.run'`. So is a returned String that quotes one, such as a `raised in:` line. A `Set` is pinned by its members (`Set[1, 2]`). A return value with no Ruby literal, such as an `Object`, is pinned by its class only. In RSpec a `Struct` or `Data` value is pinned by its class and members, and an Array or Hash that holds one item by item (`match([a_kind_of(Rule).and(have_attributes(action: "borrow"))])`); minitest pins a `Struct` by its class only. An expected Hash keeps the value's own key order, so a failure diff lines up key by key. A private or protected entry, and a private `new`, are called through `send`, as `explore` called them. A String argument is a plain literal, which the file's `frozen_string_literal` freezes, and `explore` passes it frozen as well. An input that raises `FrozenError` with frozen Strings, and not with unfrozen ones, keeps the unfrozen run: its test writes each String as `+"..."` under a comment that says so. That run came second, so it saw what the first run changed before it raised: a savepoint undoes rows, but no run undoes a global, a class variable, or a file. The comment says this too. Run the emitted test on its own to check that value. A class or module that `private_constant` hides is reached through `const_get` (`Shop.const_get(:Ledger)`), and the RSpec describe names it as a string. A minitest test is named after its input and outcome, such as `test_24_12_raises_zero_division_error`. Inputs whose names would be the same are named by the values that differ between them, such as `test_status_timeout_and_error_class_timeout_returns_ok`, so adding an input can rename those. Strings that share their start are named from the words where they part. Ruby source that shares its start, such as two factory calls in `receiver`, keeps the word before they part (`test_limit_100_returns_ok`). A name is cut between words, a blank string shows as `blank`, an empty Array or Hash argument as `empty_array` or `empty_hash`, and a Hash argument is named by its values. A collection in a Hash argument is named by its key and size (`groups_3`, `tags_empty`), and an Array of collections by its size (`array_of_2`). An Array that holds scalars and collections says `array`, then each scalar and the keys of each Hash (`returns [:ok, a Hash of id, name]`, `returns_array_ok_hash_id_and_name`), so `["Done", []]` is not named as the String `"Done"` (`returns_array_done_empty_array`). A number of more than 15 digits is named by its first three digits and its power of ten (`123e46`). A key that ends another leaf's path too keeps the keys above it (`items_id` beside `id`). A Hash outcome is named by the fewest leaves, nested ones too, that tell its siblings apart (`returns_due_cents_0_and_discount_100`), the same leaves in both formats, or by its keys when it has no sibling (`returns_hash_lines_and_discount_cents`). Each key after the first comes after `and`, and a cut never splits a key. An Array of scalars says `array` (`[nil]` is `returns_array_nil`), and a String or a Symbol that reads as `nil`, `true`, or `false` says `text` (`returns_text_nil`). A Hash key that reads so says `key` (`returns_key_nil_0` for `{"NIL" => 0}`). A test emitted outside the target's directory tree requires the target by absolute path, unless `--require-by-name` is given and an `-I` or `--require` directory holds it. When a test requires a file by its path from out of its own project (the nearest directory with a `Gemfile`, a gemspec, or `.git`), by absolute path or by a climb into another project, stderr warns that the test runs only where that file sits on this machine, and names the fix. A target that a `--require` file already loads gets no require of its own.

An RSpec file describes the constant, then `.method` or `#method`. The receiver is a `let`, each setup call a `before`, and inputs that start with the same receiver, calls, or argument values share a `context`. An example says its outcome first, then the argument values of its own, so `rspec --format documentation` reads like a spec. A value inside an argument is named by its path, and an Array of scalars as a whole (`items is [1, 2]`). A path writes a String key quoted and a Symbol key bare, so a String-keyed Hash such as Rails params does not read as a Symbol lookup: the JSON input `[{"sku": "B"}]` reads `items[0]["sku"] is "B"`, and the Ruby literal `{"ruby": "[{sku: \"B\"}]"}` reads `items[0].sku is "B"`. Ruby in `{"ruby": ...}` that is a plain literal is named by its value in this way, in both formats. A Hash outcome writes each key as its literal does (`returns "state" => "open"`, `returns due_cents: 0`), and a nested leaf under a String key as the literal that holds it, with the leaves under one key in one literal (`returns "counts" => {"discarded" => 1}`, `returns "tests" => [{"file" => "a_spec.rb", "disposition" => "flaky"}]`). A context says only the values that tell it from its siblings. No text is longer than 80 characters: a longer example says only the values that tell it apart, by their deepest key (`when status is "timeout"`), or by the keys above it too when another leaf ends in the same key (`when result.status is "timeout"`). A String key is named with the argument and the literal that holds the leaf (`when doc holds "status" => "timeout"`, `when doc holds "result" => {"status" => "timeout"}`), since `doc["status"]` would name another leaf, and a long String is cut where it parts from its siblings, and ends before a word the cut would split. An example still over 80 characters cuts its outcome, not those values (`returns ["require \"shop\"",... when target_path is "app/cart.rb"`). An outcome over 40 characters that is a String or an Array of scalars shows its start, then is cut (`returns ["require_relative \"../lib/shop/cart...`). A text with a double quote is written in single quotes, so it needs no escape, even when a String value in it shows its own backslashes (`'returns 1 when x is "say \"hi\""'`).

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

## Inside a test suite

`Branchout.explore` runs from inside a test and returns the report the CLI prints. [Quick start in your Rails app](#quick-start-in-your-rails-app) shows the Gemfile line and one explore spec. The spec's first line, `require "branchout/coverage" if ENV["BRANCHOUT"]`, sets up Coverage before the helper boots the app, so the models load after it. In minitest it goes before `require "test_helper"`. In a suite without Rails it works the same way.

Run the explore file alone: in a run of the whole suite, another spec file can load the model first. When `.rspec` requires `rails_helper`, the app boots before the spec's first line, so a model that an initializer reads, or every model when the test environment eager-loads (`config.eager_load`, which Rails sets from `ENV["CI"]`), loads too early, and explore refuses it. Set up before Rails, Coverage measures every gem too. In the sample app of the Quick start, the explore run took about 0.3 seconds longer to boot and about 12 ms longer for each input than with the line in `spec/rails_helper.rb`, right after the line that loads `config/environment`. That placement is the faster one when nothing loads a model during boot: the gems are loaded by then, and the models load later, on first use.

The inputs are the entries of an inputs file, or the file's path. Their Ruby runs in the test (`within: self`), so it reaches the suite's factories, fixtures, and helpers. When ActiveRecord is loaded, each input runs in a savepoint that is rolled back: no input sees the rows another wrote, and the test's rows stay as they were. `around:` replaces that, as a lambda that takes the input as a block. An input that raises `FrozenError` with frozen Strings runs again with unfrozen ones only when it ran in `Branchout::ROLL_BACK`, the default or inside an `around:` that calls it. With any other `around:`, such as `Branchout::RUN_ONLY`, the `FrozenError` is pinned, because branchout cannot tell whether that around undid the first run's rows. The strategy is `inputs` only unless `strategies:` says otherwise, and `timeout:` is 1 second unless set (`nil` turns it off). `target:`, `emit_tests:`, `format:`, `json:`, `verbose:`, `pin_keys:`, `requires:`, `seed:`, `random:`, and `mutate_cap:` mean what the CLI flags mean. In minitest the same call goes in a test of an `ActiveSupport::TestCase`, run with `BRANCHOUT=1 bin/rails test`.

The emitted test requires the helper the suite loaded (`rails_helper`, else `test_helper`, else `spec_helper`) by name. A suite that loaded none of them names its helper in `requires:`, or `emit_tests:` is refused. `requires:` takes one path as a String, or a list of paths. A `requires:` entry that names no file is found on the load path, and one found nowhere stops with `requires: "spec/helper" names no file under the working directory or on the load path`. It does not require the model, which the app loads. A minitest test inherits from the exploring test's base class, such as `ActiveSupport::TestCase`. An RSpec file gives its `describe` the exploring example group's `type`, such as `type: :model`. rspec puts the project's `spec` and `lib` on the load path itself, so the `# Load path:` comment of an RSpec file does not name them. Run it as any other test, without `BRANCHOUT`.

Coverage counts a file only when the file loads after `branchout/coverage`. A target that loaded earlier is refused, not loaded again, because loading a model again declares its validations a second time. A suite that starts SimpleCov in its helper, before or after `branchout/coverage`, needs no change: branchout measures the run, and SimpleCov reports 0% for it, because explore clears the counts after each input. An input's Ruby must not read a local of the exploring example, and an input that reads a `let` or `subject` is refused: the emitted file has neither, and a `let` read first inside an input would be made in its rolled-back savepoint and kept for the next input.

The CLI can load the app with `RAILS_ENV=test` and `--require config/environment.rb`, but then each input's rows stay in the test database, later inputs see them, and the test's helpers are not there.

## How it builds the frontier

branchout loads the `--require` files and then the target after `Coverage.setup(lines: true, branches: true)` and discards the counts from loading. A target that a `--require` file already loaded, with `require` or with `Kernel#load` as Rails loads an initializer, is not loaded again. For each input it resumes coverage, calls the method, suspends coverage, and reads `Coverage.result`. It keeps the entry method and same-file callees reached by a bare call or `self.`. A class method that builds its own instance, as in `def self.apply(doc) = new(doc).apply`, is followed into `initialize` and the instance method it calls, also through `tap(&:parse)` or `then(&:parse)`.

A method in another file is not counted, so its arms are not in the total, the `M` of `covered: N of M arms` (`arms_total` in `--verbose` and `--json`). When a check moves from a subclass's method into a parent class's helper, the total gets smaller while the logic stays the same. `NOT COUNTED` names each such callee: a method that the counted code calls by a bare call or `self.` and that Ruby finds in another file, such as a parent class or a mixin, and a method it calls on an object it builds with `Const.new`, kept in a local (`journal = Ledger.new`) or in an instance variable that a method of the class sets (`@ledger = Ledger.new` in `initialize`). Each entry has `callee` (`Register#required_sku`), `loc` (the file and line of its `def`), and `arms` (the branch arms in that `def`, or `unknown` when its file loaded before coverage started or the method has no `def`, as with `define_method`). Explore the callee as its own entry to cover those arms. Methods of an installed gem or of Ruby's own library are not listed, because an app cannot move a check into one: a Rails model calls dozens of them, such as an association reader or `update!`. Methods written in C, Ruby's own prelude methods, attribute readers and writers, methods with no arms, and calls on an object whose class the code does not show are not listed.

Branch coverage counts no arm for `||`, `&&`, `||=`, or `&&=`, so it cannot say whether their right side ran. A method that branches only through them, as `user&.admin? || params[:force]` does past its `&.`, would report fewer arms than it has, or `covered: 0 of 0 arms`, which reads as fully covered. `OPERATORS` lists each one in the counted code, and `operators_not_counted` counts them: `loc` (the operator's line and column), `op`, and `text` (the whole expression, cut at 160 characters). Give inputs that make each left side truthy and falsy. When the entry has no arm but has such an operator, stderr says so. `&.` has arms of its own (`receiver-present`, `receiver-nil`).

An arm id is `kind@line:column/arm@line:column`, from the Coverage branch key. Columns are 0-based. `cond` is the Prism predicate. For a `when` or `in` arm it is that line. If the locations do not match, the source line is used.

The frontier is every arm whose count is 0. `parent: reached` means some input executed that decision. `nearest` is the one that reached it with the fewest taken arms, then the smallest weight (absolute numeric size, plus string and container length), then the smallest canonical JSON. `path` is the sorted set of arms that input took. Coverage does not record order. A loop count greater than 1 is written as `*count`.

`sense` is the direction that selects the arm: `cond-true` (`if` then, `unless` else), `cond-false` (`if` else, `unless` then), `arm-matched` (that `when` or `in`), `arm-else`, `body-entered` (`while` or `until` body), `receiver-present`, or `receiver-nil` (`&.`).

Exceptions are listed apart from arm coverage. A covered arm can still raise. The same inputs, flags, and CRuby produce the same stdout. An input equal to an earlier one runs once, and stderr says how many repeated. The report has no timestamps. Paths are relative to the working directory.

## Install

Ruby 3.3 or newer. Exploring uses Coverage, Prism, and json from the standard library. `gem install branchout` installs the `branchout` command. In a project with a Gemfile, add `gem "branchout", group: :test, require: false` instead and run `bundle exec branchout`. A checkout of this repository works too: run `ruby bin/branchout`, or put `bin` on `PATH`. Emitted minitest files run under `ruby`. Emitted RSpec files need the `rspec` gem. Outside a bundle, `bin/branchout` activates the newest installed prism that every installed gem accepts, so a target that requires minitest 6 (prism ~> 1.5) still loads when a newer prism is installed.

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
- An input that raised `FrozenError` and ran again with unfrozen Strings ran in the same process as its first run, after it. A global, a class variable, or a file that the first run changed is not undone.
- The target loads into branchout's own process. A target or `--require` file that loads another checkout of branchout is refused, because it would replace the tool's classes. To explore branchout's own code, run that checkout's `bin/branchout`. When an argument names one of its own files, it sets coverage up before it loads itself, so that coverage measures the file without loading it again. A file that loaded before coverage was set up, such as one of Ruby's own library, is refused: loading it again would define its classes a second time, and an object built from the first ones would no longer be one of them.
- The entry must be defined in the target file, under its constant or under a superclass declared in the same file. An inherited entry follows the subclass's overrides, as Ruby does.
- A method that depends on time, randomness, or I/O will not produce a stable report.
- A path is a set of arms, not an order. `&&`, `||`, `||=`, and `&&=` are not arms; `OPERATORS` lists them. `while` and `until` record a body arm; a condition that ran but did not enter the body is recovered from the line count.
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
