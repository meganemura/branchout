# frozen_string_literal: true

class FixtureGate
  def self.ready?(order)
    order[:paid] && !order[:cancelled] || order[:forced]
  end

  def self.allow?(user, force)
    user&.fetch(:admin) || force
  end

  def self.settle(options)
    options[:mode] ||= "auto"
    options[:trace] &&= options[:mode] == "debug"
    options
  end
end
