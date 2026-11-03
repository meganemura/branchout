# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class ExampleReportTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin/concolic")

  DEMOS = [
    ["magic_value", "examples/magic_value.rb", "MagicValue.classify"],
    ["arithmetic", "examples/arithmetic.rb", "Arithmetic.classify"],
    ["version_parser", "examples/version_parser.rb", "VersionParser.parse"],
    ["hidden_bug", "examples/hidden_bug.rb", "HiddenBug.scale"]
  ].freeze

  def run_cli(*args)
    Open3.capture3(RbConfig.ruby, BIN, *args.map(&:to_s), chdir: ROOT)
  end

  def test_committed_reports_match_a_fresh_run
    DEMOS.each do |name, target, entry|
      inputs = "examples/inputs/#{name}.json"
      stdout, stderr, status = run_cli(
        "explore", target, entry,
        "--inputs", inputs, "--strategy", "inputs", "--random", "0", "--seed", "1"
      )
      assert status.success?, stderr
      assert_equal File.read(File.join(ROOT, "reports/#{name}.txt")), stdout, name

      base_out, base_err, base_status = run_cli(
        "baselines", target, entry,
        "--inputs", inputs, "--seed", "1", "--random", "40"
      )
      assert base_status.success?, base_err
      assert_equal File.read(File.join(ROOT, "reports/#{name}_baselines.txt")), base_out, "#{name} baselines"
    end
  end
end
