# frozen_string_literal: true

# The part of ActiveRecord that explore uses: a transaction that a raised
# Rollback undoes.
module ActiveRecord
  Rollback = Class.new(StandardError)

  class Base
    def self.rows = (@rows ||= [])

    def self.transaction(requires_new: false)
      saved = rows.dup
      begin
        yield
      rescue Rollback
        rows.replace(saved)
        nil
      rescue Exception # rubocop:disable Lint/RescueException
        rows.replace(saved)
        raise
      end
    end
  end
end
