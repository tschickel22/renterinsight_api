class AgreementCategory < ApplicationRecord
  belongs_to :company

  # Validations
  validates :name, presence: true
  validates :name, uniqueness: { scope: :company_id, conditions: -> { where(is_deleted: [false, nil]) }, message: 'already exists' }
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/, message: 'must be a valid hex color' }, allow_blank: true

  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :ordered, -> { order(:position, :name) }
  scope :system_categories, -> { where(is_system: true) }

  # Prevent deleting system categories
  before_destroy :prevent_system_delete

  SYSTEM_CATEGORIES = [
    { name: 'Sales Agreement', color: '#2563EB', description: 'Purchase and sales contracts', position: 1 },
    { name: 'Service Contract', color: '#7C3AED', description: 'Service and maintenance agreements', position: 2 },
    { name: 'NDA', color: '#DC2626', description: 'Non-disclosure agreements', position: 3 },
    { name: 'Lease Agreement', color: '#059669', description: 'Property lease contracts', position: 4 },
    { name: 'Compliance', color: '#D97706', description: 'Regulatory and compliance documents', position: 5 },
    { name: 'Warranty', color: '#0891B2', description: 'Warranty terms and claims', position: 6 },
    { name: 'Employment', color: '#4F46E5', description: 'Employment and contractor agreements', position: 7 },
    { name: 'General', color: '#6B7280', description: 'Uncategorized agreements', position: 8 },
  ].freeze

  def self.seed_defaults_for_company(company)
    SYSTEM_CATEGORIES.each do |cat_data|
      company.agreement_categories.find_or_create_by!(name: cat_data[:name]) do |cat|
        cat.color = cat_data[:color]
        cat.description = cat_data[:description]
        cat.position = cat_data[:position]
        cat.is_system = true
      end
    end
  end

  private

  def prevent_system_delete
    if is_system?
      errors.add(:base, 'Cannot delete system categories')
      throw(:abort)
    end
  end
end
