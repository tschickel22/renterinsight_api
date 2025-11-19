# frozen_string_literal: true

# CompanyHiddenRole Model
# 
# Join table tracking which system roles a company wants to hide from their UI.
# This allows per-company role visibility without affecting other companies
# or modifying the system roles themselves.

class CompanyHiddenRole < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :role

  # Validations
  validates :company_id, presence: true
  validates :role_id, presence: true
  validates :role_id, uniqueness: { scope: :company_id, message: 'is already hidden for this company' }

  # Scopes
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :for_role, ->(role_id) { where(role_id: role_id) }

  # Class methods
  def self.hide_role_for_company(company_id, role_id)
    find_or_create_by!(company_id: company_id, role_id: role_id)
  end

  def self.show_role_for_company(company_id, role_id)
    where(company_id: company_id, role_id: role_id).destroy_all
  end

  def self.hidden_role_ids_for_company(company_id)
    where(company_id: company_id).pluck(:role_id)
  end

  def self.role_hidden_for_company?(company_id, role_id)
    exists?(company_id: company_id, role_id: role_id)
  end
end
