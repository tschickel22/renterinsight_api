# frozen_string_literal: true

class Lead < ApplicationRecord
  belongs_to :source, optional: true

  # Add the association so controllers can call @lead.activities
  has_many :activities, dependent: :destroy
end
