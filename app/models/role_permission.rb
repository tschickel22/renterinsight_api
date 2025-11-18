# frozen_string_literal: true

# RolePermission Model
# 
# Junction table that connects roles to specific permissions.
# Each permission is defined as a combination of:
# - Resource (what)
# - Action (how)
# - Scope (where)
# - Granted (allowed or denied)

class RolePermission < ApplicationRecord
  # Associations
  belongs_to :role
  belongs_to :resource
  belongs_to :action
  belongs_to :scope

  # Validations
  validates :role_id, presence: true
  validates :resource_id, presence: true
  validates :action_id, presence: true
  validates :scope_id, presence: true
  validates :role_id, uniqueness: { 
    scope: [:resource_id, :action_id, :scope_id],
    message: 'already has this permission defined'
  }

  # Scopes
  scope :granted, -> { where(granted: true) }
  scope :denied, -> { where(granted: false) }
  scope :for_role, ->(role_id) { where(role_id: role_id) }
  scope :for_resource, ->(resource_key) { joins(:resource).where(resources: { key: resource_key }) }
  scope :for_action, ->(action_key) { joins(:action).where(actions: { key: action_key }) }
  scope :for_scope, ->(scope_key) { joins(:scope).where(scopes: { key: scope_key }) }

  # Callbacks
  after_save :invalidate_cache
  after_destroy :invalidate_cache

  # Instance methods
  def permission_string
    "#{resource.key}:#{action.key}:#{scope.key}"
  end

  def to_h
    {
      resource: resource.key,
      action: action.key,
      scope: scope.key,
      granted: granted
    }
  end

  private

  def invalidate_cache
    # Invalidate permission cache for all users with this role
    role.users.each do |user|
      Rails.cache.delete_matched("permissions:#{user.id}:*")
    end
  end
end
