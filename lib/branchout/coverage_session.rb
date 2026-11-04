# frozen_string_literal: true

require "coverage"

module Branchout
  # Coverage counts a file's arms only when the file loads after Coverage
  # was set up. Setup leaves measurement suspended: explore resumes it
  # around each call.
  module CoverageSession
    module_function

    def install
      Coverage.setup(lines: true, branches: true) if Coverage.state == :idle
    end
  end
end
