# frozen_string_literal: true

require "coverage"

module Branchout
  # Coverage counts a file's arms only when the file loads after Coverage
  # was set up. Setup leaves measurement suspended: explore resumes it
  # around each call.
  module CoverageSession
    LIB = File.join(File.expand_path("..", __dir__), "")

    module_function

    def install
      Coverage.setup(lines: true, branches: true) if Coverage.state == :idle
    end

    # A file of branchout's own lib loads with the tool, so it has arms only
    # when coverage was set up before the tool loaded. Only a run that names
    # one sets it up that early: each call reads the coverage of every file
    # loaded after setup, and the tool's own files made that 1.3 ms a call
    # instead of 0.04 ms.
    def names_own_file?(argv)
      argv.any? { |arg| File.file?(arg) && File.expand_path(arg).start_with?(LIB) }
    end
  end
end
