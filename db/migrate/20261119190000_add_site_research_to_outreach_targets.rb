# frozen_string_literal: true

# What we learned from a retailer's own website before the first message
# (backlog E105): the facts the opener may use and the summary noted on the lead.
class AddSiteResearchToOutreachTargets < ActiveRecord::Migration[8.0]
  def change
    add_column :outreach_targets, :site_research, :jsonb
  end
end
