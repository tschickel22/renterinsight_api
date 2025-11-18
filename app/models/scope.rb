# frozen_string_literal: true

# Scope Model
# 
# Represents the scope or extent of access for a permission.
# Scopes are platform-level and seeded by migrations.
# 
# Examples: 'all' (company-wide), 'assigned_regions', 'assigned_locations', 'own'

class Scope < ApplicationRecord
  # Associations
  has_many :role_permissions, dependent: :destroy
  has_many :roles, through: :role_permissions

  # Validations
  validates :key, presence: true, uniqueness: true, length: { maximum: 100 }
  validates :name, presence: true

  # Class methods
  def self.seed_defaults
    [
      { key: 'all', name: 'All (Company-wide)', description: 'Access applies to entire company' },
      { key: 'assigned_regions', name: 'Assigned Regions', description: 'Access limited to regions user is assigned to' },
      { key: 'assigned_locations', name: 'Assigned Locations', description: 'Access limited to locations user is assigned to' },
      { key: 'own', name: 'Own Records Only', description: 'Access limited to records user created or owns' }
    ].each do |scope_data|
      find_or_create_by!(key: scope_data[:key]) do |scope|
        scope.name = scope_data[:name]
        scope.description = scope_data[:description]
      end
    end
  end
end
