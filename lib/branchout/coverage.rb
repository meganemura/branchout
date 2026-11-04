# frozen_string_literal: true

# A test suite requires this file before its app loads, so that explore can
# count the arms of the app's files. Requiring branchout itself does not
# start coverage: Bundler loads the gemspec, and so branchout, in every
# process of a project that depends on it by path.
require_relative "coverage_session"

Branchout::CoverageSession.install
