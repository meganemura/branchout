# frozen_string_literal: true
# rbs_inline: enabled

require "coverage"

module Branchout
  # Coverage counts a file's arms only when the file loads after Coverage
  # was set up. Setup leaves measurement suspended: explore resumes it
  # around each call.
  module CoverageSession
    # __dir__ is nil only in code that eval runs, and this file is required.
    HERE = __dir__ #: String
    LIB = File.join(File.expand_path("..", HERE), "") #: String
    private_constant :HERE

    # Many suites start SimpleCov unconditionally at the top of a helper.
    # From a helper that loads after the session, its Coverage.start would
    # raise "coverage measurement is already setup", so the session keeps
    # measuring, and the tool reads the session's result when it reports.
    # Coverage takes :all, or a keyword per kind of coverage, and returns nil.
    module LaterStart
      #: (*Symbol, **bool) -> nil
      def setup(...) = (super unless CoverageSession.installed?)

      #: (*Symbol, **bool) -> nil
      def start(...) = (super unless CoverageSession.installed?)
    end

    # @rbs self.@installed: bool

    module_function

    # Coverage that another tool started earlier measures lines only, so
    # the session stops it and sets Coverage up again with branches.
    #: () -> void
    def install
      return if installed?

      Coverage.result unless Coverage.state == :idle
      Coverage.setup(lines: true, branches: true)
      Coverage.singleton_class.prepend(LaterStart)
      @installed = true
    end

    #: () -> bool
    def installed? = @installed == true

    # A file of branchout's own lib loads with the tool, so it has arms only
    # when coverage was set up before the tool loaded. Only a run that names
    # one sets it up that early: each call reads the coverage of every file
    # loaded after setup, and the tool's own files made that 1.3 ms a call
    # instead of 0.04 ms.
    #: (Array[String], ?from: String) -> bool
    def names_own_file?(argv, from: Dir.pwd)
      argv.any? do |arg|
        path = File.expand_path(arg, from)
        File.file?(path) && path.start_with?(LIB)
      end
    end
  end
end
