class IntakeForm < ApplicationRecord
  # A field mapping whose target starts with this prefix points at one of the
  # company's lead custom fields rather than a Lead column. Custom field keys
  # are free to collide with real column names (company 17 has one keyed
  # `email`), so the namespace is what keeps a custom answer from silently
  # overwriting the standard mapping — and it is how IntakeSubmission knows to
  # write into custom_field_values instead of calling an attribute writer that
  # does not exist.
  CUSTOM_FIELD_PREFIX = 'custom:'

  # Shown beside the marketing consent checkbox when a dealer has not written
  # their own. Deliberately plain: it names who is sending, what they will send,
  # and how to stop, which is what a consent record has to be able to prove was
  # on screen. {{company}} is the only substitution.
  DEFAULT_MARKETING_CONSENT_TEXT =
    'Yes, {{company}} may email and text me about homes, offers and events. ' \
    'I can unsubscribe at any time.'

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

    # The consent checkbox, resolved here rather than in a controller so every
    # endpoint that hands out a form carries it: the public page, the dealer
    # site embed, the builder's list, and the builder's preview. It was added to
    # #show alone at first, which meant the builder loaded forms from #index and
    # its preview drew no consent question at all — an admin checking their form
    # saw something their visitors would not.
    json['marketing_consent'] = {
      'enabled' => marketing_consent?,
      'text' => resolved_marketing_consent_text,
      'version' => marketing_consent_version
    }
    json['marketingConsentEnabled'] = json['marketing_consent_enabled']
    json['marketingConsentText'] = json['marketing_consent_text']
    json['marketingConsentVersion'] = json['marketing_consent_version']

    json
  end
  
  # What a visitor's browser needs to draw and submit the form, and nothing
  # else. #as_json is the builder's view and carries internal configuration:
  # who is notified, the lead source, field mappings, the bound location,
  # submission counts. Public endpoints used to hand that to anyone holding the
  # form link. Both key styles are kept because the public pages read both.
  def public_as_json
    captcha = captcha_required?
    {
      'name' => name,
      'description' => description,
      'fields' => fields,
      'public_id' => public_id,
      'publicId' => public_id,
      'submit_button_text' => submit_button_text,
      'submitButtonText' => submit_button_text,
      'thank_you_message' => thank_you_message,
      'thankYouMessage' => thank_you_message,
      'redirect_url' => redirect_url,
      'redirectUrl' => redirect_url,
      'captcha_required' => captcha,
      'captchaRequired' => captcha,
      'captchaSiteKey' => (TurnstileVerifier.site_key if captcha),
      'marketing_consent' => {
        'enabled' => marketing_consent?,
        'text' => resolved_marketing_consent_text,
        'version' => marketing_consent_version
      }
    }.compact
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
  
  # The exact wording to show this form's submitter. Resolved at render AND at
  # submit time, and copied onto the submission, so a later edit cannot rewrite
  # what somebody already agreed to.
  def resolved_marketing_consent_text
    text = marketing_consent_text.presence || DEFAULT_MARKETING_CONSENT_TEXT
    text.gsub('{{company}}', company&.name.to_s.presence || 'this dealership')
  end

  def marketing_consent?
    marketing_consent_enabled
  end

  private
  
  def update_submission_count
    return unless saved_change_to_id? || saved_change_to_is_active?
    update_column(:submission_count, intake_submissions.count)
  end
end
