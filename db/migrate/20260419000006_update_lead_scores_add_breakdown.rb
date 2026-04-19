# frozen_string_literal: true

class UpdateLeadScoresAddBreakdown < ActiveRecord::Migration[8.0]
  def change
    change_table :lead_scores, bulk: true do |t|
      t.string :band
      t.jsonb  :breakdown, default: {}
    end
  end
end
