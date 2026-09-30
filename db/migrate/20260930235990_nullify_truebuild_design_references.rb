# frozen_string_literal: true

# A saved design points at the lead, contact, account, deal, quote, home and
# intake submission it belongs to. Deleting any of those used to fail on the
# foreign key (a 500 deleting a deal or contact that had a design); the
# design now simply loses that link.
class NullifyTruebuildDesignReferences < ActiveRecord::Migration[8.0]
  REFS = { lead: :leads, contact: :contacts, account: :accounts, deal: :deals, quote: :quotes,
           vehicle: :vehicles, intake_submission: :intake_submissions }.freeze

  def up
    REFS.each do |column, table|
      remove_foreign_key :truebuild_designs, table, column: "#{column}_id" if foreign_key_exists?(:truebuild_designs, table, column: "#{column}_id")
      add_foreign_key :truebuild_designs, table, column: "#{column}_id", on_delete: :nullify
    end
  end

  def down
    REFS.each do |column, table|
      remove_foreign_key :truebuild_designs, table, column: "#{column}_id"
      add_foreign_key :truebuild_designs, table, column: "#{column}_id"
    end
  end
end
