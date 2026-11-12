# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "support/unbundled"

# Reruns the README's commands, so that they and the output pasted after them
# cannot drift from what branchout prints. Each sh block runs in one folder,
# in order; a block that follows it and is not sh is the stdout it must print.
class ReadmeQuickStartTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("..", __dir__)
  Block = Struct.new(:info, :body)
  RAILS_QUICK_START = 1
  WITHOUT_AN_APP = 2
  SPEC_FILE = /\A# (spec\/\S+)\n/

  def test_trying_it_without_an_app_prints_what_the_readme_shows
    blocks = section(File.join(ROOT, "README.md"), WITHOUT_AN_APP)
    Dir.mktmpdir do |dir|
      bin = shims(dir)
      work = File.join(dir, "work")
      Dir.mkdir(work)
      env = {"PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}"}
      compared = run_blocks(blocks, work, env) { |script| script.lines.grep_v(/\Agem install /).join }
      assert_operator compared, :>=, 4, "the section shows fewer outputs than expected"
    end
  end

  # The Rails steps need an app with the Quick start's Loan model and
  # factories and its gems installed, which this repository's bundle does
  # not hold. BRANCHOUT_README_RAILS_APP names such an app without branchout;
  # the test runs the steps on a copy of it, with the gem from this checkout.
  def test_the_rails_quick_start_prints_what_the_readme_shows
    app = ENV["BRANCHOUT_README_RAILS_APP"]
    skip "set BRANCHOUT_README_RAILS_APP to a Rails app to rerun the Rails Quick start" unless app

    blocks = section(File.join(ROOT, "README.md"), RAILS_QUICK_START)
    Dir.mktmpdir do |dir|
      work = File.join(dir, "app")
      FileUtils.cp_r(app, work)
      gemfile = blocks.find { |block| block.info == "ruby" && block.body.include?('gem "branchout"') }
      File.write(File.join(work, "Gemfile"), gemfile.body.sub('gem "branchout"', "gem \"branchout\", path: #{ROOT.inspect}"),
                 mode: "a")
      env = Unbundled.env("BUNDLE_GEMFILE" => File.join(work, "Gemfile"),
                          "PATH" => "#{RbConfig::CONFIG.fetch("bindir")}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}")
      compared = run_blocks(rails_steps(blocks), work, env) do |script|
        script.sub(/\Abundle install$/, "bundle install --local --quiet")
      end
      assert_operator compared, :>=, 3, "the Rails Quick start shows fewer outputs than expected"
    end
  end

  def test_japanese_readme_holds_the_same_blocks
    [RAILS_QUICK_START, WITHOUT_AN_APP].each do |index|
      assert_equal section(File.join(ROOT, "README.md"), index), section(File.join(ROOT, "README.ja.md"), index)
    end
  end

  private

  def section(path, index)
    text = File.read(path, encoding: "UTF-8").split(/^## /)[index]
    text.scan(/^```(\w*)\n(.*?)^```$/m).map { |info, body| Block.new(info, body) }
  end

  # A spec file block is written when the steps reach it, so the second run
  # of the explore spec sees the second version of the file. The Gemfile
  # lines are added before the steps, and the method listing runs nothing.
  def rails_steps(blocks)
    blocks.filter_map do |block|
      next block unless block.info == "ruby"

      Block.new("write", block.body) if block.body.match?(SPEC_FILE)
    end
  end

  def run_blocks(blocks, work, env)
    compared = 0
    blocks.each_with_index do |block, index|
      if block.info == "write"
        File.write(File.join(work, block.body[SPEC_FILE, 1]), block.body)
        next
      end
      next unless block.info == "sh"

      script = yield block.body
      out, err, status = Open3.capture3(env, "bash", "-e", "-o", "pipefail", "-c", script, chdir: work, unsetenv_others: true)
      assert status.success?, "README block failed:\n#{script}\n#{err}"
      shown = blocks[index + 1]
      next if shown.nil? || %w[sh write].include?(shown.info)

      assert_equal normalized(shown.body), normalized(out), "README output differs for:\n#{script}"
      compared += 1
    end
    compared
  end

  def shims(dir)
    bin = File.join(dir, "bin")
    Dir.mkdir(bin)
    commands = {"branchout" => File.join(ROOT, "bin", "branchout"), "rspec" => Gem.bin_path("rspec-core", "rspec")}
    commands.each do |name, script|
      path = File.join(bin, name)
      File.write(path, "#!/bin/sh\nexec '#{RbConfig.ruby}' '#{script}' \"$@\"\n")
      File.chmod(0o755, path)
    end
    bin
  end

  # rspec's timings change on every run.
  def normalized(text)
    text.dup.force_encoding(Encoding::UTF_8).gsub(/^Finished in .* seconds \(files took .* seconds to load\)$/, "Finished in")
        .sub(/\A\n+/, "").sub(/\n+\z/, "")
  end
end
