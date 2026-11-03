# Driving branchout

This tool does not call an LLM. A person or a coding agent reads the frontier, appends inputs, and reruns the same command.

## One command

Turn random sampling and literal mutation off during the search, so new coverage comes only from inputs you add.

```sh
ruby bin/branchout explore TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --strategy inputs \
  --random 0 \
  --seed 1
```

An instance method is `Const#method`. The class must be constructible with `new` and no required arguments.

Start from a single seed:

```json
{
  "inputs": [
    {"args": [0]}
  ]
}
```

Use `[""]` for a string, `[[]]` for an array, and `[{}]` for a hash. If inference is wrong, set `"types": ["int", "string"]` at the top level. `meta` is ignored. Do not delete or reorder existing entries. Append.

## Reading the frontier

Stdout is the contract. The same inputs and seed produce the same bytes. There is no timestamp. Ids are sorted.

- `id` is `kind@line:column/arm@line:column`. Columns are 0-based, matching Coverage and Prism.
- `cond` is the decision's condition. For `when`, it is that line.
- `sense` is the direction that selects the arm.
  - `cond-true` means the condition is true (`if` then, `unless` else).
  - `cond-false` means the condition is false (`if` else, `unless` then).
  - `arm-matched` is that `when` or `in`. `arm-else` is the case else.
  - `body-entered` is the `while` or `until` body.
- `parent: reached` means some input executed the decision. Flip these first.
- `nearest` is the input that reached the decision with the fewest taken arms, then the smallest absolute numeric weight, then the smallest canonical JSON.
- `path` is the sorted set of arms `nearest` took. Order is not recorded. An empty set prints `(none)`.
- `parent: not-reached` means the parent decision has not run. Reach the parent first.
- `EXCEPTIONS` are runtime exceptions. A full frontier can still be empty of exceptions, and a covered method can still raise.

`--json` is the same report in a stable machine-readable form.

## Rounds

1. Run the command above.
2. Read uncovered arms with `parent: reached`, in id order.
3. If you have not yet added an input meant to flip that arm, add one. Copy `nearest` and change it only enough to satisfy `cond` and `sense`. Open the source at that line.
4. If a covered arm divides by a non-constant denominator, indexes out of range, or `raise`s, and you have not yet added an input that fires that fault while staying in the arm, add one.
5. Save and rerun the same command.
6. Stop when any of these is true:
   - `FRONTIER` is `(none)` and there is no remaining fault to aim at.
   - Every remaining `parent: reached` arm has already been tried and did not flip (the condition is unsatisfiable).
   - You have completed 8 rounds.

Do not batch `parent: not-reached` arms before their parent has run. In one round, add inputs only for arms that are reached now and for faults you can see now.

## When you stop

```sh
ruby bin/branchout explore TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests test/generated/name_test.rb \
  --json-out reports/name.json \
  --md-out reports/name.md

ruby bin/branchout baselines TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --seed 1 --random 40
```

For RSpec, use `--emit-tests spec/generated/name_spec.rb`. A `_spec.rb` path selects RSpec without `--format`. Pass `--format rspec` to force it.

`baselines` runs random only, literal mutation only, and the inputs file only. Random integers are -3..12. Random strings have length 0..3 over `abc01.-`. Mutation tries each source literal and literal±1 in each slot, then a cartesian product of the first two numeric slots up to `--mutate-cap` (default 256). Neither solves a congruence nor concatenates strings into something like `"0-rc1"`.

## Do not

- Add an LLM client, an API key, or an external command to this tool.
- Put secrets in inputs or reports.
- Expect the tool to rewrite inputs.json.
