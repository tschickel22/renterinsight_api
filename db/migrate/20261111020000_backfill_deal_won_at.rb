# Won and lost deals closed through Edit Deal, the pipeline board or the API
# never got won_at / lost_at (only mark_as_won set them), so dashboards that
# count won deals by won_at left them out (39 of 141 on production,
# 2026-11-10). Filled from the close date, using each company's own won and
# lost stages (custom pipelines name them differently).
class BackfillDealWonAt < ActiveRecord::Migration[8.0]
  def up
    Company.find_each do |company|
      deals = Deal.where(company_id: company.id, deleted_at: nil)
      deals.where(stage: company.won_stage_keys, won_at: nil)
           .update_all('won_at = COALESCE(actual_close_date::timestamp, gl_posted_at, updated_at)')
      deals.where(stage: company.lost_stage_keys, lost_at: nil)
           .update_all('lost_at = COALESCE(actual_close_date::timestamp, updated_at)')
    end
  end

  def down; end
end
