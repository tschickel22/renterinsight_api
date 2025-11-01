# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password
  
  # Associations
  belongs_to :company, optional: true
  belongs_to :invitation, optional: true
  has_many :activities, dependent: :nullify
  has_many :reminders, dependent: :destroy

  validates :email, presence: true, uniqueness: true
  validates :first_name, presence: true, if: -> { name.blank? }
  validates :password, length: { minimum: 6 }, if: -> { password.present? }
  
  # Soft delete scopes
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  scope :with_deleted, -> { unscope(where: :deleted_at) }
  
  # Default scope to exclude deleted users
  default_scope { where(deleted_at: nil) }
  
  # Virtual attribute for full name (backward compatibility with 'name' field)
  def name
    if first_name.present? && last_name.present?
      "#{first_name} #{last_name}"
    else
      read_attribute(:name) || first_name || last_name || email
    end
  end
  
  # Status helpers
  def inactive?
    status == 'inactive'
  end
  
  def suspended?
    status == 'suspended'
  end
  
  def active?
    status == 'active'
  end
  
  # Role helpers
  def admin?
    role == 'admin' || role == 'super_admin'
  end
  
  def client?
    role == 'client' || role == 'buyer'
  end
  
  def staff?
    role == 'staff' || role == 'employee'
  end
  
  # Soft delete methods
  def soft_delete!(reason: nil)
    update!(deleted_at: Time.current, deleted_reason: reason)
  end
  
  def restore!
    update!(deleted_at: nil, deleted_reason: nil)
  end
  
  def deleted?
    deleted_at.present?
  end
  
  # MFA helper methods
  def mfa_enabled?
    mfa_enabled == true
  end
end
