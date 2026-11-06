---
name: branchout
description: "Explore concrete inputs that reach uncovered Ruby branch arms and emit minitest or RSpec characterization tests. Use when adding tests for under-covered Ruby branches, when exploring inputs that reach an uncovered if/unless/case/while arm, or when a Ruby method's branch coverage is still incomplete."
compatibility: Requires Ruby 3.3+ and the branchout executable. Running emitted RSpec needs the rspec gem.
---

# branchout

branchout runs one Ruby method on concrete inputs and prints the branch arms still uncovered. It does not solve constraints, call a model, or edit the inputs file. You read the frontier, append inputs, and rerun the same command.

## Install

Ruby 3.3 or newer. Exploring uses Coverage, Prism, and json from the standard library. No gem is required to explore. Outside a bundle, `bin/branchout` activates the newest installed prism that every installed gem accepts, so a target that requires minitest 6 still loads when a newer prism is installed.

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

`--strategy` is a comma list of `inputs`, `mutate`, and `random` (default: all three). `--random` defaults to 16 and `--seed` to 0. During the search, pass `--strategy inputs --random 0` and keep `--seed` fixed. The same inputs, flags, and CRuby produce the same stdout. An input equal to an earlier one runs once, and stderr says how many repeated.

Other flags: `--require PATH`, `-I DIR` (load path, repeatable), `--mutate-cap N` (default 256), `--timeout SEC` (default 1, must be > 0), `--json` (JSON on stdout instead of text), `--json-out PATH`, `--md-out PATH`, `--require-by-name` (see below).

## Inputs JSON

Start from one seed. [inputs.example.json](inputs.example.json) shows every accepted key. A real seed is usually just `inputs`; set `types` only when inference is wrong, one entry per positional parameter.

```json
{
  "inputs": [
    {"args": [0]}
  ]
}
```

