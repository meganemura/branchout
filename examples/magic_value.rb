# frozen_string_literal: true

module MagicValue
  def self.classify(x)
    if x == 114514
      :magic
    else
      :ordinary
    end
  end
end
