class Template < ApplicationRecord
  # String-backed enum on the `template_type` column
  enum :template_type, { email: 'email', sms: 'sms' }

  validates :name, presence: true
  validates :template_type, presence: true
end
