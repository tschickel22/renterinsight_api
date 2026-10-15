# frozen_string_literal: true

# TrueBuild intake forms made automatically (no play turned on) were created
# with nobody to notify, so their leads arrived unowned and unannounced. Give
# each one the company's first admin, as new ones now get. A form a dealer has
# already pointed at someone is left alone.
class DefaultTruebuildFormNotifiedUser < ActiveRecord::Migration[8.0]
  def up
    IntakeForm.where(name: Truebuild::DesignSaver::FORM_NAME, notified_user_id: nil).find_each do |form|
      admin = Truebuild::DesignSaver.default_notified_user(form.company)
      form.update_columns(notified_user_id: admin.id, updated_at: Time.current) if admin
    end
  end

  def down; end
end
