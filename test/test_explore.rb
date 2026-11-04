# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

# Branchout.explore runs inside a test of the suite it explores, so each
# test here runs a fixture suite in a Ruby of its own: Coverage is
# process-global, and the suite must start it before its app loads.
class ExploreTest < Minitest::Test
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
      assert_equal 3, emitted.scan("returns_first").length, emitted
    end
  end

  def test_inputs_see_each_others_rows_without_the_rollback
    Dir.mktmpdir do |dir|
      report, emitted = explore_pantry(dir, around: "run_only")
      assert_includes report, "arms_covered: 4\narms_total: 4\n"
      assert_includes report, "rows left: 2\n"
      assert_includes emitted, "assert_equal :full, pantry.stock(+\"salt\")"
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
      assert_includes emitted, "require \"spec_helper\"\n\nRSpec.describe Pantry do\n"
      assert_includes emitted, "let(:pantry) { Pantry.new(owner) }"
      assert_includes emitted, "expect(pantry.stock(pantry.owner + ' tea')).to eq(:first)"

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", *rspec, env["EMIT_TO"], chdir: ROOT)
      assert status.success?, stdout + stderr
      assert_includes stdout, "2 examples, 0 failures"
    end
  end

  def test_an_input_that_reads_a_let_is_refused
    refusal = "the input {\"args\":[\"tea\"],\"kwargs\":{},\"receiver\":{\"ruby\":\"Pantry.new(cook)\"}} reads let(:cook) " \
              "of the exploring test, which the emitted test does not have. A let an input reads first is made in that " \
              "input's rolled-back savepoint and kept for the next input. Build it in the input's Ruby."
    rspec = ["-I", SUITE, "-rrspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--"]
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", *rspec, "#{SUITE}/pantry_let_spec.rb", chdir: ROOT)
    refute status.success?, stdout + stderr
    assert_includes stdout.gsub(/\s+/, " "), "Branchout::Error: #{refusal}"

    stdout, stderr, status = run_suite("#{SUITE}/pantry_let_test.rb")
    refute status.success?, stdout + stderr
    assert_includes stdout.gsub(/\s+/, " "), "Branchout::Error: #{refusal}"
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
  end

  def test_a_receiver_that_is_not_ruby_source_is_refused
    require "branchout"
    error = assert_raises(Branchout::Error) do
      Branchout::InputFile.parse_entry({ "args" => [], "receiver" => { "ruby" => 3 } }, "inputs[0]")
    end
    assert_equal "inputs[0] receiver must be Ruby such as {\"ruby\": \"create(:loan)\"}", error.message
  end

  # Bundler loads the gemspec, and so branchout, in every process of a
  # project that depends on branchout by path.
  def test_requiring_branchout_leaves_coverage_off
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", 'require "branchout"; print Coverage.state',
                                            chdir: ROOT)
    assert status.success?, stderr
    assert_equal "idle", stdout
  end

  def test_a_target_loaded_before_coverage_is_refused_not_loaded_again
    stdout, _stderr, status = run_suite("#{SUITE}/early_test.rb", "PANTRY_FIRST" => "1")
    refute status.success?
    assert_includes stdout, "Branchout::Error: #{SUITE}/pantry.rb loaded before branchout/coverage, so Coverage has no arms for it. " \
                            "Require \"branchout/coverage\" in the test helper before the app's code loads: in Rails, after config/environment with eager loading off."
  end

  def test_coverage_another_tool_started_is_refused
    stdout, _stderr, status = run_suite("#{SUITE}/early_test.rb", "COVERAGE_TOOL" => "1")
    refute status.success?
    assert_includes stdout, "Branchout::Error: Coverage is running, so explore cannot measure #{SUITE}/pantry.rb. " \
                            "Require \"branchout/coverage\" in the test helper before the app's code loads: in Rails, after config/environment with eager loading off, " \
                            "and run without another coverage tool such as SimpleCov."
  end
end
