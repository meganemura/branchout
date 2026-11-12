# frozen_string_literal: true

# The environment of a command that runs outside this bundle. The tests run
# in parallel threads and ENV belongs to the whole process, so a test hands
# this to the command and never swaps ENV with Bundler.with_unbundled_env,
# which let another test start its Ruby without the bundle.
module Unbundled
  module_function

  # The child's Gemfile lives elsewhere and reads no .bundle/config of this
  # checkout, so the install path CI set there is passed on explicitly. A
  # variable the bundle set maps to nil, which unsets it in the child.
  def env(extra)
    return extra unless defined?(Bundler)

    path = Bundler.settings[:path]
    base = Bundler.unbundled_env
    base = base.merge("BUNDLE_PATH" => File.expand_path(path, Bundler.root)) if path
    ENV.keys.to_h { |key| [key, nil] }.merge(base, extra)
  end
end
