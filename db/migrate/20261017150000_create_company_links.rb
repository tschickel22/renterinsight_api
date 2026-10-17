# frozen_string_literal: true

# E68 step 5: a dealer links a vendor to the installer's own company, hands it
# projects or phases, and gets status back. Every crossing is logged.
class CreateCompanyLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :company_links do |t|
      t.references :dealer_company, null: false, foreign_key: { to_table: :companies }
      t.references :installer_company, foreign_key: { to_table: :companies } # set when accepted
      t.references :dealer_vendor, null: false, foreign_key: { to_table: :vendors }
      t.string :status, null: false, default: 'invited' # invited, active, ended
      t.string :invite_email, null: false
      t.references :invited_by, foreign_key: { to_table: :users }
      t.references :accepted_by, foreign_key: { to_table: :users }
      t.datetime :accepted_at
      t.string :agreement_version
      t.datetime :dealer_agreed_at
      t.datetime :installer_agreed_at
      t.references :installer_dealer_account, foreign_key: { to_table: :accounts } # the dealer as the installer's customer
      t.datetime :ended_at
      t.references :ended_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :company_links, %i[dealer_company_id installer_company_id], unique: true,
              where: 'installer_company_id IS NOT NULL', name: 'index_company_links_on_pair'
    add_index :company_links, :dealer_vendor_id, unique: true, where: "status <> 'ended'", name: 'index_company_links_on_open_vendor'

    create_table :project_links do |t|
      t.references :company_link, null: false, foreign_key: true
      t.references :dealer_company, null: false, foreign_key: { to_table: :companies }
      t.references :installer_company, null: false, foreign_key: { to_table: :companies }
      t.references :dealer_project, null: false, foreign_key: { to_table: :projects }
      t.references :dealer_phase, foreign_key: { to_table: :project_phases } # nil: the whole project
      t.references :installer_project, foreign_key: { to_table: :projects }
      t.string :status, null: false, default: 'offered' # offered, accepted, declined, cancelled, done
      t.decimal :fee_amount, precision: 12, scale: 2
      t.text :note
      t.references :offered_by, foreign_key: { to_table: :users }
      t.datetime :offered_at
      t.references :responded_by, foreign_key: { to_table: :users }
      t.datetime :responded_at
      t.text :decline_reason
      t.references :dealer_cost_item, foreign_key: { to_table: :project_cost_items }
      t.references :installer_invoice, foreign_key: { to_table: :invoices }
      t.references :dealer_bill, foreign_key: { to_table: :bills }
      t.timestamps
    end
    add_index :project_links, %i[installer_company_id status]

    create_table :project_link_phases do |t|
      t.references :project_link, null: false, foreign_key: true
      t.references :dealer_phase, null: false, foreign_key: { to_table: :project_phases }, index: { unique: true }
      t.references :installer_phase, foreign_key: { to_table: :project_phases }, index: { unique: true }
      t.timestamps
    end

    create_table :company_link_events do |t|
      t.references :company_link, null: false, foreign_key: true
      t.references :project_link, foreign_key: true
      t.references :company, foreign_key: true # whose action
      t.references :user, foreign_key: true
      t.string :kind, null: false
      t.string :summary, null: false
      t.jsonb :data, null: false, default: {}
      t.datetime :created_at, null: false
    end
  end
end
