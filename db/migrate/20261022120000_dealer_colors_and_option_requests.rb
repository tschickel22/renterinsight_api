# frozen_string_literal: true

# A dealer's own option changes (backlog E85). A catalog option with
# company_id set is a dealer's own color, seen by no other dealer. Requests
# carry a dealer's added colors, hidden colors and renamed options to the
# platform admin, who applies them for everyone, keeps them for that dealer,
# or turns them down.
class DealerColorsAndOptionRequests < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_reference :catalog_options, :company, null: true, index: false
    add_index :catalog_options, :company_id, where: 'company_id IS NOT NULL', algorithm: :concurrently

    create_table :catalog_option_requests do |t|
      t.references :company, null: false, foreign_key: true
      t.references :manufacturer, null: false, foreign_key: true
      t.references :catalog_option, null: false, foreign_key: true
      t.string :action, null: false # add | hide | rename
      t.string :color_set
      # rename: the dealer's name for the option.
      t.string :name
      t.text :note
      t.references :deal, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: 'open' # open | applied | dealer_only | dismissed | withdrawn
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.datetime :resolved_at
      t.text :resolution_note
      t.timestamps
    end
    add_index :catalog_option_requests, %i[company_id status]
    add_index :catalog_option_requests, :status
  end
end
