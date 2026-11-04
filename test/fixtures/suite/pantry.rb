# frozen_string_literal: true

require_relative "shelf_label"

class Pantry
  include ShelfLabel

  attr_reader :owner

  def initialize(owner)
    @owner = owner
  end

  def stock(item)
    return :full if ActiveRecord::Base.rows.size >= 2

    ActiveRecord::Base.rows << [owner, label(item)]
    ActiveRecord::Base.rows.size == 1 ? :first : :more
  end

  def restock(item)
    ActiveRecord::Base.rows << [owner, item]
    item << " (restocked)"
    ActiveRecord::Base.rows.size == 1 ? :first : :more
  end
end
