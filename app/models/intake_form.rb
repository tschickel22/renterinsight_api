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
  # on screen. {{company}} is the only substitution. What they will send
  # depends on the business: a software company does not send home offers.
  DEFAULT_MARKETING_CONSENT_TEXTS = {
    'manufactured_housing' => 'homes, offers and events',
    'installer'            => 'its services and offers',
    'rv'                   => 'RVs, offers and events',
    'saas'                 => 'its products, updates and offers',
    'property_management'  => 'rentals, availability and community news',
    'storage'              => 'storage units, availability and offers'
  }.transform_values { |about| "Yes, {{company}} may email and text me about #{about}. I can unsubscribe at any time." }.freeze
  DEFAULT_MARKETING_CONSENT_TEXT = DEFAULT_MARKETING_CONSENT_TEXTS['manufactured_housing']
  OTHER_MARKETING_CONSENT_TEXT =
    'Yes, {{company}} may email and text me about its products, services and offers. I can unsubscribe at any time.'

  def self.default_marketing_consent_text(industry)
    DEFAULT_MARKETING_CONSENT_TEXTS.fetch(industry.to_s, OTHER_MARKETING_CONSENT_TEXT)
  end

  belongs_to :company
  belongs_to :source, class_name: 'Source', foreign_key: 'source_id', optional: true
  belongs_to :notified_user, class_name: 'User', foreign_key: 'notified_user_id', optional: true
  # Optional binding to a specific location. When set, leads created from
  # this form land at that location instead of the company's Corporate
  # fallback (see IntakeSubmission#create_lead_from_submission).
  belongs_to :location, optional: true
  # Who a new lead belongs to: the notified user (one person), or the next rep
  # in this rotation. The list is the same kind plays, API keys and workflows
  # use, and a play running on this form shares it, so the form and the play
  # keep one place in line rather than two.
  belongs_to :round_robin_list, class_name: 'RoundRobinAssignmentList', optional: true
  has_many :intake_submissions, dependent: :destroy

  ASSIGNMENT_MODES = %w[notified_user round_robin].freeze

  before_create :generate_public_id
  before_save :save_rotation
  before_save :bump_marketing_consent_version
  after_save :update_submission_count

  validates :name, presence: true
  validates :public_id, uniqueness: true, allow_nil: true
  validates :assignment_mode, inclusion: { in: ASSIGNMENT_MODES }, allow_nil: true
  validate :rotation_has_reps
  validate :assignees_belong_to_company
  validate :redirect_url_is_web_address
  normalizes :redirect_url, with: ->(url) { url.strip.presence }
  
  scope :active, -> { where(is_active: true) }
  scope :inactive, -> { where(is_active: false) }
  
  # schema column is already JSON type, no need to serialize
  # Just use accessor methods to alias it as 'fields'
  
  def fields
    schema || []
  end

  # The reps to rotate between, in order. Set from the form builder; saved onto
  # the form's rotation list (created the first time) when the form is saved.
  def rotation_user_ids
    return @rotation_user_ids unless @rotation_user_ids.nil?

    Array(round_robin_list&.user_ids).map(&:to_i)
  end

  def rotation_user_ids=(ids)
    @rotation_user_ids = Array(ids).map(&:to_i).select(&:positive?).uniq
  end

  def rotates?
    assignment_mode == 'round_robin' && round_robin_list&.active == true
  end

  # The rep a new lead from this form belongs to. Advances the rotation, so
  # call it once per lead actually created. Falls back to the notified user
  # when everyone in the rotation is inactive.
  def next_owner_id
    (rotates? ? round_robin_list.next_active_user!&.id : nil) || notified_user_id
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
    json['assignment_mode'] = assignment_mode || 'notified_user'
    json['assignmentMode'] = json['assignment_mode']
    json['roundRobinListId'] = round_robin_list_id
    json['rotation_user_ids'] = rotation_user_ids
    json['rotationUserIds'] = json['rotation_user_ids']
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
      'version' => marketing_consent_version,
      # What a blank wording box means for this company, for the editor's placeholder.
      'default_text' => default_marketing_consent_text
    }
    json['hideName'] = json['hide_name']
    json['hideDescription'] = json['hide_description']
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
      'hide_name' => hide_name,
      'hideName' => hide_name,
      'hide_description' => hide_description,
      'hideDescription' => hide_description,
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
    text = marketing_consent_text.presence || default_marketing_consent_text
    text.gsub('{{company}}', company&.name.to_s.presence || 'this dealership')
  end

  def default_marketing_consent_text
    self.class.default_marketing_consent_text(company&.industry)
  end

  def marketing_consent?
    marketing_consent_enabled
  end

  private

  # A new wording is a new version, so a consent record can say which one a
  # person saw. Blank and the default count as the same wording.
  def bump_marketing_consent_version
    return if new_record? || !will_save_change_to_marketing_consent_text?
    was, now = attribute_change_to_be_saved(:marketing_consent_text).map { |t| t.presence || default_marketing_consent_text }
    return if was.strip == now.strip
    n = marketing_consent_version.to_s[/\d+/].to_i
    self.marketing_consent_version = "v#{n + 1}"
  end

  # Only this company's active users join the rotation; anything else in the
  # request is dropped. The list is updated in place, so a play sharing it
  # sees the change and the rotation keeps its place in line.
  def save_rotation
    return if @rotation_user_ids.nil? || assignment_mode != 'round_robin'

    active = User.where(company_id: company_id, status: 'active', id: @rotation_user_ids).pluck(:id)
    ids = @rotation_user_ids & active
    list = round_robin_list if round_robin_list&.company_id == company_id
    if list
      list.update!(user_ids: ids, active: true)
    else
      taken = RoundRobinAssignmentList.where(company_id: company_id).pluck(:name)
      base = "#{name} rotation"
      list_name = base
      n = 1
      list_name = "#{base} (#{n += 1})" while taken.include?(list_name)
      self.round_robin_list = RoundRobinAssignmentList.create!(company_id: company_id, name: list_name, user_ids: ids, active: true)
    end
    @rotation_user_ids = nil
  end

  def rotation_has_reps
    return unless assignment_mode == 'round_robin'

    if @rotation_user_ids.nil?
      errors.add(:base, 'Choose at least one rep to rotate new leads between.') if round_robin_list.nil?
    elsif User.where(company_id: company_id, status: 'active', id: @rotation_user_ids).none?
      errors.add(:base, 'Choose at least one active rep to rotate new leads between.')
    end
  end

  # A form from one company must never hand its leads, or news of them, to
  # someone in another. Checked only on change so a form saved before this
  # rule still saves.
  def assignees_belong_to_company
    if will_save_change_to_notified_user_id? && notified_user_id.present? &&
       !User.where(id: notified_user_id, company_id: company_id).exists?
      errors.add(:notified_user_id, 'must be someone at this dealership')
    end
    if will_save_change_to_round_robin_list_id? && round_robin_list_id.present? &&
       !RoundRobinAssignmentList.where(id: round_robin_list_id, company_id: company_id).exists?
      errors.add(:round_robin_list_id, 'must be one of this dealership\'s rotations')
    end
  end

  # After a submit the visitor's browser is sent to this address, so it must
  # be a web page: a javascript: address would run on the dealer's site.
  def redirect_url_is_web_address
    return if redirect_url.blank? || !will_save_change_to_redirect_url?

    uri = URI.parse(redirect_url)
    return if uri.is_a?(URI::HTTP) && uri.host.present?

    errors.add(:redirect_url, 'must be a web address starting with https://')
  rescue URI::InvalidURIError
    errors.add(:redirect_url, 'must be a web address starting with https://')
  end

  def update_submission_count
    return unless saved_change_to_id? || saved_change_to_is_active?
    update_column(:submission_count, intake_submissions.count)
  end
end
