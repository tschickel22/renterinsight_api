# frozen_string_literal: true
class Tag < ApplicationRecord
  # Controllers use: name, description, color, category, tag_type (array/json), is_system, is_active
  scope :active, -> { where(is_active: [true, nil]) } # treat nil as active for legacy rows
end