- An entry is `{"args": [...]}` or a bare array. Keywords go in `kwargs`: `{"args": [0], "kwargs": {"flag": true}}`. An entry with `new`, `receiver`, `setup`, `kwargs`, `block`, or `before` may leave out `args` for a call with no positional argument.
- When the method reads rows that no argument holds, such as a record a class method finds, make them in `before`: `{"before": {"ruby": "FactoryBot.create(:part, sku: \"A\")"}, "args": ["A"]}`. It runs first, in the input's own savepoint. RSpec writes it as the `before` of the input's context, and minitest as the line before the call. Do not hide it in the argument with `.tap { ... }`, which fills the description.
- For `Const#method`, constructor arguments go in `new`, in the same shape as an entry: `{"args": [5], "new": [10]}` calls `Const.new(10).method(5)`, and `{"args": [5], "new": {"kwargs": {"main": 1}}}` calls `Const.new(main: 1).method(5)`. A required keyword of `initialize` needs `new` as a required argument does. Inputs differ by `new` too, so a method with no parameters is explored by varying `new`. When the target file defines `initialize`, `mutate` and `random` fill `new` from its parameters, in the same domains as the method's own.
- When the receiver is an object that `new` cannot build, such as a saved record from a factory, a fixture, or a test helper, give its Ruby in `receiver` in place of `new`: `{"receiver": {"ruby": "create(:loan, :approved)"}, "args": [{"ruby": "loan.borrower"}]}`. The receiver takes the name the emitted test gives it, the class in snake case (`loan`, `room`), so `args`, `kwargs`, and `setup` can read from it (`room.acts.first`). Each input builds it again. The emitted minitest test assigns that name, and the RSpec spec declares it as a `let`. A bare `create` or `build` needs `FactoryBot::Syntax::Methods` included in the suite; without it write `FactoryBot.create`. An input whose own Ruby raises before the entry runs stops explore and names the input: fix that input, since its error is not the method's.
- When the method reads state that later calls build, such as `cart.add(...)` before `cart.total`, list those calls in `setup`, in order: `{"args": [], "setup": [{"method": "add", "args": ["apple", 3]}]}`. Each step has `method` and optional `args` and `kwargs`. Coverage counts only the entry call. An exception raised in a setup call is still reported, with `loc` on that line. The emitted test names the receiver after the class (`cart = Shop::Cart.new`) and repeats the calls.
- Seeds: `[0]` int, `[0.0]` float, `[""]` string, `[[]]` array, `[{}]` hash, `[false]` bool.
- `"types"` values are `int`, `float`, `string`, `array`, `hash`, or `bool`. A default of `[]`, `{}`, `true`, or `false` already gives the type. The array length must match the positional parameters. Extra top-level keys such as `meta` are ignored. An entry may carry a `note` (`{"args": [100], "note": "the refund limit"}`), which branchout ignores; put the reason for that input there. An entry may carry `pin_keys` (`{"args": [3], "pin_keys": ["tax"]}`), which replaces `--pin-keys` for that input's test; `"pin_keys": []` pins its Hash whole.
- A JSON value is passed as the Ruby value it reads as: null is nil, a JSON array an Array, and a JSON object a Hash with String keys. `-0.0` is stored as `0.0`.
- Any other argument, such as a domain object (`RegisterCommands.apply(register, command)`), an ActiveRecord record, or an exception, is Ruby source in `{"ruby": "..."}`: `{"args": [{"ruby": "Factories.loan(3)"}]}`. Put a factory method in a `--require` file and call it here, so the test reads as a call (`Lending.approve(Factories.loan(3))`). Each call evaluates the source again at the top level, so every call gets a new object. A Hash argument whose one key is `"ruby"` is written as Ruby too (`{"ruby": "{\"ruby\" => \"3.4\"}"}`). Source that does not parse is refused with the entry's label.
- A file path is a plain String. Put the file under the project, such as `spec/fixtures/files/rates.csv`, and give its absolute path: the emitted test writes it from its own directory (`File.expand_path("../fixtures/files/rates.csv", __dir__)`), so it passes in every checkout, and its name says `spec/fixtures/files/rates.csv`. A path under the temporary or the home directory and outside the project is written as given, and stderr says `the emitted test passes <path>, a file of this machine outside the test's project`, or `a path of this machine outside the test's project that does not exist`: move that path into the project and run again. A returned value or an error message that holds a path under the project is written from the test's directory as well; one that holds a path of this machine outside it makes stderr say `the emitted test pins <path>, a path of this machine outside the test's project`. Names and descriptions say such a path by its file alone. Do not write `__dir__` in `{"ruby": ...}`: explore evaluates the source as `(input)`, where `__dir__` is `.`, and the test file has another directory.
- A block the entry takes goes in `block`, as a brace block: `{"args": [{"ruby": "Factories.loan(3)"}], "block": "{ |amount| amount > 2 }"}`. The emitted call is `Lending.approve(Factories.loan(3)) { |amount| amount > 2 }`; the minitest name says `with_block`, and RSpec says `block is { |amount| amount > 2 }` when the block tells the example apart.
- Append. Do not delete or reorder entries. Leave a failed attempt in the file so you do not retry it blindly.

The target file must load and define the entry. When it needs the rest of its library (a constant from another file), pass the library's entry file with `--require PATH`, repeatable. A name that is no file under the working directory is found on the `-I` directories and then the load path, as `ruby -r` finds it (`-I lib --require shop`); a name found nowhere stops with `--require shop names no file under the working directory, an -I directory, or the load path`. It loads before the target, and emitted tests require it too. Its directory joins the end of the load path, after the gems, so `lib/name.rb` can `require "name/part"`; run the emitted test with that directory on the load path too (`ruby -Ilib`). The target's stdout and stderr are discarded, while it loads and in each call.

An instance method of a library class, with constructor arguments in each input's `new`:

```sh
branchout explore lib/foo/model.rb 'Foo::Model#value' \
  --require lib/foo.rb \
  --inputs path/to/inputs.json \
  --strategy inputs --random 0
```

Run from the project root. `loc` and `target` print relative to the current directory, and absolute paths otherwise.

## Inside a test suite (Rails)

Most methods of a Rails app run only inside its suite: they need the booted app, the database, factories, and a transaction per test. Explore those from inside a test with `Branchout.explore`, not with the CLI.

1. Add the gem to the app's test group: `gem "branchout", group: :test, require: false`.
2. Write one example that explores, in a file of its own, skipped unless `BRANCHOUT` is set. Its first line starts coverage, before the helper loads the app: Coverage counts a file only when the file loads after that line.

```ruby
# spec/models/loan_explore_spec.rb
require "branchout/coverage" if ENV["BRANCHOUT"]
require "rails_helper"
require "branchout"

