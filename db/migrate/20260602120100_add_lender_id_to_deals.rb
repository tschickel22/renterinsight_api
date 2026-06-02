# frozen_string_literal: true

class AddLenderIdToDeals < ActiveRecord::Migration[8.0]
  def change
    # Keep the existing denormalized lender_name string column; lender_id references
    # the new managed Lender list. A before_save on Deal mirrors lender.name into
    # lender_name so the reports (which read lender_name) keep working unchanged.
    add_reference :deals, :lender, null: true, foreign_key: true, index: true
  end
end
