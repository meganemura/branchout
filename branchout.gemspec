# frozen_string_literal: true

require_relative "lib/branchout/version"

Gem::Specification.new do |spec|
  spec.name = "branchout"
  spec.version = Branchout::VERSION
  spec.summary = "Coverage-guided, agent-driven input exploration for Ruby"
  spec.description = <<~TEXT
    Runs a Ruby method on concrete inputs and reports branch arms that are still
    uncovered. An agent reads that frontier and proposes the next inputs.
    Branchout does not collect or solve symbolic path constraints.
  TEXT
  spec.authors = ["meganemura"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/meganemura/branchout"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*", "bin/*", "skills/**/*", "README.md", "README.ja.md", "AGENTS.md", "LICENSE", "examples/**/*"]
  spec.bindir = "bin"
  spec.executables = ["branchout"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rspec", "~> 3.13"
end
