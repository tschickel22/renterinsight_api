class AddSmsOptInIfMissing < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:leads, :opt_in_sms) || column_exists?(:leads, :sms_opt_in)
      add_column :leads, :opt_in_sms, :boolean, default: false, null: false
      add_index :leads, :opt_in_sms
    end
    unless column_exists?(:contacts, :opt_in_sms) || column_exists?(:contacts, :sms_opt_in)
      add_column :contacts, :opt_in_sms, :boolean, default: false, null: false
      add_index :contacts, :opt_in_sms
    end
  end
end
