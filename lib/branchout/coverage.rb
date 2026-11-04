# frozen_string_literal: true

# A test suite requires this file before its app loads, so that explore can
# count the arms of the app's files. Requiring branchout itself does not
# start coverage: an app whose Gemfile lists branchout without
# require: false loads it in every process.
require_relative "coverage_session"

Branchout::CoverageSession.install
