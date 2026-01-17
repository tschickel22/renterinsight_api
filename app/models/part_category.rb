# frozen_string_literal: true

class PartCategory < ApplicationRecord
  include Customizable
  
  # Associations
  belongs_to :company
  belongs_to :parent, class_name: 'PartCategory', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true
  
  has_many :children, class_name: 'PartCategory', foreign_key: 'parent_id', dependent: :nullify
  has_many :parts, foreign_key: 'category_id', dependent: :nullify
  
  # Validations
  validates :company_id, presence: true
  validates :name, presence: true, length: { maximum: 255 }
  validates :name, uniqueness: { scope: :company_id, conditions: -> { where(is_deleted: false) } }
  
  # Prevent circular parent references
  validate :parent_cannot_be_self
  validate :parent_cannot_be_descendant
  
  # Scopes
  scope :active, -> { where(active: true, is_deleted: false) }
  scope :top_level, -> { where(parent_id: nil) }
  scope :for_company, ->(company_id) { where(company_id: company_id, is_deleted: false) }
  scope :by_name, -> { order(:name) }
  
  # Callbacks
  before_validation :normalize_fields
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, active: false)
    # Also soft delete children
    children.each(&:soft_delete!)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Display helpers
  def display_name
    name
  end
  
  def full_path
    path = [name]
    current = parent
    while current.present?
      path.unshift(current.name)
      current = current.parent
    end
    path.join(' > ')
  end
  
  # Check if this category has any parts or children
  def has_parts?
    parts.where(is_deleted: false).exists?
  end
  
  def has_children?
    children.where(is_deleted: false).exists?
  end
  
  def can_delete?
    !has_parts? && !has_children?
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :name, :description, :parent_id, :active, :created_at, :updated_at],
      methods: [:full_path, :has_parts, :has_children]
    ))
  end
  
  private
  
  def normalize_fields
    self.name = name&.strip
  end
  
  def parent_cannot_be_self
    return if parent_id.nil? || id.nil?
    
    if parent_id == id
      errors.add(:parent_id, "cannot be the same as the category")
    end
  end
  
  def parent_cannot_be_descendant
    return if parent_id.nil?
    
    # Check if parent is a descendant of this category
    current = parent
    while current.present?
      if current.id == id
        errors.add(:parent_id, "cannot be a descendant of this category")
        break
      end
      current = current.parent
    end
  end
end
