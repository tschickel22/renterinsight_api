# frozen_string_literal: true

class Lead < ApplicationRecord
  belongs_to :source, optional: true

  # Add this association so Lead has .activities
  has_many :activities, dependent: :destroy
end
