# frozen_string_literal: true

module Plays
  # The starter plays a dealer can turn on, by key.
  module Registry
    def self.all
      [Plays::NewLeadAnyChannel]
    end

    def self.find(key)
      all.find { |play| play::KEY == key.to_s }
    end
  end
end
