# frozen_string_literal: true

class ActivityLog < ApplicationRecord
  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :trackable, polymorphic: true, optional: true
  belongs_to :account, optional: true
  belongs_to :location, optional: true

  validates :action, :module_name, :description, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user_id) { where(user_id: user_id) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }
  scope :for_module, ->(mod) { where(module_name: mod) }
  scope :for_action, ->(action) { where(action: action) }
  scope :for_date_range, ->(start_date, end_date) { where(created_at: start_date..end_date) }
end
