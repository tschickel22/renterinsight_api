# frozen_string_literal: true

class UnifyContractorsAndSuppliersIntoVendors < ActiveRecord::Migration[8.0]
  # Unifies the legacy `contractors` and `suppliers` tables into a single
  # `vendors` table. Contractors and Suppliers become STI-style alias
  # subclasses of Vendor, distinguished by `vendor_type`.
  #
  # Strategy:
  #   1. Rename contractors -> vendors (preserves IDs, sequences, and FKs from
  #      the contractor side).
  #   2. Add columns from the suppliers schema that contractors lacked
  #      (addresses, code, payment_terms, qb_vendor_id, etc.) plus net-new
  #      accounting columns (vendor_type, is_1099_eligible, default_expense_account_id).
  #   3. Rename contractor_id -> vendor_id in all referencing tables.
  #   4. Rename bills.supplier_id -> bills.vendor_id (clean rename: bills is
  #      net-new in this branch).
  #   5. Insert one vendor row per supplier row (vendor_type='supplier'),
  #      copying fields including suppliers.custom_fields -> vendors.custom_field_values.
  #   6. Cutover: remap the supplier_id values in purchase_orders, recurring_bills,
  #      supplier_parts, and the polymorphic agreement_* tables to point at
  #      the new vendor IDs. After this, the `Supplier < Vendor` alias resolves
  #      correctly through these FKs.
  #   7. On purchase_orders and recurring_bills, also add a parallel vendor_id
  #      column (same values as the remapped supplier_id) so callers can
  #      gradually move to the new column name. supplier_parts gets no parallel
  #      column per ops decision.
  #   8. Polymorphic types Supplier -> Vendor on agreement_signers and
  #      agreement_attachments (STI uses base class name).
  #
  # The `suppliers` table is left in place but becomes a dead reference table
  # (its `vendor_id` column tracks the migration link). A follow-up migration
  # can drop it once nothing reads from it.
  def up
    # ------------------------------------------------------------------
    # 1. Rename contractors -> vendors (idempotent: skip if already done)
    # ------------------------------------------------------------------
    if table_exists?(:contractors) && !table_exists?(:vendors)
      rename_table :contractors, :vendors
    end

    # ------------------------------------------------------------------
    # 2. Add vendor_type discriminator
    # ------------------------------------------------------------------
    add_column :vendors, :vendor_type, :string, default: 'contractor', null: false unless column_exists?(:vendors, :vendor_type)
    add_index :vendors, :vendor_type unless index_exists?(:vendors, :vendor_type)

    # ------------------------------------------------------------------
    # 3. Add columns from the suppliers schema that contractors lacked
    # ------------------------------------------------------------------
    add_column :vendors, :code, :string                               unless column_exists?(:vendors, :code)
    add_column :vendors, :website, :string                            unless column_exists?(:vendors, :website)
    add_column :vendors, :address_line1, :string                      unless column_exists?(:vendors, :address_line1)
    add_column :vendors, :address_line2, :string                      unless column_exists?(:vendors, :address_line2)
    add_column :vendors, :city, :string                               unless column_exists?(:vendors, :city)
    add_column :vendors, :state, :string                              unless column_exists?(:vendors, :state)
    add_column :vendors, :zip_code, :string                           unless column_exists?(:vendors, :zip_code)
    add_column :vendors, :country, :string, default: 'US'             unless column_exists?(:vendors, :country)
    add_column :vendors, :tax_id, :string                             unless column_exists?(:vendors, :tax_id)
    add_column :vendors, :payment_terms, :string                      unless column_exists?(:vendors, :payment_terms)
    add_column :vendors, :default_lead_time_days, :integer            unless column_exists?(:vendors, :default_lead_time_days)
    add_column :vendors, :qb_vendor_id, :string                       unless column_exists?(:vendors, :qb_vendor_id)
    add_column :vendors, :active, :boolean, default: true             unless column_exists?(:vendors, :active)
    add_column :vendors, :deleted_at, :datetime                       unless column_exists?(:vendors, :deleted_at)
    add_column :vendors, :created_by_id, :bigint                      unless column_exists?(:vendors, :created_by_id)
    add_column :vendors, :updated_by_id, :bigint                      unless column_exists?(:vendors, :updated_by_id)
    add_column :vendors, :account_number, :string                     unless column_exists?(:vendors, :account_number)

    # Net-new accounting columns
    add_column :vendors, :is_1099_eligible, :boolean, default: false  unless column_exists?(:vendors, :is_1099_eligible)
    add_column :vendors, :default_expense_account_id, :bigint         unless column_exists?(:vendors, :default_expense_account_id)
    add_index :vendors, :default_expense_account_id unless index_exists?(:vendors, :default_expense_account_id)
    add_index :vendors, :qb_vendor_id  unless index_exists?(:vendors, :qb_vendor_id)

    # Backfill `active` from contractor `status` (per ops decision: status is
    # canonical, active is a back-compat boolean for supplier code paths).
    execute <<~SQL
      UPDATE vendors
      SET active = (status = 'active' AND (is_deleted IS NULL OR is_deleted = false))
      WHERE vendor_type = 'contractor'
    SQL

    # ------------------------------------------------------------------
    # 4. Rename contractor_id -> vendor_id in all referencing tables
    # ------------------------------------------------------------------
    %i[contractor_assignments assignment_work_logs project_cost_items].each do |table|
      next unless column_exists?(table, :contractor_id)

      if foreign_key_exists?(table, column: :contractor_id)
        remove_foreign_key table, column: :contractor_id
      end
      rename_column table, :contractor_id, :vendor_id
      add_foreign_key table, :vendors, column: :vendor_id, on_delete: :nullify rescue nil
    end

    # ------------------------------------------------------------------
    # 5. Rename bills.supplier_id -> bills.vendor_id (bills is net-new this branch)
    # ------------------------------------------------------------------
    if column_exists?(:bills, :supplier_id)
      if foreign_key_exists?(:bills, column: :supplier_id)
        remove_foreign_key :bills, column: :supplier_id
      end
      rename_column :bills, :supplier_id, :vendor_id
      add_foreign_key :bills, :vendors, column: :vendor_id, on_delete: :nullify rescue nil
    end

    # ------------------------------------------------------------------
    # 6. Add vendor_id to suppliers for migration tracking
    # ------------------------------------------------------------------
    add_column :suppliers, :vendor_id, :bigint unless column_exists?(:suppliers, :vendor_id)
    add_index :suppliers, :vendor_id           unless index_exists?(:suppliers, :vendor_id)

    # ------------------------------------------------------------------
    # 7. Insert supplier rows into vendors (vendor_type='supplier')
    #    Skip if a vendor with same company_id + same lowered name already
    #    exists for vendor_type='supplier' (idempotency for re-runs).
    # ------------------------------------------------------------------
    execute <<~SQL
      INSERT INTO vendors (
        company_id, name, vendor_type,
        contact_name, email, phone,
        code, website, address_line1, address_line2, city, state, zip_code, country,
        tax_id, notes, payment_terms, account_number, default_lead_time_days, qb_vendor_id,
        active, status, is_deleted, deleted_at, custom_field_values,
        created_by_id, updated_by_id, created_at, updated_at
      )
      SELECT
        s.company_id, s.name, 'supplier',
        s.contact_name, s.email, s.phone,
        s.code, s.website, s.address_line1, s.address_line2, s.city, s.state, s.zip_code, s.country,
        s.tax_id, s.notes, s.payment_terms, s.account_number, s.default_lead_time_days, s.qb_vendor_id,
        s.active, CASE WHEN s.active THEN 'active' ELSE 'inactive' END, s.is_deleted, s.deleted_at, COALESCE(s.custom_fields, '{}'::jsonb),
        s.created_by_id, s.updated_by_id, s.created_at, s.updated_at
      FROM suppliers s
      WHERE NOT EXISTS (
        SELECT 1 FROM vendors v
        WHERE v.company_id = s.company_id
          AND LOWER(v.name) = LOWER(s.name)
          AND v.vendor_type = 'supplier'
      )
    SQL

    # ------------------------------------------------------------------
    # 8. Link suppliers.vendor_id to the new vendor row
    # ------------------------------------------------------------------
    execute <<~SQL
      UPDATE suppliers s
      SET vendor_id = v.id
      FROM vendors v
      WHERE v.company_id = s.company_id
        AND LOWER(v.name) = LOWER(s.name)
        AND v.vendor_type = 'supplier'
        AND s.vendor_id IS NULL
    SQL

    # ------------------------------------------------------------------
    # 9. Cutover: remap supplier_id values across all referencing tables
    #    so they point at the new vendor IDs. After this, the
    #    Supplier < Vendor alias resolves these FKs correctly.
    # ------------------------------------------------------------------

    # purchase_orders: drop old FK to suppliers, remap supplier_id, add parallel vendor_id
    if foreign_key_exists?(:purchase_orders, column: :supplier_id)
      remove_foreign_key :purchase_orders, column: :supplier_id
    end
    execute <<~SQL
      UPDATE purchase_orders po
      SET supplier_id = s.vendor_id
      FROM suppliers s
      WHERE po.supplier_id = s.id AND s.vendor_id IS NOT NULL
    SQL
    add_column :purchase_orders, :vendor_id, :bigint unless column_exists?(:purchase_orders, :vendor_id)
    execute "UPDATE purchase_orders SET vendor_id = supplier_id"
    add_index :purchase_orders, :vendor_id unless index_exists?(:purchase_orders, :vendor_id)

    # recurring_bills: drop old FK to suppliers, remap supplier_id, add parallel vendor_id
    if table_exists?(:recurring_bills)
      if foreign_key_exists?(:recurring_bills, column: :supplier_id)
        remove_foreign_key :recurring_bills, column: :supplier_id
      end
      execute <<~SQL
        UPDATE recurring_bills rb
        SET supplier_id = s.vendor_id
        FROM suppliers s
        WHERE rb.supplier_id = s.id AND s.vendor_id IS NOT NULL
      SQL
      add_column :recurring_bills, :vendor_id, :bigint unless column_exists?(:recurring_bills, :vendor_id)
      execute "UPDATE recurring_bills SET vendor_id = supplier_id WHERE supplier_id IS NOT NULL"
      add_index :recurring_bills, :vendor_id unless index_exists?(:recurring_bills, :vendor_id)
    end

    # supplier_parts: drop old FK to suppliers, remap only, no parallel column
    if foreign_key_exists?(:supplier_parts, column: :supplier_id)
      remove_foreign_key :supplier_parts, column: :supplier_id
    end
    execute <<~SQL
      UPDATE supplier_parts sp
      SET supplier_id = s.vendor_id
      FROM suppliers s
      WHERE sp.supplier_id = s.id AND s.vendor_id IS NOT NULL
    SQL

    # ------------------------------------------------------------------
    # 10. Polymorphic agreement_* — rewrite type to base class name 'Vendor'
    #     and remap IDs from old supplier IDs to new vendor IDs.
    # ------------------------------------------------------------------
    execute <<~SQL
      UPDATE agreement_signers ag
      SET signable_type = 'Vendor', signable_id = s.vendor_id
      FROM suppliers s
      WHERE ag.signable_type = 'Supplier'
        AND ag.signable_id = s.id
        AND s.vendor_id IS NOT NULL
    SQL

    execute <<~SQL
      UPDATE agreement_attachments aa
      SET attachable_type = 'Vendor', attachable_id = s.vendor_id
      FROM suppliers s
      WHERE aa.attachable_type = 'Supplier'
        AND aa.attachable_id = s.id
        AND s.vendor_id IS NOT NULL
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Vendor unification is destructive (FK remap, polymorphic rewrite). ' \
          'Restore from backup if rollback is required.'
  end
end
