# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  # Outside a bundle the first require of prism activates the newest one,
  # and a target that then requires a gem pinned to an older prism, as
  # minitest 6 is to prism ~> 1.5, fails to activate that gem. The CLI
  # parses the target before it loads it, so it activates the newest prism
  # that the newest installed version of every gem accepts.
  module PrismChoice
    module_function

    #: () -> void
    def activate
      return if defined?(::Bundler) || Gem.loaded_specs.key?("prism")

      version = accepted(Gem::Specification.find_all_by_name("prism").map(&:version), Gem::Specification.to_a)
      gem "prism", "= #{version}" if version
    end

    #: (Array[Gem::Version], Array[Gem::Specification]) -> Gem::Version?
    def accepted(versions, specs)
      # steep:ignore:start
      # group_by makes no empty group, so max_by finds a spec in each.
      newest = specs.group_by(&:name).map { |_, same| same.max_by(&:version) } #: Array[Gem::Specification]
      # steep:ignore:end
      wanted = newest.flat_map { |spec| spec.runtime_dependencies.select { |dep| dep.name == "prism" }.map(&:requirement) }
      versions.select { |version| wanted.all? { |requirement| requirement.satisfied_by?(version) } }.max
    end
  end
end