RSpec.describe Loan, type: :model do
  it "explores approve", if: ENV["BRANCHOUT"] do
    officer = {ruby: "{name: 'Grace', senior: false}"}
    puts Branchout.explore("Loan#approve", within: self, emit_tests: "spec/models/loan_approve_spec.rb", inputs: [
      {receiver: {ruby: "create(:loan)"}, args: [officer]},
      {receiver: {ruby: "create(:loan, :approved)"}, args: [officer]}
    ])
  end
end
```

3. A model that loaded before that line is refused with `loaded before branchout/coverage`, not loaded again, because loading it again declares its validations twice. Run the explore file alone, so that no other spec file loads the model first. When `.rspec` requires `rails_helper`, the app boots before the first line, so an initializer that reads a model, or eager loading (Rails turns it on when `CI` is set), loads it too early. Then run `BRANCHOUT=1 RUBYOPT="-rbundler/setup -rbranchout/coverage" bundle exec rspec <file>`. `bundle exec` reads `RUBYOPT` before Bundler sets the load path, so without `-rbundler/setup` an installed branchout loads instead of the Gemfile's, or a `path:` or `git:` pin raises `LoadError`. `rspec -r branchout/coverage` does not help, because rspec requires it after the files `.rspec` names. The refusal names the command, and, when a helper that loads no model came first (`spec_helper` before `rails_helper`), `rspec --options /dev/null -r spec_helper <file>` too. Coverage set up before Rails also counts the gems' files: on a small app the explore run took about 0.3 s longer to boot and about 12 ms longer for each input. To skip that cost, move the line into `spec/rails_helper.rb` right after the line that loads `config/environment`, with eager loading off. In minitest the line goes first in the test file in the same way, before `require "test_helper"`.

4. Run it: `BRANCHOUT=1 bundle exec rspec spec/models/loan_explore_spec.rb`. In minitest the same call goes in a `test` of an `ActiveSupport::TestCase`, run with `BRANCHOUT=1 bin/rails test test/models/loan_explore_test.rb`.

`explore` returns the report the CLI prints, and follows the same rounds: append inputs to the list (or to an inputs file, by passing its path as `inputs:`) and rerun. `within: self` is the running test. Each input's Ruby runs in that test, so it reaches the suite's factories (`create`, `build`), fixtures (`rooms(:open)`), and helpers. When ActiveRecord is loaded, each input runs in a savepoint that is rolled back, so no input sees the rows another wrote, and the test's own rows stay as they were; `around:` replaces that, as a lambda that takes the input as a block. An input that raises `FrozenError` with frozen Strings runs again with unfrozen ones only when it ran in `Branchout::ROLL_BACK` (the default, or inside an `around:` that calls it); with any other `around:`, such as `Branchout::RUN_ONLY`, the `FrozenError` is pinned. An input that ran in `Branchout::ROLL_BACK` runs once more, as every CLI input does: a returned Hash pins only the keys whose values were the same both times (a generated UUID id, a factory sequence, or a `SecureRandom` token is left out, and a kept value with no literal, such as a `Time` or a record, is pinned by its class), a value that differed as a whole gets no test (a file left with none skips one example, `pins no input`, that says so), an error whose message differed is pinned by its class, and stderr names each such input. To pin such a key, give the input the value instead (`FactoryBot.create(:part, id: "...")`). The strategy is `inputs` only by default, because a random argument rarely fits a record. The other keywords are `target:` (the file, when the entry is defined outside the file `source_location` names), `emit_tests:`, `format:`, `json:`, `verbose:`, `pin_keys:`, `requires:`, `strategies:`, `seed:`, `random:`, `mutate_cap:`, and `timeout:` (default 1; `nil` turns it off).

The emitted test requires the helper the suite loaded (`require "rails_helper"`, else `test_helper`, else `spec_helper`) by name (a suite that loaded none of them passes its helper as `requires:`, or `emit_tests:` is refused; an entry found nowhere stops with `requires: "spec/helper" names no file under the working directory or on the load path`) and does not require the model, which the app loads. A minitest test inherits from the exploring test's own base class, such as `ActiveSupport::TestCase`, so fixtures and helpers work there too. An RSpec file gives its `describe` the exploring example group's `type` (`RSpec.describe Loan, type: :model do`). Its `# Load path:` comment leaves out the project's `spec` and `lib`, which rspec puts on the load path itself. Run it as any other test of the suite, without `BRANCHOUT`.

