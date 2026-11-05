# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

# Reruns the README's Quick start, so its commands and pasted output cannot
# drift from what branchout prints. Each sh block runs in one empty folder,
# in order; a block that follows it and is not sh is the stdout it must print.
class ReadmeQuickStartTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("..", __dir__)
  Block = Struct.new(:info, :body)

  def test_quick_start_prints_what_the_readme_shows
    blocks = quick_start(File.join(ROOT, "README.md"))
    compared = 0
    Dir.mktmpdir do |dir|
      bin = shims(dir)
      work = File.join(dir, "work")
      Dir.mkdir(work)
      blocks.each_with_index do |block, index|
        next unless block.info == "sh"

        script = block.body.lines.grep_v(/\Agem install /).join
        out, err, status = Open3.capture3({"PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}"},
                                          "bash", "-e", "-o", "pipefail", "-c", script, chdir: work)
        assert status.success?, "README block failed:\n#{script}\n#{err}"
        shown = blocks[index + 1]
        next if shown.nil? || shown.info == "sh"

        assert_equal normalized(shown.body), normalized(out), "README output differs for:\n#{script}"
        compared += 1
      end
    end
    assert_operator compared, :>=, 4, "the Quick start shows fewer outputs than expected"
  end

  def test_japanese_quick_start_holds_the_same_blocks
    assert_equal quick_start(File.join(ROOT, "README.md")), quick_start(File.join(ROOT, "README.ja.md"))
  end

  private

  # The Quick start is the first section after the title.
  def quick_start(path)
    section = File.read(path, encoding: "UTF-8").split(/^## /)[1]
    section.scan(/^```(\w*)\n(.*?)^```$/m).map { |info, body| Block.new(info, body) }
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
