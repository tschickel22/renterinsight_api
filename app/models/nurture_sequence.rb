class NurtureSequence < ApplicationRecord
  belongs_to :company, optional: true
  
  has_many :nurture_steps, dependent: :destroy
  has_many :steps, class_name: 'NurtureStep', dependent: :destroy
  has_many :nurture_enrollments, dependent: :delete_all
  
  # Scope to company for tenant isolation
  scope :for_company, ->(company_id) { where(company_id: company_id) }
end
