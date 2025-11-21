class Source < ApplicationRecord
  belongs_to :company, optional: true
  has_many :leads, dependent: :nullify
  has_many :deals, dependent: :nullify
  
  scope :for_company, ->(company_id) { where(company_id: [company_id, nil]) }
  scope :active, -> { where(is_active: [true, nil]) }
end
