class AddVisibilityToReports < ActiveRecord::Migration[8.0]
  def change
    add_column :reports, :visibility, :string
  end
end