- An input's Ruby must not read a local of the exploring example, and explore refuses an input that reads a `let` or `subject`. The emitted file has neither, and a `let` that an input reads first would be made inside that input's savepoint, so the rollback removes its row and later inputs get the record Rails marked unsaved. Build what an input needs in its own Ruby.
- A suite that starts SimpleCov in a helper needs no change. branchout measures the explore run, and SimpleCov reports 0% for it.
- Leave the explore example skipped, or delete it once the emitted test is in place.

`--require config/environment.rb` also loads a Rails app for the CLI, with `RAILS_ENV=test`, but each input's rows stay in the test database, later inputs see them, and the test's helpers and `create` are not there.

## Reading the frontier

Stdout is the contract. There is no timestamp. The report opens with `covered: 5 of 6 arms by 13 inputs`, `raised:`, and, with `--emit-tests`, `tests:`. `FRONTIER` follows: each arm that an input reached and did not take, in line order, one line each, its `loc` and what an input must do to take it (``app/models/loan.rb:7:4 makes `state == "approved"` true``), under a `nearest:` line that names the input to change, which consecutive arms share; then, under `not reached yet`, one line for each decision that no input ran (`file:line cond (2 arms)`). `EXCEPTIONS` gives one line for each class, line, and message, and the inputs that raised it (the first three, then a count). `NOT PINNED` lists the covered arms that no emitted test checks, under the `input:` that took them: every input that took such an arm returned a value that differed as a whole between two runs. Give such an input the value it makes (an id, a token), or add one that takes the arm and returns the same value twice. `NOT COUNTED` and `OPERATORS` appear when they have an entry. A section with no entry is left out, except `FRONTIER`, which prints `(none)`.

`--verbose` (`verbose: true` inside a suite) prints the whole report instead: the run settings of the strategies that ran (`seed` and `random` only with `random`, `mutate_cap` only with `mutate`) and the counts (`arms_covered`, `arms_total`, `exceptions`, `callees_not_counted`, `operators_not_counted`, `boundaries_not_counted`), then the sections `COVERED`, `FRONTIER`, `EXCEPTIONS`, `NOT COUNTED`, `OPERATORS`, and `BOUNDARIES`, each record on its own lines, every arm in id order, and each frontier arm with `path`. `--md-out` writes that report. `--json` always holds all of it, so `--verbose` with `--json` is refused.


- `id` is `kind@line:column/arm@line:column`. Columns are 0-based, matching Coverage and Prism. A loop count greater than 1 is appended as `*count`.
- `loc` is `file:line:column`. Open that line. `cond` is the predicate, or the `when` / `in` line. Longer text is cut at 160 characters.
- `sense` selects the arm: `cond-true` (`if` then, `unless` else), `cond-false` (`if` else, `unless` then), `arm-matched` (that `when` or `in`), `arm-else` (case else), `body-entered` (`while` or `until` body), `receiver-present` / `receiver-nil` (`&.`). Anything else is `taken`.
- `parent` (`--verbose` and `--json`): `reached` means some input executed the decision. Flip these first; the default report lists them one line each. `not-reached` means the parent has not run and `nearest` is `null`. Reach the parent first.
- `nearest` reached the decision with the fewest taken arms, then the smallest weight (absolute numeric size, plus string, Ruby source, and container length), then the smallest canonical JSON. With no keywords and no `new` it prints as the args array (`[0,1]`), which pastes into `args`. With keywords, `new`, `receiver`, `setup`, or a `block` it prints as `{"args":[...]}`, plus `"kwargs"`, `"new"`, `"receiver"`, `"setup"`, and `"block"` when set, which pastes back as an entry.
- `path` (`--verbose` and `--json`) is the sorted set of arms `nearest` took. Order is not recorded. An empty set prints `(none)`; a missing path prints `null`.
- `COVERED` (`--verbose`) uses `input` for the witness of that arm, an input that returned the same value on two runs when one did, and adds `pinned: no` when none did. In `--verbose`, `EXCEPTIONS` lists `class`, `loc`, `input`, and `message` for each input. An empty frontier can still have exceptions, and a covered method can still raise.
- `NOT COUNTED` lists the methods in other files that the counted code calls on self, such as a parent class's helper or a mixin's method, and the methods it calls on an object built with `Const.new` in a local or in an instance variable the class sets (`@ledger = Ledger.new`): `callee` (`Register#required_sku`), `loc` (its `def`), and `arms` (the arms in that `def`, or `unknown`). Their arms are not in `arms_total`, so an `arms_total` that dropped after a refactor can mean the logic moved there. Explore that callee as its own entry. Methods of installed gems and of Ruby's own library (an association reader, `update!`), C methods, attribute readers, methods with no arms, and calls on an object whose class the code does not show (a parameter, a method's return value) are not listed.
- `OPERATORS` lists each `||`, `&&`, `||=`, and `&&=` in the counted code: `loc` (the operator), `op`, and `text`. Branch coverage counts no arm for them, so `arms_total` leaves them out and the report cannot say which side ran. `arms_total: 0` with an `OPERATORS` entry is not full coverage: give inputs that make each left side truthy and falsy, and let the pinned results show the difference. `&.` has its own arms.
- `BOUNDARIES` lists each `<`, `<=`, `>`, and `>=` in the counted code, in the same shape. Coverage sees no side of a comparison, so every arm can be covered while no input makes its two sides equal, and a mutant that turns `>` into `>=` survives. Add an input that makes the sides equal (the date on the boundary, the limit itself). The list comes from the source, so a comparison an input already made equal stays on it; check the inputs, not the list.

