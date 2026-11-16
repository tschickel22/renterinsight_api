# Credit applications and other forms that hold SSNs, birth dates and income.
# A template marked sensitive makes its agreements keep signer answers encrypted
# (sensitive_values, Rails encryption) and only until the signed PDF exists, and
# share them only for a limited time (share_until), as a password-locked PDF.
class AddSensitiveAnswersToAgreements < ActiveRecord::Migration[8.0]
  def change
    add_column :agreement_templates, :sensitive, :boolean, default: false, null: false
    add_column :agreements, :sensitive, :boolean, default: false, null: false
    add_column :agreements, :sensitive_values, :text
    add_column :agreements, :share_until, :datetime
  end
end
