# frozen_string_literal: true

# sig/generated is written from the type comments in lib/ by
# `bundle exec rbs-inline --output=sig/generated lib`. sig-deps holds stubs
# for the parts of other libraries that RBS does not declare; the gem does
# not ship them.
target :lib do
  signature "sig", "sig-deps"
  check "lib"

  library "json", "pathname", "stringio", "timeout", "coverage", "tmpdir", "fileutils", "digest", "date", "prism"
end