`--json` is the same report (`version`, counts, `covered`, `arms_not_pinned` (the `NOT PINNED` arms, in the shape of `covered`), `frontier`, `exceptions`, `not_counted`, `operators_not_counted`, `boundaries_not_counted`). Each frontier object has `id`, `loc`, `cond`, `sense`, `parent`, `nearest` (`{"args","kwargs"}`, plus `"new"` and `"setup"` when set, or null), and `path`.

## Rounds

1. Run the explore command.
2. Read the `FRONTIER` arm lines in the order printed.
3. If you have not yet added an input meant to flip that arm, add one. Copy the `nearest` above its line and change it only enough to do what the line says. `&&` and `||` are not separate arms.
4. If a covered arm divides by a non-constant denominator, indexes out of range, or `raise`s, and you have not yet added an input that fires that fault while staying in the arm, add one.
5. Save and rerun the same command.
6. Stop when `FRONTIER` is `(none)` and no fault remains to aim at, or every remaining reached arm has already been tried and did not flip (unsatisfiable, such as `x == 1 && x == 0`), or you have completed 8 rounds.

In one round, add inputs only for arms that are reached now and for faults you can see now. Do not batch the `not reached yet` decisions before their parent has run.

## Emit tests

When you stop, emit characterization tests. Each one pins a discovered input's return value, or the exception class and message, a message over several lines as it was raised (the report puts each line break as one space). A `NameError` or `NoMethodError` is pinned by its class and `error.name`, so the test passes on Ruby 3.3 and 3.4+ alike. A message that quotes a backtrace frame (`lib/x.rb:3:in 'Box.run'`) is matched by a Regexp that leaves the frame's label open, since 3.3 writes `` `run' `` there; so is a returned String that quotes a frame. A `Set` is pinned by its members (`eq(Set[1, 2])`), and a `Date` by its value (`Date.new(2026, 4, 1)`). A `Struct` or `Data` whose members all have a literal is pinned by its class and members (`eq(Rule.new(action: "borrow", on: Date.new(2026, 4, 1)))`). A return value with no Ruby literal, such as an `Object`, a `Time`, or a record, is pinned by its class only. In RSpec a `Struct` or `Data` that holds such a value is pinned by its class and members, and an Array or Hash that holds one item by item (`match([a_kind_of(Rule).and(have_attributes(at: a_kind_of(Time)))])`); minitest pins it by its class only. An expected Hash keeps the value's key order, so a failure diff reads key by key. A private or protected entry, and a private `new`, are called through `send`, as `explore` calls them. A String argument is written as a plain literal and reaches the method frozen, as in the emitted file. Only an input that raises `FrozenError` with frozen Strings, and not with unfrozen ones, gets `+"..."`, under a comment that says why. That value is from a second run in the same process, which saw any global, class variable, or file the first run changed before it raised; run the emitted test on its own before you trust it. A class or module that `private_constant` hides is reached through `const_get` (`Shop.const_get(:Ledger)`), and the RSpec describe names it as a string, since a bare name fails when the spec file loads.

A minitest test is named after its input and what it pins: the input's values and the outcome (`test_0_0_returns_out_of_range`). Inputs whose minitest names would be the same are named by the leaves that differ between them instead: the deepest Hash key above each leaf, with the keys above it when another leaf ends in the same key (`items_id` beside `id`), and its value, or `none` where an input lacks the key and every key above or below it (an input whose Array is empty says `empty`, and one whose Array holds items is named by them) (`test_status_fail_and_error_class_none_returns_ok`). Strings at one leaf drop the words they all start with, so two failure diffs that part at `fail` and `pass` are named from there; Ruby source, such as two factory calls in `receiver`, keeps the word before they part (`limit_100`). Only a name that still collides gets six hex digits of its input's digest. The same inputs file gives the same names, and adding an input can rename the inputs it now shares a name with. Names are cut between words: a blank string argument shows as `blank`, an empty Array or Hash argument as `empty_array` or `empty_hash`, a Hash outcome is named by the fewest leaves, nested ones too, that tell every two different sibling Hashes apart, a leaf every Hash has first (`returns_due_cents_0_and_discount_100`, `returns_discarded_1` for `counts.discarded`), the same leaves the RSpec description says, or, with no sibling, by its keys, never cut, each after the first after `and` (`returns_hash_lines_and_discount_cents`), an Array of collections by its size (`returns_array_of_2`), and an Array of scalars after `array` (`[nil]` is `returns_array_nil`, never `returns_nil`); an Array that holds scalars and collections says `array`, then each scalar and each Hash's keys (`returns_array_ok_hash_id_and_name`, RSpec `returns [:ok, a Hash of id, name]`; `["Done", []]` is `returns_array_done_empty_array`). A String or a Symbol that reads as `nil`, `true`, or `false` says `text` (`returns_text_nil`), and a Hash key that reads so says `key` (`returns_key_nil_0` for `{"NIL" => 0}`). A number of more than 15 digits is named by its first three digits and its power of ten (`123e46`). An input whose key holds another shape than its sibling's (Hashes where the sibling has Arrays) is named by its own leaves, not `none`, and a missing key says `none` once. A Hash argument is named by its values, a collection in it by its key and size (`groups_3`, `tags_empty`), and an Array of collections by its size (`array_of_2`). A test emitted outside the target's directory tree requires the target by absolute path. When a test requires a file by its path from out of its own project (the nearest directory with a `Gemfile`, a gemspec, or `.git`), by absolute path or by a climb into another project, stderr warns that the test runs only where that file sits on this machine, and names the fix. Emit the test under the app (`spec/`), or pass `--require-by-name`, so it runs on another machine. With `--require-by-name`, the emitted test requires each `--require` file and the target through the load path instead, named from the first `-I` directory or `--require` file's directory that holds it: `--require lib/shop.rb` on `lib/shop/cart.rb` emits `require "shop"` and `require "shop/cart"`. A target outside them, such as a Rails model, needs `-I`: `--require lib/shop.rb -I app/models` on `app/models/cart.rb` emits `require "cart"`, and the explore run has `app/models` on its load path too. Without that `-I`, the target is required by path, under a `# Required by path:` comment, and stderr names the file. With no `--require` file and no `-I`, the name comes from the nearest `lib` directory above the target, or from the target's own directory, so a library's entry file `lib/shop.rb` needs no `--require` of itself. Run such a test with those directories on the load path (`ruby -Ilib -Iapp/models`); a `# Load path: -I lib -I app/models` comment above its requires names them, from the working directory, or, for a directory outside it, from its project root with the project named (`-I lib (in shop)`). When a `--require` file already loads the target, the test requires the `--require` files only. That holds for a target it loaded with `Kernel#load`, as Rails loads an initializer, and explore does not load it a second time. The `# target:` header is relative to the working directory, or, for a target outside it, to the nearest directory with a `Gemfile`, a gemspec, or `.git`.

