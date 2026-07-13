class BackfillEvangelineDepositAmount < ActiveRecord::Migration[8.0]
  # One-time backfill for Evangeline Home Center (company_id=17). They tracked
  # "Deposit Amount" as a custom field on leads/contacts/accounts/deals; we now
  # have a real `deposit_amount` column (deals uses the existing `down_payment`).
  # This copies their JSONB values into the new columns and deactivates the
  # custom fields. The JSONB keys are LEFT IN PLACE as a rollback window —
  # a later cleanup can strip them once we're confident.
  #
  # Deal tiebreak per user: custom value wins when both are set.
  disable_ddl_transaction!

  COMPANY_ID = 17
  CUSTOM_FIELD_IDS = [35, 36, 37, 38].freeze

  def up
    return unless Company.exists?(id: COMPANY_ID)

    # Leads
    Lead.where(company_id: COMPANY_ID)
        .where("custom_field_values ? 'deposit_amount'")
        .find_each do |lead|
      value = lead.custom_field_values['deposit_amount']
      next if value.blank?
      lead.update_columns(deposit_amount: value.to_d, updated_at: Time.current)
    end

    # Contacts
    Contact.where(company_id: COMPANY_ID)
           .where("custom_field_values ? 'deposit_amount'")
           .find_each do |contact|
      value = contact.custom_field_values['deposit_amount']
      next if value.blank?
      contact.update_columns(deposit_amount: value.to_d, updated_at: Time.current)
    end

    # Accounts
    Account.where(company_id: COMPANY_ID)
           .where("custom_field_values ? 'deposit_amount'")
           .find_each do |account|
      value = account.custom_field_values['deposit_amount']
      next if value.blank?
      account.update_columns(deposit_amount: value.to_d, updated_at: Time.current)
    end

    # Deals: custom value always wins (per Evangeline usage — the down_payment
    # column had stale import data, the custom field is what their team edits).
    Deal.where(company_id: COMPANY_ID)
        .where("custom_field_values ? 'deposit_amount'")
        .find_each do |deal|
      value = deal.custom_field_values['deposit_amount']
      next if value.blank?
      deal.update_columns(down_payment: value.to_d, updated_at: Time.current)
    end

    # Deactivate the four custom fields so the UI stops rendering them. The
    # JSONB values on each record are intentionally NOT stripped — that's the
    # rollback window.
    CustomField.where(id: CUSTOM_FIELD_IDS, company_id: COMPANY_ID).update_all(is_active: false)
  end

  def down
    # Reactivate the custom fields; leave the column values in place (they can
    # be cleared manually if needed — the JSONB source of truth still exists).
    CustomField.where(id: CUSTOM_FIELD_IDS, company_id: COMPANY_ID).update_all(is_active: true)
  end
end
