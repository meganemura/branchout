# frozen_string_literal: true

# A helper that .rspec requires, so it boots the app, and here loads the
# model, before the spec file's first line.
require_relative "../suite/active_record"
require_relative "../suite/pantry"
