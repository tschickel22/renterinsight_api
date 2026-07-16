class AddCaptchaRequiredToIntakeForms < ActiveRecord::Migration[8.0]
  def change
    add_column :intake_forms, :captcha_required, :boolean, default: false, null: false
  end
end
