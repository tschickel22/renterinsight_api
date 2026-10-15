# frozen_string_literal: true

# Deal appointments get customer reminders and calendar invites like lead,
# contact and account appointments. Existing deal appointments stay off (the
# customer was never told); new ones default on.
class AddCustomerNoticesToDealActivities < ActiveRecord::Migration[8.0]
  def up
    add_column :deal_activities, :remind_customer, :boolean, default: false, null: false
    add_column :deal_activities, :send_calendar_invite, :boolean, default: false, null: false
    add_column :deal_activities, :customer_notices, :jsonb, default: {}, null: false
    change_column_default :deal_activities, :remind_customer, from: false, to: true
    change_column_default :deal_activities, :send_calendar_invite, from: false, to: true
  end

  def down
    remove_column :deal_activities, :customer_notices
    remove_column :deal_activities, :send_calendar_invite
    remove_column :deal_activities, :remind_customer
  end
end
