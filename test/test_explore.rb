# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

# Branchout.explore runs inside a test of the suite it explores, so each
# test here runs a fixture suite in a Ruby of its own: Coverage is
# process-global, and the suite must start it before its app loads.
class ExploreTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("..", __dir__)
  SUITE = "test/fixtures/suite"

  def run_suite(file, env = {})
    Open3.capture3(env, RbConfig.ruby, "-Ilib", "-I#{SUITE}", file, chdir: ROOT)
  end

  def explore_pantry(dir, around: nil)
    env = {"EMIT_TO" => File.join(dir, "pantry_test.rb"), "REPORT_TO" => File.join(dir, "report.txt"),
           "BRANCHOUT_AROUND" => around}
    stdout, stderr, status = run_suite("#{SUITE}/pantry_explore_test.rb", env)
    assert status.success?, stdout + stderr
    [File.read(env["REPORT_TO"]), File.read(env["EMIT_TO"])]
  end

  def test_each_input_runs_in_a_rolled_back_transaction
    Dir.mktmpdir do |dir|
      report, emitted = explore_pantry(dir)
      assert_includes report, "arms_covered: 2\narms_total: 4\n"
      assert_includes report, "rows left: 0\n"
      assert_includes report, "NOT COUNTED\ncallee: ShelfLabel#label\nloc: #{SUITE}/shelf_label.rb:4\narms: 2\n"
      assert_equal 3, emitted.scan("returns_first").length, emitted
    end
  end

  def test_inputs_see_each_others_rows_without_the_rollback
    Dir.mktmpdir do |dir|
      report, emitted = explore_pantry(dir, around: "run_only")
      assert_includes report, "arms_covered: 4\narms_total: 4\n"
      assert_includes report, "rows left: 2\n"
      assert_includes emitted, "assert_equal :full, pantry.stock(\"salt\")"
    end
  end

  # The run with frozen Strings writes a row before it raises FrozenError,
  # so the run with unfrozen ones sees that row only if it is not undone.
  def test_an_input_retried_with_unfrozen_strings_sees_none_of_the_first_runs_rows
    Dir.mktmpdir do |dir|
      env = {"EMIT_TO" => File.join(dir, "restock_test.rb"), "REPORT_TO" => File.join(dir, "report.txt")}
      stdout, stderr, status = run_suite("#{SUITE}/pantry_restock_explore_test.rb", env)
      assert status.success?, stdout + stderr
      report = File.read(env["REPORT_TO"])
      refute_includes report, "EXCEPTIONS"
      assert_includes report, "\nPass verbose: true for every covered arm and the run settings.\n"
      assert_includes report, "rows left: 0\n"
      emitted = File.read(env["EMIT_TO"])
      assert_includes emitted, "a class variable, or a file.\n    pantry = Pantry.new(owner)\n    assert_equal :first, pantry.restock(+\"jam\")\n"

      stdout, stderr, status = run_suite(env["EMIT_TO"])
      assert status.success?, stdout + stderr
      assert_includes stdout, "1 runs, 1 assertions, 0 failures, 0 errors"
    end
  end

  # Without a rollback the run with frozen Strings keeps its row, so a
  # second run would pin a value no fresh test sees. Only an input that ran
  # in ROLL_BACK's savepoint runs again; a custom around that keeps its rows,
  # as RUN_ONLY does, keeps the FrozenError, also after an earlier explore
  # in the same test rolled its input back.
  def test_an_input_that_keeps_its_rows_is_not_run_again_with_unfrozen_strings
    [["custom", 1, "1"], ["wrapped", 0]].each do |around, rows_left, first|
      Dir.mktmpdir do |dir|
        env = {"EMIT_TO" => File.join(dir, "restock_test.rb"), "REPORT_TO" => File.join(dir, "report.txt"),
               "BRANCHOUT_AROUND" => around, "EXPLORE_FIRST" => first}
        stdout, stderr, status = run_suite("#{SUITE}/pantry_restock_explore_test.rb", env)
        assert status.success?, stdout + stderr
        report = File.read(env["REPORT_TO"])
        assert_includes report, "rows left: #{rows_left}\n", around
        emitted = File.read(env["EMIT_TO"])
        if rows_left.zero?
          refute_includes report, "EXCEPTIONS", around
          assert_includes emitted, "assert_equal :first, pantry.restock(+\"jam\")", around
        else
          assert_includes report, "EXCEPTIONS\nFrozenError at ", around
          assert_includes emitted, "pantry.restock(\"jam\")", around
          refute_includes emitted, "+\"jam\"", around
        end
      end
    end
  end

  def test_the_emitted_test_requires_the_suite_helper_and_runs_in_the_suite
    Dir.mktmpdir do |dir|
      report, emitted = explore_pantry(dir)
      assert_includes report, "timeout: 1\n"
      assert_includes emitted, "# Load path: -I #{SUITE}\nrequire \"test_helper\"\n\nclass PantryStockCharacterizationTest < SuiteCase\n"
      refute_includes emitted, "require_relative"
      assert_includes emitted, "    pantry = Pantry.new(owner)\n    assert_equal :first, pantry.stock(pantry.owner + ' tea')\n"

      stdout, stderr, status = run_suite(File.join(dir, "pantry_test.rb"))
      assert status.success?, stdout + stderr
      assert_includes stdout, "3 runs, 3 assertions, 0 failures, 0 errors"
    end
  end

  def test_rspec_inputs_reach_the_example_helpers
    Dir.mktmpdir do |dir|
      env = {"EMIT_TO" => File.join(dir, "pantry_spec.rb"), "REPORT_TO" => File.join(dir, "report.txt")}
      rspec = ["-I", SUITE, "-rrspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--"]
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", *rspec, "#{SUITE}/pantry_explore_spec.rb", chdir: ROOT)
      assert status.success?, stdout + stderr
      assert_includes File.read(env["REPORT_TO"]), "timeout: none\n"
      assert_includes File.read(env["REPORT_TO"]), "arms_covered: 2\n"
      emitted = File.read(env["EMIT_TO"])
      assert_includes emitted, "require \"spec_helper\"\n\nRSpec.describe Pantry, type: :model do\n"
      assert_includes emitted, "    context \"with Pantry.new(owner)\" do\n      let(:pantry) { Pantry.new(owner) }\n"
      assert_includes emitted, "    context \"with Pantry.new('bo')\" do\n      let(:pantry) { Pantry.new('bo') }\n"
      assert_includes emitted, "expect(pantry.stock(pantry.owner + ' tea')).to eq(:first)"

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", *rspec, env["EMIT_TO"], chdir: ROOT)
      assert status.success?, stdout + stderr
      assert_includes stdout, "3 examples, 0 failures"
    end
  end

  # The input's own Ruby raised before the entry ran, so the error says
  # nothing about the entry, and a test that pinned it would keep it.
  def test_an_input_whose_own_ruby_raises_is_refused
    inputs = '[{"args":["bolt"]},{"args":[{"ruby":"create(:part)"}]}]'
    stdout, stderr, status = run_suite("#{SUITE}/ticket_explore_test.rb", "INPUTS" => inputs)
    refute status.success?, stdout + stderr
    # Ruby 3.3 quotes the method name with a backtick.
    assert_includes stdout.gsub(/\s+/, " ").sub("`create'", "'create'"),
                    "Branchout::Error: the input {\"args\":[{\"ruby\":\"create(:part)\"}],\"kwargs\":{}} raised NoMethodError in its own Ruby " \
                    "before Ticket.attributes_from ran: undefined method 'create' for an instance of TicketExploreTest. " \
                    "Fix the input: a bare create or build needs FactoryBot::Syntax::Methods in the suite; " \
                    "without it write FactoryBot.create."
  end

  # Each input runs twice. A Hash leaf that differs between the runs, as a
  # generated id or a SecureRandom token does, is left out of the pin, and
  # a value that differs as a whole is not pinned, so the emitted test
  # passes on its first run.
  def test_a_value_that_differs_between_two_runs_is_not_pinned
    Dir.mktmpdir do |dir|
      emit_to = File.join(dir, "ticket_test.rb")
      inputs = '[{"args":["bolt"]},{"args":["nut"],"kwargs":{"line":{"ruby":"serial"}}}]'
      stdout, stderr, status = run_suite("#{SUITE}/ticket_explore_test.rb", "INPUTS" => inputs, "EMIT_TO" => emit_to)
      assert status.success?, stdout + stderr
      assert_includes stderr, "branchout: [\"bolt\"] returned a Hash whose token differed between two runs, " \
                              "so its test pins only part.\n"
      assert_includes stderr, "branchout: {\"args\":[\"nut\"],\"kwargs\":{\"line\":{\"ruby\":\"serial\"}}} " \
                              "returned a Hash whose token, line differed between two runs, so its test pins only part.\n"
      emitted = File.read(emit_to)
      assert_includes emitted, "assert_equal({ part: \"bolt\" }, Ticket.attributes_from(\"bolt\").slice(:part))"
      stdout, stderr, status = run_suite(emit_to)
      assert status.success?, stdout + stderr
      assert_includes stdout, "2 runs, 2 assertions, 0 failures, 0 errors"

      stdout, stderr, status = run_suite("#{SUITE}/ticket_explore_test.rb", "INPUTS" => "[[]]", "EMIT_TO" => emit_to, "ENTRY" => "Ticket.code")
      assert status.success?, stdout + stderr
      assert_includes stderr, "branchout: [] returned a value that differed between two runs, so it has no test.\n"
      assert_includes File.read(emit_to), "skip \"each input returned a value that differed between two runs, so no emitted test checks it\""
    end
  end

  # rspec requires the files .rspec and -r name before the spec file, so
  # the spec's first line comes too late and -r branchout/coverage loads
  # after them; RUBYOPT loads it before rspec starts. A helper that loaded
  # the model, as a rails_helper does, cannot be the way around it.
  def test_a_helper_that_rspec_requires_first_is_named_with_the_way_around_it
    dir = "test/fixtures/dotrspec"
    rspec = ["-rrspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--", "-I", "."]
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{ROOT}/lib", *rspec, "pantry_explore_spec.rb", chdir: dir)
    refute status.success?, stdout + stderr
    assert_includes stdout.gsub(/\s+/, " "),
                    "rspec required dot_helper before the explore file and before any -r branchout/coverage. " \
                    "Start Coverage before rspec loads: RUBYOPT=\"-rbundler/setup -rbranchout/coverage\" bundle exec rspec <the explore file>."

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{ROOT}/lib", *rspec, "--options", File::NULL, "-r", "plain_helper",
                                            "-r", "dot_helper", "pantry_explore_spec.rb", chdir: dir)
    refute status.success?, stdout + stderr
    assert_includes stdout.gsub(/\s+/, " "),
                    "rspec required plain_helper, dot_helper before the explore file and before any -r branchout/coverage. " \
                    "Start Coverage before rspec loads: RUBYOPT=\"-rbundler/setup -rbranchout/coverage\" bundle exec rspec <the explore file>, " \
                    "or rspec --options /dev/null -r plain_helper <the explore file>, which leaves out the helpers that loaded it."

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{ROOT}/lib", *rspec, "--options", File::NULL, "-r", "plain_helper",
                                            "pantry_explore_spec.rb", chdir: dir)
    assert status.success?, stdout + stderr
    assert_includes stdout, "covered: 2 of 4 arms by 1 input\n"

    stdout, stderr, status = Open3.capture3({"RUBYOPT" => "-I#{ROOT}/lib -rbranchout/coverage"}, RbConfig.ruby, *rspec, "pantry_explore_spec.rb",
                                            chdir: dir)
    assert status.success?, stdout + stderr
    assert_includes stdout, "covered: 2 of 4 arms by 1 input\n"

    # A model Ruby itself loaded first is not rspec's doing.
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{ROOT}/lib", "-r./dot_helper", *rspec, "--options", File::NULL,
                                            "pantry_explore_spec.rb", chdir: dir)
    refute status.success?, stdout + stderr
    assert_includes stdout.gsub(/\s+/, " "), "and run that file alone. "
    refute_includes stdout, "rspec required"
  end

  # A helper that is the model itself loaded it, and one that loaded it
  # with Kernel#load leaves no position to compare.
  def test_a_helper_that_is_the_model_or_loads_it_with_load_is_not_the_way_around_it
    dir = "test/fixtures/dotrspec"
    rspec = ["-rrspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--", "-I", "."]
    [[["../suite/active_record", "../suite/pantry"], "pantry_explore_spec.rb", " -r ../suite/active_record"],
     [["load_helper"], "pantry_loaded_spec.rb", nil]].each do |helpers, spec, harmless|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{ROOT}/lib", *rspec, "--options", File::NULL, "-r", "plain_helper",
                                              *helpers.flat_map { |name| ["-r", name] }, spec, chdir: dir)
      refute status.success?, stdout + stderr
      second_form = harmless ? ", or rspec --options /dev/null -r plain_helper#{harmless} <the explore file>, " : ". "
      assert_includes stdout.gsub(/\s+/, " "),
                      "rspec required #{["plain_helper", *helpers].join(", ")} before the explore file and before any -r branchout/coverage. " \
                      "Start Coverage before rspec loads: RUBYOPT=\"-rbundler/setup -rbranchout/coverage\" bundle exec rspec " \
                      "<the explore file>#{second_form}"
    end
  end

  # bundle exec loads rspec in its own process, which read RUBYOPT before
  # Bundler set the load path, so a bare -rbranchout/coverage there loads an
  # installed branchout, or none, instead of the bundle's. The refusal's
  # command must load the copy the Gemfile names, as a path or git gem.
  def test_the_refusals_rubyopt_loads_the_bundles_branchout
    dir = File.join(ROOT, "test/fixtures/dotrspec")
    rspec = ["-rrspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--", "-I", "."]
    stdout, = Open3.capture3(RbConfig.ruby, "-I#{ROOT}/lib", *rspec, "pantry_explore_spec.rb", chdir: dir)
    rubyopt = stdout.gsub(/\s+/, " ")[/RUBYOPT="([^"]+)" bundle exec rspec/, 1]
    refute_nil rubyopt, stdout

    Dir.mktmpdir do |bundle|
      gemfile = File.join(bundle, "Gemfile")
      File.write(gemfile, <<~GEMFILE)
        source "https://rubygems.org"
        gem "rspec-core", #{Gem.loaded_specs.fetch("rspec-core") { Gem::Specification.find_by_name("rspec-core") }.version.to_s.inspect}
        gem "branchout", path: #{ROOT.inspect}
      GEMFILE
      env = {"BUNDLE_GEMFILE" => gemfile, "PATH" => "#{RbConfig::CONFIG.fetch("bindir")}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}"}
      without_bundle do
        _out, err, status = Open3.capture3(env, "bundle", "install", "--local", "--quiet", chdir: dir)
        assert status.success?, err
        stdout, stderr, status = Open3.capture3(env.merge("RUBYOPT" => rubyopt), "bundle", "exec", "rspec", "-I", ".",
                                                "pantry_explore_spec.rb", chdir: dir)
        assert status.success?, stdout + stderr
        assert_includes stderr, "branchout/coverage from #{ROOT}/lib/branchout/coverage.rb\n"
        assert_includes stdout, "covered: 2 of 4 arms by 1 input\n"
      end
    end
  end

  def without_bundle(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : yield
  end

  # An input's before Ruby makes the rows the entry reads, in the input's
  # own savepoint, and the emitted test makes them before the call.
  def test_an_inputs_before_runs_in_its_savepoint_before_the_call
    Dir.mktmpdir do |dir|
      emit_to = File.join(dir, "stocked_test.rb")
      inputs = '[{"before":{"ruby":"ActiveRecord::Base.rows << [owner, \"bolt\"]"},"args":["bolt"]},{"args":["bolt"]}]'
      stdout, stderr, status = run_suite("#{SUITE}/ticket_explore_test.rb", "INPUTS" => inputs, "EMIT_TO" => emit_to, "ENTRY" => "Ticket.stocked")
      assert status.success?, stdout + stderr
      assert_includes stdout, "covered: 2 of 2 arms by 2 inputs\n"
      emitted = File.read(emit_to)
      assert_includes emitted, "    ActiveRecord::Base.rows << [owner, \"bolt\"]\n    assert_equal :stocked, Ticket.stocked(\"bolt\")\n"
      assert_includes emitted, "    assert_equal :missing, Ticket.stocked(\"bolt\")\n"
      stdout, stderr, status = run_suite(emit_to)
      assert status.success?, stdout + stderr
      assert_includes stdout, "2 runs, 2 assertions, 0 failures, 0 errors"
    end
  end

  # The savepoint reason holds only for a let the input made. The spec
  # reads its let before explore, so only the missing let is the reason.
  def test_an_input_that_reads_a_let_is_refused
    read = "the input {\"args\":[\"tea\"],\"kwargs\":{},\"receiver\":{\"ruby\":\"Pantry.new(cook)\"}} reads let(:cook) " \
           "of the exploring test, which the emitted test does not have."
    made = " A let an input reads first is made in that input's rolled-back savepoint and kept for the next input."
    build = " Build it in the input's Ruby."
    rspec = ["-I", SUITE, "-rrspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--"]
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", *rspec, "#{SUITE}/pantry_let_spec.rb", chdir: ROOT)
    refute status.success?, stdout + stderr
    assert_includes stdout.gsub(/\s+/, " "), "Branchout::Error: #{read}#{build}"

    stdout, stderr, status = run_suite("#{SUITE}/pantry_let_test.rb")
    refute status.success?, stdout + stderr
    assert_includes stdout.gsub(/\s+/, " "), "Branchout::Error: #{read}#{made}#{build}"
  end

  # The refused explore ran its input before it found the let, so the
  # arms that input took are still counted when the next explore starts.
  def test_an_explore_after_a_refused_one_counts_only_its_own_inputs
    stdout, stderr, status = run_suite("#{SUITE}/pantry_after_refusal_test.rb")
    assert status.success?, stdout + stderr
    assert_includes stdout, "covered: 1 of 4 arms by "
  end

  def test_a_suite_with_no_helper_explore_knows_must_name_one_to_emit
    Dir.mktmpdir do |dir|
      emit_to = File.join(dir, "t.rb")
      stdout, _stderr, status = run_suite("#{SUITE}/bare_explore_test.rb", "EMIT_TO" => emit_to)
      refute status.success?
      assert_includes stdout.gsub(/\s+/, " "), "Branchout::Error: the suite loaded no rails_helper.rb, test_helper.rb, spec_helper.rb " \
                                               "from #{ROOT}, so an emitted test would not load the app; pass the helper file as requires:"
      refute File.exist?(emit_to)
    end
  end

  # The README writes requires: as one String, as the refusal above asks.
  def test_a_suite_names_its_helper_in_requires_as_one_string
    Dir.mktmpdir do |dir|
      emit_to = File.join(dir, "t.rb")
      stdout, stderr, status = run_suite("#{SUITE}/bare_explore_test.rb", "EMIT_TO" => emit_to, "REQUIRES" => "#{SUITE}/test_helper")
      assert status.success?, stdout + stderr
      assert_includes File.read(emit_to), %(require "test_helper"\n)
    end
  end

  # minitest 6 needs prism 1, and RubyGems activates the newest prism for
  # a require with no version, so branchout must not load prism until it
  # parses.
  def test_a_suite_may_require_branchout_before_its_test_framework
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", 'require "branchout"; require "minitest"; print :loaded',
                                            chdir: ROOT)
    assert status.success?, stderr
    assert_equal "loaded", stdout
  end

  # These refusals come before explore touches Coverage, so they run here.
  def test_an_entry_or_inputs_explore_cannot_use_is_refused
    require "branchout"
    {
      ["Pantry", []] => "entry \"Pantry\" is not Const.method or Const#method",
      ["Comparable#clamp", []] => "Comparable#clamp has no Ruby source file; pass target:",
      ["NoSuchConst.run", []] => "cannot resolve NoSuchConst.run: uninitialized constant NoSuchConst",
      ["ExploreTest#run_suite", {}] => "inputs must be a list or an inputs file path"
    }.each do |(entry, inputs), message|
      error = assert_raises(Branchout::Error) { Branchout.explore(entry, within: self, inputs: inputs) }
      assert_equal message, error.message
    end
    error = assert_raises(Branchout::Error) do
      Branchout.explore("ExploreTest#run_suite", within: self, inputs: [], emit_tests: "x_test.rb", format: :tap)
    end
    assert_equal "format must be minitest or rspec", error.message
    error = assert_raises(Branchout::Error) do
      Branchout.explore("ExploreTest#run_suite", within: self, inputs: [], json: true, verbose: true)
    end
    assert_equal "verbose: is only valid with the text report; json: true holds every arm and the run settings", error.message
    error = assert_raises(Branchout::Error) do
      Branchout.explore("ExploreTest#run_suite", within: self, inputs: [], requires: ["no_such_helper"])
    end
    assert_equal "requires: \"no_such_helper\" names no file under the working directory or on the load path", error.message
  end

  def test_a_receiver_that_is_not_ruby_source_is_refused
    require "branchout"
    error = assert_raises(Branchout::Error) do
      Branchout::InputFile.parse_entry({ "args" => [], "receiver" => { "ruby" => 3 } }, "inputs[0]")
    end
    assert_equal "inputs[0] receiver must be Ruby such as {\"ruby\": \"create(:loan)\"}", error.message
  end

  # An app whose Gemfile lists branchout without require: false loads it in
  # every process.
  def test_requiring_branchout_leaves_coverage_off
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", 'require "branchout"; print Coverage.state',
                                            chdir: ROOT)
    assert status.success?, stderr
    assert_equal "idle", stdout
  end

  # The CLI installs the session before it loads a --require file, and a
  # suite's helper may require branchout/coverage again.
  def test_installing_the_session_again_keeps_the_counts_of_loaded_files
    script = 'require "branchout/coverage"; require_relative "test/fixtures/suite/pantry"; ' \
             'Branchout::CoverageSession.install; print Coverage.peek_result.keys.grep(/pantry/).length'
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, chdir: ROOT)
    assert status.success?, stderr
    assert_equal "1", stdout
  end

  def test_a_target_loaded_before_coverage_is_refused_not_loaded_again
    stdout, _stderr, status = run_suite("#{SUITE}/early_test.rb", "PANTRY_FIRST" => "1")
    refute status.success?
    assert_includes stdout, "Branchout::Error: #{SUITE}/pantry.rb loaded before branchout/coverage, so Coverage has no arms for it. " \
                            "Require \"branchout/coverage\" first in the test file that explores, before its helper, and run that file alone."
  end

  # Many suites start SimpleCov unconditionally at the top of a helper,
  # which loads before or after the explore file's first line.
  def test_explore_measures_when_another_tool_starts_coverage_before_or_after_it
    %w[before after].each do |order|
      stdout, stderr, status = run_suite("#{SUITE}/early_test.rb", "COVERAGE_TOOL" => order)
      assert status.success?, "#{order}: #{stdout}#{stderr}"
      assert_includes stdout, "covered: 2 of 4 arms by 1 input\n", order
    end
  end
end
