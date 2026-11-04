# frozen_string_literal: true

class Pantry
  attr_reader :owner

  def initialize(owner)
    @owner = owner
  end

  def stock(item)
    return :full if ActiveRecord::Base.rows.size >= 2

    ActiveRecord::Base.rows << [owner, item]
    ActiveRecord::Base.rows.size == 1 ? :first : :more
  end
end
