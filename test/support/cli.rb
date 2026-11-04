# frozen_string_literal: true

# Runs bin/branchout for a test and returns [stdout, stderr, status], as
# Open3.capture3 does. Booting Ruby and prism took most of the 0.17 s of each
# run, so where fork exists a server process forks itself once per run.
# The servers fork before any test runs, so each run starts with branchout
# loaded and no target, no Coverage, and no test state, as a new Ruby does.
# Tests run in parallel, so there is one server per Minitest worker, and a run
# takes whichever one is free.
# Where fork does not exist, or BRANCHOUT_TEST_SPAWN is set, each run spawns
# Ruby. A run that passes flags to Ruby itself, such as -W0, spawns too.
require "open3"
require "rbconfig"
require "tmpdir"
require "branchout"

module CLIProcess
  BIN = File.expand_path("../../bin/branchout", __dir__)
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end
  Server = Struct.new(:requests, :replies)

  module_function

  def run(*args, chdir:)
    args = args.map(&:to_s)
    # The servers loaded branchout before coverage was set up, so a run that
    # explores one of branchout's own files starts a Ruby of its own.
    own_file = Branchout::CoverageSession.names_own_file?(args, from: chdir)
    return Open3.capture3(RbConfig.ruby, BIN, *args, chdir: chdir) if !@servers || own_file

    Dir.mktmpdir do |dir|
      out = File.join(dir, "out")
      err = File.join(dir, "err")
      server = @servers.pop
      begin
        Marshal.dump([args, chdir, out, err], server.requests)
        server.requests.flush
        code = Marshal.load(server.replies)
      ensure
        @servers.push(server)
      end
      [File.read(out), File.read(err), Status.new(code)]
    end
  end

  def start_servers
    return if ENV["BRANCHOUT_TEST_SPAWN"] || !Process.respond_to?(:fork)

    # branchout autoloads prism; load it here so no run pays for it.
    Prism
    workers = defined?(Minitest.parallel_executor) && Minitest.parallel_executor ? Minitest.parallel_executor.size : 1
    started = []
    workers.times { started << start_server(started) }
    @servers = Thread::Queue.new(started)
  end

  # A server closes the pipes of the servers forked before it, so each one
  # sees end of file when the test process exits.
  def start_server(started)
    requests_r, requests_w = IO.pipe
    replies_r, replies_w = IO.pipe
    fork do
      requests_w.close
      replies_r.close
      started.each { |server| server.requests.close; server.replies.close }
      serve(requests_r, replies_w)
    end
    requests_r.close
    replies_w.close
    Server.new(requests_w, replies_r)
  end

  # The server and each run leave through exit!, so neither runs the
  # test process's at_exit hooks, which would start Minitest again.
  def serve(requests, replies)
    loop do
      args, chdir, out, err = Marshal.load(requests)
      pid = fork do
        requests.close
        replies.close
        $stdout.reopen(out, "w")
        $stderr.reopen(err, "w")
        Dir.chdir(chdir)
        exit!(branchout(args))
      end
      Process.wait(pid)
      Marshal.dump($?.exitstatus || 1, replies)
      replies.flush
    end
  rescue EOFError
    exit!(0)
  end

  # What bin/branchout and Ruby do with the CLI's result: an uncaught
  # exception prints its report and exits 1.
  def branchout(args)
    Branchout::CLI.start(args)
  rescue SystemExit => e
    e.status
  rescue Exception => e # rubocop:disable Lint/RescueException
    $stderr.print e.full_message(highlight: false)
    1
  ensure
    $stdout.flush
    $stderr.flush
  end

  start_servers
end
