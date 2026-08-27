# frozen_string_literal: true

# Find & merge duplicates for Leads, Contacts and Accounts.
#
# merged_into_id is the single signal that a record lost a merge. It is used
# instead of the existing soft-delete columns because those are inconsistent
# across the three tables: leads have no is_deleted at all and are hard
# deleted, contacts have is_deleted, accounts have is_deleted, deleted_at and
# status. One uniform column means the scopes and the API do not have to branch
# per entity, and it keeps the survivor reachable so an old link, a bookmark or
# an integration id can be redirected rather than 404.
class AddMergeTrackingToCrmEntities < ActiveRecord::Migration[8.0]
  def change
    %i[leads contacts accounts].each do |table|
      add_column table, :merged_into_id, :bigint
      add_column table, :merged_at,      :datetime
      add_column table, :merged_by_id,   :bigint

      # Every list query filters merged records out, so it belongs beside company_id.
      add_index table, %i[company_id merged_into_id],
                name: "index_#{table}_on_company_id_and_merged_into"
      add_index table, :merged_into_id, name: "index_#{table}_on_merged_into_id"
    end
  end
end
