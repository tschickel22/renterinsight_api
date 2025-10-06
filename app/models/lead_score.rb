# frozen_string_literal: true
class LeadScore < ApplicationRecord
  self.table_name = 'lead_scores'
  belongs_to :lead
end
