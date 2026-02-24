class AddMergeFieldPlacementsToAgreements < ActiveRecord::Migration[8.0]
  def change
    add_column :agreements, :merge_field_placements, :jsonb, default: []
  end
end
