# frozen_string_literal: true

class FixtureCart
  def initialize(currency = "JPY")
    @currency = currency
    @items = []
  end

  def add(name, quantity, price: 100)
    raise ArgumentError, "quantity must be positive" unless quantity.positive?
    raise ArgumentError, "cart is full" if size + quantity > 20

    @items << [name, quantity, price]
    self
  end

  def volume_discount_cents
    if size >= 10
      500
    elsif size >= 3
      100
    else
      0
    end
  end

  def size
    @items.empty? ? 0 : @items.sum { |_name, quantity, _price| quantity }
  end
end
