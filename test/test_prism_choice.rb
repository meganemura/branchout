# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "branchout/prism_choice"

class PrismChoiceTest < Minitest::Test
  def spec(name, version, prism: nil)
    Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.add_dependency "prism", prism if prism
    end
  end

  def versions(*list) = list.map { |v| Gem::Version.new(v) }

  def test_takes_the_newest_prism_when_no_gem_names_one
    assert_equal Gem::Version.new("2.1.0"), Branchout::PrismChoice.accepted(versions("1.9.0", "2.1.0"), [spec("json", "2.0")])
  end

  def test_takes_the_newest_prism_every_gem_accepts
    specs = [spec("minitest", "6.0.6", prism: "~> 1.5"), spec("typeprof", "0.31.1", prism: ">= 1.4.0")]
    assert_equal Gem::Version.new("1.9.0"), Branchout::PrismChoice.accepted(versions("1.4.0", "2.1.0", "1.9.0", "1.8.2"), specs)
  end

  # A require with no version activates the newest version of a gem, so an
  # older one's requirement does not stop a prism.
  def test_reads_only_the_newest_version_of_each_gem
    specs = [spec("minitest", "6.0.6", prism: "~> 1.5"), spec("minitest", "7.0.0", prism: ">= 2")]
    assert_equal Gem::Version.new("2.1.0"), Branchout::PrismChoice.accepted(versions("1.9.0", "2.1.0"), specs)
  end

  def test_takes_none_when_the_gems_disagree
    specs = [spec("minitest", "6.0.6", prism: "~> 1.5"), spec("other", "1.0", prism: ">= 2")]
    assert_nil Branchout::PrismChoice.accepted(versions("1.9.0", "2.1.0"), specs)
  end

  # A bundle names its own prism, and a gem call outside it raises.
  def test_activates_nothing_inside_a_bundle
    out, err, status = activate_in_ruby("module Bundler; end", 'print Gem.loaded_specs.key?("prism")')
    assert status.success?, err
    assert_equal "false", out
  end

  # A second gem call for another version would raise.
  def test_keeps_a_prism_that_is_already_loaded
    out, err, status = activate_in_ruby('require "prism"; loaded = Prism::VERSION', "print loaded == Prism::VERSION")
    assert status.success?, err
    assert_equal "true", out
  end

  def activate_in_ruby(before, after)
    code = "#{before}; require 'branchout/prism_choice'; Branchout::PrismChoice.activate; #{after}"
    Open3.capture3(RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-e", code)
  end

  def test_a_development_dependency_does_not_count
    other = spec("other", "1.0")
    other.add_development_dependency "prism", ">= 2"
    assert_equal Gem::Version.new("1.9.0"), Branchout::PrismChoice.accepted(versions("1.9.0"), [other])
  end
end
