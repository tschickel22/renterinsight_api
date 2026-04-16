class AddSharingToReports < ActiveRecord::Migration[8.0]
  def change
    add_column :reports, :shared_user_ids, :jsonb, default: []
    add_index  :reports, :shared_user_ids, using: :gin
  end
end
