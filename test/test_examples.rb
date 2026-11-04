# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "support/cli"

class ExampleReportTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("..", __dir__)

  DEMOS = [
    ["magic_value", "examples/magic_value.rb", "MagicValue.classify"],
    ["arithmetic", "examples/arithmetic.rb", "Arithmetic.classify"],
    ["version_parser", "examples/version_parser.rb", "VersionParser.parse"],
    ["hidden_bug", "examples/hidden_bug.rb", "HiddenBug.scale"]
  ].freeze

  # The run happens in a copy of examples/, so the emitted tests get the
  # same relative paths as the committed ones and the checkout is not written.
  def test_committed_records_match_a_fresh_run
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(ROOT, "examples"), dir)
      DEMOS.each do |name, target, entry|
        records = {
          "reports/#{name}.json" => "--json-out",
          "reports/#{name}.md" => "--md-out",
          "test/generated/#{name}_test.rb" => "--emit-tests",
          "spec/generated/#{name}_spec.rb" => "--emit-tests"
        }
        common = ["--inputs", "examples/inputs/#{name}.json", "--seed", "1"]
        records.each do |path, flag|
          stdout, stderr, status = CLIProcess.run(
            "explore", target, entry,
            *common, "--strategy", "inputs", "--random", "0", flag, path,
            chdir: dir
          )
          assert status.success?, stderr
          assert_equal File.read(File.join(ROOT, "reports/#{name}.txt")), stdout, name
          assert_equal File.read(File.join(ROOT, path)), File.read(File.join(dir, path)), path
        end

        stdout, stderr, status = CLIProcess.run(
          "baselines", target, entry, *common, "--random", "40",
          chdir: dir
        )
        assert status.success?, stderr
        assert_equal File.read(File.join(ROOT, "reports/#{name}_baselines.txt")), stdout, "#{name} baselines"
      end
    end
  end
end
