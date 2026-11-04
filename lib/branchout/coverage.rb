# frozen_string_literal: true

require "coverage"

module Branchout
  # Coverage counts a file's arms only when the file loads after Coverage
  # was set up, so a test suite requires this file before its app loads.
  # Setup leaves measurement suspended: explore resumes it around each call.
  module CoverageSession
    module_function

    def install
      return unless Coverage.state == :idle

      previous = $VERBOSE
      $VERBOSE = nil
      Coverage.setup(lines: true, branches: true)
    ensure
      $VERBOSE = previous if defined?(previous)
    end
  end
end

Branchout::CoverageSession.install
