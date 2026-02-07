class WebsiteVersion < ApplicationRecord
  # Associations
  belongs_to :website
  belongs_to :created_by, class_name: 'User'
  
  # Validations
  validates :snapshot_data, presence: true
  
  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :current, -> { where(is_current: true) }
  
  # Mark as current version
  def make_current!
    transaction do
      website.website_versions.update_all(is_current: false)
      update!(is_current: true)
    end
  end
  
  # Restore website to this version
  def restore!
    return unless snapshot_data.present?
    
    website.update!(
      name: snapshot_data['name'],
      domain: snapshot_data['domain'],
      theme_id: snapshot_data['theme_id'],
      primary_color: snapshot_data['primary_color'],
      secondary_color: snapshot_data['secondary_color'],
      font_family: snapshot_data['font_family'],
      custom_css: snapshot_data['custom_css'],
      custom_js: snapshot_data['custom_js']
    )
    
    make_current!
  end
end
