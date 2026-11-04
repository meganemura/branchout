# frozen_string_literal: true

class FixtureLedger
  CLOSED = "closed"
  LIMIT = 500

  def label(code, cents)
    return :closed if closed?(code)
    return :held if held?(code)
    return :large if large?(cents)

    :open
  end

  private

  def closed?(value) = value == CLOSED

  def held?(state) = state == "held"

  def large?(amount) = amount > LIMIT
end
