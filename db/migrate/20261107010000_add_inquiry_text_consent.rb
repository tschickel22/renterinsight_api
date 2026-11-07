# Consent to texts about an inquiry, asked apart from marketing consent.
#
# Carriers rejected a texting campaign (Twilio 30913, 2026-11-06) because one
# checkbox asked for marketing and for conversational texts at once. Marketing
# consent has to be its own question. So forms get a second box, the
# submission keeps what the visitor saw, and the lead carries the answer for
# the Lead Assistant and the lead response play to check. opt_in_sms stays
# marketing only: campaign audiences select on it.
class AddInquiryTextConsent < ActiveRecord::Migration[8.0]
  def change
    add_column :intake_forms, :sms_consent_enabled, :boolean, default: true, null: false
    add_column :intake_forms, :sms_consent_text, :text
    add_column :intake_forms, :sms_consent_version, :string, default: 'v1', null: false

    add_column :intake_submissions, :sms_consent, :boolean, default: false, null: false
    add_column :intake_submissions, :sms_consent_text, :text
    add_column :intake_submissions, :sms_consent_at, :datetime

    add_column :leads, :sms_inquiry_consent, :boolean, default: false, null: false
    add_column :leads, :sms_inquiry_consent_at, :datetime
  end
end
