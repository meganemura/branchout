# frozen_string_literal: true

# A helper that loads the model with Kernel#load, as Rails loads an
# initializer, so the model is not in $LOADED_FEATURES.
require_relative "../suite/active_record"
load File.expand_path("../suite/pantry.rb", __dir__)
