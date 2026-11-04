# frozen_string_literal: true

module Branchout
  # Outside a bundle the first require of prism activates the newest one,
  # and a target that then requires a gem pinned to an older prism, as
  # minitest 6 is to prism ~> 1.5, fails to activate that gem. The CLI
  # parses the target before it loads it, so it activates the newest prism
  # that the newest installed version of every gem accepts.
  module PrismChoice
    module_function

    def activate
      return if defined?(::Bundler) || Gem.loaded_specs.key?("prism")

      version = accepted(Gem::Specification.find_all_by_name("prism").map(&:version), Gem::Specification.to_a)
      gem "prism", "= #{version}" if version
    end

    def accepted(versions, specs)
      newest = specs.group_by(&:name).map { |_, same| same.max_by(&:version) }
      wanted = newest.flat_map { |spec| spec.runtime_dependencies.select { |dep| dep.name == "prism" }.map(&:requirement) }
      versions.select { |version| wanted.all? { |requirement| requirement.satisfied_by?(version) } }.max
    end
  end
end
