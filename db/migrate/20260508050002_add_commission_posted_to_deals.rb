# frozen_string_literal: true

class AddCommissionPostedToDeals < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:deals, :commission_posted)
      add_column :deals, :commission_posted, :boolean, default: false, null: false
    end

    unless column_exists?(:deals, :commission_posted_at)
      add_column :deals, :commission_posted_at, :datetime
    end

    unless column_exists?(:deals, :commission_journal_entry_id)
      add_column :deals, :commission_journal_entry_id, :bigint
    end
  end
end