An RSpec file is laid out for a reader: `RSpec.describe Const` with `describe ".method"` or `describe "#method"` inside. It calls the class as `described_class`, pins `true`, `false`, and `nil` with `be(true)`, `be(false)`, and `be_nil`, and writes a Hash with spaces inside its braces in both formats, as RuboCop and rubocop-rspec expect by default. The receiver is a `let`, each setup call a `before`, and inputs that start with the same receiver, setup calls, or argument values share a `context` (`context 'after add("apple", 3)'`, `context "when x is 138"`). A receiver whose `new` differs from a sibling's only at some keywords is named by those keywords (`context "with start_at: Date.new(2026, 5, 1)"`), and `new` takes its keywords in the input's order. A context of an input's `before` that calls the method a sibling's `before` calls is named by the keywords that differ (`context "after FactoryBot.create(:part) with size: 1"`). A `before` of several lines is indented line by line and named by the lines that differ from a sibling's (`after FactoryBot.create(:membership) with enabled: false`). An example says its outcome, then the argument values of its own (`it "returns :hit when z is 7"`); a value every input shares is left out. A value inside a Hash or Array argument is named by its path, and an Array of scalars as a whole (`items is [1, 2]`). A path writes a String key quoted and a Symbol key bare, so a String-keyed Hash such as Rails params never reads as a Symbol lookup: the JSON input `[{"sku": "B"}]` reads `items[0]["sku"] is "B"`, and the Ruby literal `{"ruby": "[{sku: \"B\"}]"}` reads `items[0].sku is "B"`. A `{"ruby": ...}` that is a plain literal (Arrays, Hashes, Strings, Symbols, numbers, `nil`, `true`, `false`) is named by its value in this way, in both formats; a Ruby call with keyword arguments, such as `FactoryBot.build(:fact, a: "X", b: "Y")`, is named by its keywords as a Hash is (`b is "Y"`), and the call before them only when it differs; any other Ruby is named by its source. The parameter's name is left out when every input passes one argument and the path starts at a Symbol key (`sku is "A"`); a path that starts at a position or a String key keeps it (`items[0]["sku"] is "A"`, `doc["status"] is "ready"`). A Hash outcome says the same leaves as the minitest name, each key as the Hash literal writes it (`it "returns due_cents: 0, discount: 100"`, `returns "state" => "open"`); a nested leaf under a String key is written as the literal that holds it, and the leaves under one key share one literal (`returns "counts" => {"discarded" => 1}`, `returns "tests" => [{"file" => "a_spec.rb", "disposition" => "flaky"}]`). A context says only the facts that tell it from its siblings. No text is longer than 80 characters: a longer example keeps only the facts that tell it from its siblings, then names each leaf by its deepest key (`returns discarded: 1, candidates: 1 when status is "timeout"`), or by the keys above it too when another leaf ends in the same key (`when result.status is "timeout"`); a String key is named with the argument and the literal that holds the leaf (`when doc holds "status" => "timeout"`, `when doc holds "result" => {"status" => "timeout"}`), since `doc["status"]` would name another leaf, then cuts its outcome, so the facts that tell it apart stay whole (`returns ["require \"shop\"",... when target_path is "app/cart.rb"`); an example that raises keeps the error's class whole, or names it by its last segment (`raises PartNotFoundError`) when the whole class would push the text past 80 characters. An outcome over 40 characters that is a String or an Array of scalars shows its start, then is cut (`returns ["require_relative \"../lib/shop/cart...`). A String over 30 characters is cut where it parts from the other Strings at its leaf, and ends before a word the cut would split (`x is "...and going on"`). Only a text that is still the same as a sibling's ends in its input's digest. A text that holds a double quote is written in single quotes, or `%q()`, so it needs no escape, even when a String value in it shows its own backslashes (`'returns 1 when x is "say \"hi\""'`). A method that takes no argument in any input is the `subject`. An input that raised keeps its setup calls inside `expect { }`, so a raise from setup is still pinned. Read the result with `rspec --format documentation`: each line should say what the method does for one input.

