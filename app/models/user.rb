# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password
  
  has_many :activities, dependent: :nullify
  has_many :reminders, dependent: :destroy

  validates :email, presence: true, uniqueness: true
  validates :first_name, presence: true, if: -> { name.blank? }
  validates :password, length: { minimum: 6 }, if: -> { password.present? }
  
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
end
