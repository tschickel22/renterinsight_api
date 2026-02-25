class AddDeliveryFieldsToAgreements < ActiveRecord::Migration[8.0]
  def change
    add_column :agreements, :delivery_method, :string, default: 'email', null: false
    add_column :agreements, :signing_order, :string, default: 'parallel', null: false
    add_column :agreements, :message_to_signers, :text
  end
end