Pin chosen keys with `--pin-keys due_cents,discount_cents` when the method returns a Hash that will grow, such as a serializer, an API payload, or a snapshot, and the test should hold only the keys you name. minitest then asserts on `value.slice(:due_cents, :discount_cents)` and RSpec uses `include(...)`; the names say only those entries. A key the value lacks is skipped, and a value with none of the keys is pinned whole. Leave it off when every key is the behavior, for a jitcatch candidate meant to catch a removed or renamed key.

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

`baselines` prints three rows: `random` only, `mutate` only, and `agent` (the inputs file only). Random integers are -3..12. Random strings have length 0..3 over `abc01.-`. Mutation tries each source literal and literal±1 in each slot (the literals of the entry and of the methods it calls in the same file, with a constant set to a literal counted as that literal), then a cartesian product of the first two numeric slots, cut by `--mutate-cap` (default 256). It does not solve a congruence or concatenate string literals. Full arm coverage is not the same as finding a fault inside an arm.

## Use with the other tools

Emitted minitest files work as jitcatch candidate tests. jitcatch copies each candidate into `.jitcatch/` of a base and a head checkout and runs it with `-Ilib`. Emit from a checkout of the base revision with `--require-by-name`, so the test loads the library of the checkout it runs in. A test emitted under a `.jitcatch` directory gets this without the flag. Without it, a test emitted outside the checkout requires one fixed path, and base and head both load that same file, so every row is `no_signal`. A `require_relative` in `.jitcatch/` of the base checkout gives the right rows, but the rerun line loads the test from the base checkout, where that path names the base's library: the line passes on head, and jitcatch prints a `warning:` that says so.

