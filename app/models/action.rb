# frozen_string_literal: true

# Action Model
# 
# Represents system-defined actions that can be performed on resources.
# Actions are platform-level and seeded by migrations.
# 
# Examples: 'create', 'read', 'update', 'delete', 'export', 'manage', etc.

class Action < ApplicationRecord
  # Associations
  has_many :role_permissions, dependent: :destroy
  has_many :roles, through: :role_permissions

  # Validations
  validates :key, presence: true, uniqueness: true, length: { maximum: 100 }
  validates :name, presence: true

  # Class methods
  def self.seed_defaults
    [
      { key: 'create', name: 'Create', description: 'Add new records' },
      { key: 'read', name: 'Read', description: 'View existing records' },
      { key: 'update', name: 'Update', description: 'Edit existing records' },
      { key: 'delete', name: 'Delete', description: 'Remove or archive records' },
      { key: 'export', name: 'Export', description: 'Download data as CSV/PDF' },
      { key: 'import', name: 'Import', description: 'Bulk upload data' },
      { key: 'manage', name: 'Manage Settings', description: 'Configure resource settings' },
      { key: 'assign', name: 'Assign Access', description: 'Grant access to other users' },
      { key: 'view_pii', name: 'View PII', description: 'Access sensitive personal information' },
      { key: 'approve', name: 'Approve', description: 'Approve requests and workflows' }
    ].each do |action_data|
      find_or_create_by!(key: action_data[:key]) do |action|
        action.name = action_data[:name]
        action.description = action_data[:description]
      end
    end
  end
end
