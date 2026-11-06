# branchout explore

branchout explore
target: examples/magic_value.rb
entry: MagicValue.classify
strategies: inputs
timeout: 1
inputs_ran: 2
executions: 2
arms_covered: 2
arms_total: 2
exceptions: 0
callees_not_counted: 0
operators_not_counted: 0
boundaries_not_counted: 0

COVERED
id: if@5:4/else@8:6
loc: examples/magic_value.rb:8:6
cond: x == 114514
sense: cond-false
input: [0]

id: if@5:4/then@6:6
loc: examples/magic_value.rb:6:6
cond: x == 114514
sense: cond-true
input: [114514]

FRONTIER
(none)

EXCEPTIONS
(none)

NOT COUNTED
(none)

OPERATORS
(none)

BOUNDARIES
(none)
