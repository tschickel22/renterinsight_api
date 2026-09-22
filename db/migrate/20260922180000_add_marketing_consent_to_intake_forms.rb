# frozen_string_literal: true

# Recipient consent, captured at the point of contact capture.
#
# Public lead forms recorded nothing about consent: a contact who had never
# agreed to anything was mailable as long as they had not previously opted out.
# Consent lives on the contact as a CommunicationPreference; these columns hold
# the form-side configuration and the exact wording each submitter was shown, so
# a consent record can be audited years later against the text that produced it.
class AddMarketingConsentToIntakeForms < ActiveRecord::Migration[8.0]
  def change
    change_table :intake_forms, bulk: true do |t|
      t.boolean :marketing_consent_enabled, default: true, null: false
      t.text    :marketing_consent_text
      t.string  :marketing_consent_version, default: 'v1', null: false
    end

    change_table :intake_submissions, bulk: true do |t|
      # Default false, never true: an unchecked box is the absence of consent,
      # and a backfilled row is a submission nobody was ever asked.
      t.boolean  :marketing_consent, default: false, null: false
      # The wording shown at submit time, copied rather than referenced, so
      # editing the form later cannot rewrite what someone already agreed to.
      t.text     :marketing_consent_text
      t.datetime :marketing_consent_at
    end
  end
end
