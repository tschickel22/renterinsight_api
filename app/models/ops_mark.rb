# frozen_string_literal: true

# A named time: when an alert last went out ("alert:<key>"), when background
# jobs last checked in ("heartbeat:jobs").
class OpsMark < ApplicationRecord
  def self.at(key)
    find_by(key: key)&.at
  end

  def self.stamp!(key, note: nil, at: Time.current)
    upsert({ key: key, at: at, note: note&.first(250) }, unique_by: :key)
  end
end
