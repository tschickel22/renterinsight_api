class AddProjectIdToDeals < ActiveRecord::Migration[8.0]
  def change
    add_reference :deals, :project, foreign_key: true, null: true
    add_index :deals, [:company_id, :project_id], name: 'idx_deals_company_project'
  end
end
