# frozen_string_literal: true

class FixtureAccount
  def initialize(balance, limit: 0)
    @balance = balance
    @limit = limit
  end

  def withdraw(amount)
    if amount > @balance + @limit
      :refused
    else
      @balance - amount
    end
  end
end
