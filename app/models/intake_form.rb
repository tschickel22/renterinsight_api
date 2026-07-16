class IntakeForm < ApplicationRecord
  belongs_to :company
  belongs_to :source, class_name: 'Source', foreign_key: 'source_id', optional: true
  belongs_to :notified_user, class_name: 'User', foreign_key: 'notified_user_id', optional: true
  # Optional binding to a specific location. When set, leads created from
  # this form land at that location instead of the company's Corporate
  # fallback (see IntakeSubmission#create_lead_from_submission).
  belongs_to :location, optional: true
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
    # Convert ActionController::Parameters to plain hashes for JSON storage
    if value.is_a?(Array)
      self.schema = value.map do |field|
        field.is_a?(ActionController::Parameters) ? field.to_h : field
      end
    else
      self.schema = value
    end
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
    json['notifiedUserId'] = json['notified_user_id']
    json['locationId'] = json['location_id']
    json['autoCreateLead'] = json['auto_create_lead']
    json['autoCreateActivity'] = json['auto_create_activity']
    json['fieldMappings'] = json['field_mappings']
    json['captchaRequired'] = json['captcha_required']
    # Site key travels with the form so the public page can render the widget
    # without any FE ENV wiring. Site keys are public by design (Cloudflare
    # binds them to allowlisted domains at their edge).
    json['captchaSiteKey'] = TurnstileVerifier.site_key if json['captcha_required']

    json
  end
  
  def generate_public_id
    self.public_id ||= loop do
      token = SecureRandom.urlsafe_base64(8)
      break token unless IntakeForm.exists?(public_id: token)
    end
  end
  
  def public_url(base_url = ENV['APP_URL'] || ENV['FRONTEND_URL'] || 'http://localhost:3000')
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
