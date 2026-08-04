# frozen_string_literal: true

# sms_opt_in is a TCPA consent flag, but on its own it records only the answer,
# not who gave it or how. If consent is ever challenged, "the boolean was true"
# is not a defensible record.
#
# These columns capture provenance so every opted-in contractor can be traced
# back to a source: the contractor flipping it themselves in the portal, or a
# dealer recording consent the contractor gave verbally or in a signed agreement.
class AddSmsConsentProvenanceToVendors < ActiveRecord::Migration[8.0]
  def change
    add_column :vendors, :sms_consent_source, :string
    add_column :vendors, :sms_consent_recorded_at, :datetime
    add_column :vendors, :sms_consent_recorded_by_id, :bigint
    add_column :vendors, :sms_consent_note, :text

    add_index :vendors, :sms_consent_recorded_by_id
    add_index :vendors, :sms_consent_source
  end
end
