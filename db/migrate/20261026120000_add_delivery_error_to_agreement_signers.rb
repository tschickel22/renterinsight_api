# Why the last invite or reminder to this signer did not go out, so the agreement
# page can say so instead of it living only in the worker log. Cleared by the next
# delivery that gets through on every channel.
class AddDeliveryErrorToAgreementSigners < ActiveRecord::Migration[8.0]
  def change
    add_column :agreement_signers, :delivery_error, :text
    add_column :agreement_signers, :delivery_error_at, :datetime
  end
end