```sh
git -C REPO archive BASE | tar -x -C base-checkout
cd base-checkout
branchout explore lib/foo/parser.rb Foo::Parser.parse --require lib/foo.rb \
  --inputs inputs.json --strategy inputs --random 0 \
  --emit-tests .jitcatch/foo_parse_test.rb
cd ..
jitcatch run --repo REPO BASE HEAD base-checkout/.jitcatch
```

For an RSpec project, emit `--format rspec` to a `*_spec.rb` file in TESTS_DIR. jitcatch runs each example as one row, named by its full description, and the row's `rerun:` line runs that one example from the repository root. On branchout itself, with jitcatch fe33733 and a spec that branchout 256128a emitted on the base checkout:

```text
  c01 Branchout::Emitters::Support.hash_differences returns [[], []] when values[0]["tests"][0] is 1, values[0]["counts"]["discarded"] is 0, values[1]["tests"][0] is 1 and values[1]["counts"]["discarded"] is 1 base=pass head=fail m18 assertion,report,touches:changed_method
    expected: [[], []]
    got: [[[["counts", "discarded"], 0]], [[["counts", "discarded"], 1]]]
    rerun: bundle exec ruby -Ilib -I. -e 'require "rspec/core"; RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); exit(RSpec::Core::Runner.run(ARGV))' {tests}/hash_differences_spec.rb:21
```

When `initialize` takes other arguments on head than on base, an input's `new` fits one side only, and every row of the other side fails with an arity `ArgumentError` (jitcatch discards it as `signature_change`). Emit on the side whose constructor the test should pin: on base, to catch a change in what the method returns for the objects base callers build. Split the inputs that need the new constructor into a second inputs file, emit it on head, and expect its rows to be `fail_on_base`; they pin the new behavior, not a regression.

A test that passes on base and fails on head is a changed return value or exception for that input. The test name says the input and what it pinned, such as `test_24_12_raises_zero_division_error`. The `# covers:` list above the assertion names each arm the input took by its line, its condition as written, and the arm, such as `line 20: unless rate.is_a?(Numeric) -> else`. A `case` arm sits on its own `when` or `else` line, and a ternary is written whole.

## Pitfalls

- The target really runs. Files, globals, and the network are not sandboxed.
- The target loads into branchout's own process. A target or `--require` file that loads another checkout of branchout is refused, because it would replace the tool's own classes. Run that checkout's own `bin/branchout` on its own files: when an argument names one, it sets coverage up before it loads itself, so the file is measured without a second load. A file that loaded before coverage was set up is refused with `loaded before explore set up coverage`, because loading it again defines its classes a second time.
- The entry must be defined in the target file, under that constant or a superclass declared in the same file. `BrokenLoans#borrow`, defined on `Loans`, runs `Loans#borrow` and follows `BrokenLoans`'s override of `limited?`, as Ruby does.
- A method that depends on time, randomness, or I/O will not stay stable across runs.
- A path is a set of arms, not an order. Two orders that take the same arms look the same. A modifier `unless` can put `then` and `else` at the same `loc`; the arm name in the id distinguishes them.
- Only a bare call, a `self.` call, and a call on a bare `new(...)` in the same file are followed. `def self.apply(doc) = new(doc).apply` reaches `initialize` and `#apply`, and `new(path).tap(&:parse)` or `then(&:parse)` reaches `#parse`. `send`, another receiver, and other files are out of scope. When the entry reaches no arm, `explore` warns on stderr: target the method that branches, or, when the warning names `OPERATORS`, vary each left side. `--emit-tests` still pins each input's return value or error, so the warning does not block characterization.
- Emitted tests pin other exception messages exactly. A message that differs between Ruby versions fails on a Ruby other than the one that emitted it.
- `Timeout.timeout` does not stop every block. If the timeout backtrace has no target line, `loc` is the method definition line.
- An unsatisfiable condition stays on the frontier. Stop trying it.
- Coverage is process-global. Run the CLI in its own process.
- Do not put secrets in inputs or reports. The tool will not rewrite the inputs file.
