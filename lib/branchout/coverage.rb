# frozen_string_literal: true

# The test file that explores requires this file first, before its helper
# loads the app, so that explore can count the arms of the app's files.
# Requiring branchout itself does not start coverage: an app whose Gemfile
# lists branchout without require: false loads it in every process.
require_relative "coverage_session"

Branchout::CoverageSession.install
