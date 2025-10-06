# frozen_string_literal: true
class AiInsight < ApplicationRecord
  self.table_name = 'ai_insights'
  belongs_to :lead

  scope :recent, -> { order(Arel.sql("COALESCE(generated_at, created_at) DESC")) }

  def mark_as_read!
    update!(is_read: true)
  end
end
