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
      assert_includes report, "EXCEPTIONS\n(none)"
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
          assert_includes report, "EXCEPTIONS\n(none)", around
          assert_includes emitted, "assert_equal :first, pantry.restock(+\"jam\")", around
        else
          assert_includes report, "class: FrozenError", around
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
    assert_includes stdout, "arms_covered: 1\narms_total: 4\n"
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
