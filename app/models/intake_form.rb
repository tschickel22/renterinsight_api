class IntakeForm < ApplicationRecord
  belongs_to :company
  belongs_to :source, class_name: 'Source', foreign_key: 'source_id', optional: true
  has_many :intake_submissions, dependent: :destroy
  
  before_create :generate_public_id
  after_save :update_submission_count
  
  validates :name, presence: true
  validates :public_id, uniqueness: true, allow_nil: true
  
  scope :active, -> { where(is_active: true) }
  scope :inactive, -> { where(is_active: false) }
  
  # schema column is already JSON type, no need to serialize
  # Just use accessor methods to alias it as 'fields'
  
  def fields
    schema || []
  end
  
  def fields=(value)
    self.schema = value
  end
  
  def as_json(options = {})
    json = super(options)
    
    # Include both naming conventions for compatibility
    json['fields'] = self.fields  # Use the fields accessor
    json['isActive'] = json['is_active']
    json['sourceId'] = json['source_id']
    json['publicId'] = json['public_id']
    json['publicUrl'] = public_url
    json['embedCode'] = embed_code
    
    json
  end
  
  def generate_public_id
    self.public_id ||= loop do
      token = SecureRandom.urlsafe_base64(8)
      break token unless IntakeForm.exists?(public_id: token)
    end
  end
  
  def public_url(base_url = ENV['APP_URL'] || 'http://localhost:3000')
    "#{base_url}/f/#{public_id}"
  end
  
  def embed_code
    url = public_url
    <<~HTML
      <iframe src="#{url}" width="100%" height="600" frameborder="0" style="border: none; border-radius: 8px;"></iframe>
    HTML
  end
  
  def increment_submission_count!
    increment!(:submission_count)
  end
  
  private
  
  def update_submission_count
    return unless saved_change_to_id? || saved_change_to_is_active?
    update_column(:submission_count, intake_submissions.count)
  end
end
