# frozen_string_literal: true

class Contact < ApplicationRecord
  # Associations
  belongs_to :account, optional: true
  belongs_to :company, optional: true
  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
  has_many :note_records, class_name: 'Note', as: :entity, dependent: :destroy

  # Validations
  validates :first_name, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :phone, format: { with: /\A[\d\s\-\(\)\+\.]+\z/, allow_blank: true }

  # Scopes
  scope :primary, -> { where(is_primary: true) }
  scope :with_email, -> { where.not(email: nil).where.not(email: '') }
  scope :with_phone, -> { where.not(phone: nil).where.not(phone: '') }
  scope :by_department, ->(dept) { where(department: dept) }
  scope :by_title, ->(title) { where(title: title) }
  scope :recent, -> { order(created_at: :desc) }
  scope :updated_recently, -> { order(updated_at: :desc) }

  # Callbacks
  before_validation :normalize_email
  before_validation :normalize_phone

  # Instance methods
  def full_name
    [first_name, last_name].compact.join(' ')
  end

  def display_name
    full_name.presence || email || phone || 'Unnamed Contact'
  end

  def has_contact_info?
    email.present? || phone.present?
  end

  def contact_methods
    methods = []
    methods << 'email' if email.present?
    methods << 'phone' if phone.present?
    methods
  end

  # Search functionality
  def self.search(query)
    return all if query.blank?

    query = query.downcase
    where(
      'LOWER(first_name) LIKE ? OR LOWER(last_name) LIKE ? OR LOWER(email) LIKE ? OR LOWER(phone) LIKE ? OR LOWER(title) LIKE ? OR LOWER(department) LIKE ?',
      "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%"
    )
  end

  # Statistics
  def self.statistics
    {
      total: count,
      with_email: with_email.count,
      with_phone: with_phone.count,
      primary: primary.count,
      by_department: group(:department).count,
      by_title: group(:title).count,
      recent_count: where('created_at >= ?', 30.days.ago).count
    }
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase if email.present?
  end

  def normalize_phone
    self.phone = phone.to_s.strip if phone.present?
  end
end
