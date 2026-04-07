class AllowNullSourceIdOnLeads < ActiveRecord::Migration[8.0]
  def change
    change_column_null :leads, :source_id, true
  end
end
