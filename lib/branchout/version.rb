# frozen_string_literal: true
# rbs_inline: enabled

# The gemspec reads only this file. Bundler loads the gemspec in every
# process of a project that depends on branchout by path, and a file it
# loads has no arms when explore targets it.
module Branchout
  VERSION = "0.2.0" #: String
end
