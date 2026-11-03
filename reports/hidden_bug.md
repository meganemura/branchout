# branchout explore

branchout explore
target: examples/hidden_bug.rb
entry: HiddenBug.scale
seed: 1
strategies: inputs
random: 0
mutate_cap: 256
timeout: 1
inputs_ran: 4
mutate_ran: 0
random_ran: 0
executions: 4
arms_covered: 4
arms_total: 4
exceptions: 1

COVERED
id: if@6:4/else@14:6
loc: examples/hidden_bug.rb:14:6
cond: a > 10 && b > 10
sense: cond-false
input: [0,0]

id: if@6:4/then@7:6
loc: examples/hidden_bug.rb:7:6
cond: a > 10 && b > 10
sense: cond-true
input: [11,11]

id: if@8:6/else@11:8
loc: examples/hidden_bug.rb:11:8
cond: denom < 50
sense: cond-false
input: [100,11]

id: if@8:6/then@9:8
loc: examples/hidden_bug.rb:9:8
cond: denom < 50
sense: cond-true
input: [11,11]

FRONTIER
(none)

EXCEPTIONS
class: ZeroDivisionError
loc: examples/hidden_bug.rb:9
input: [24,12]
message: divided by 0
