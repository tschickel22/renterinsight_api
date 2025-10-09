# frozen_string_literal: true

class Lead < ApplicationRecord
  belongs_to :converted_account, class_name: "Account", optional: true
  belongs_to :source, class_name: "Source", optional: true

  # Core CRM associations
  has_many :activities,           dependent: :destroy
  has_many :reminders,            dependent: :destroy
  has_many :lead_activities,      dependent: :destroy
  has_many :ai_insights,          dependent: :destroy
  has_many :communication_logs,   dependent: :destroy

  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
end
