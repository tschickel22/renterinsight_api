# frozen_string_literal: true

class CommunicationTemplate < ApplicationRecord
  # Template types - combined from both versions
  TEMPLATE_TYPES = %w[
    general
    company_user_invitation
    portal_user_invitation
    password_reset
    magic_link
    tenant_invitation
    portal_welcome
    quote_sent
    quote_accepted
    document_shared
  ].freeze
  
  # Available merge variables for each template type
  MERGE_VARIABLES = {
    'company_user_invitation' => %w[
      recipient_name first_name last_name email phone role role_name
      company_name invited_by invitation_url registration_url invitation_token
      invitation_expires days_until_expiry setup_instructions login_url
    ],
    'portal_user_invitation' => %w[
      recipient_name first_name last_name email phone
      company_name portal_url registration_url invitation_token
      invitation_expires days_until_expiry
    ],
    'password_reset' => %w[
      recipient_name user_name reset_url reset_link company_name
      reset_expires
    ],
    'magic_link' => %w[
      user_name magic_link link_expires company_name
    ]
  }.freeze
  
  # Validations
  validates :name, presence: true
  validates :template_type, presence: true, inclusion: { in: TEMPLATE_TYPES }, allow_nil: true
  validates :channel, presence: true, inclusion: { in: %w[email sms] }
  validates :body, presence: true
  validates :subject, presence: true, if: -> { channel == 'email' }
  
  # Scopes
  scope :active, -> { where(is_active: true) }
  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :for_type, ->(type) { where(template_type: type) }
  scope :by_type, ->(type) { where(template_type: type) }
  scope :platform_wide, -> { where(company_id: nil) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :defaults, -> { where(is_default: true) }
  
  # Associations
  has_many :communications, foreign_key: :template_id, dependent: :nullify
  
  # Callbacks
  before_validation :extract_variables
  
  # Extract variables from templates using Liquid/Mustache syntax
  # Looks for {{ variable_name }} patterns
  def extract_variables
    return if body.blank?
    
    vars = []
    
    # Extract from body
    body_vars = body.scan(/\{\{\s*(\w+(?:\.\w+)*)\s*\}\}/)
    vars.concat(body_vars.flatten) if body_vars.any?
    
    # Extract from subject if email
    if channel == 'email' && subject.present?
      subject_vars = subject.scan(/\{\{\s*(\w+(?:\.\w+)*)\s*\}\}/)
      vars.concat(subject_vars.flatten) if subject_vars.any?
    end
    
    # Build new hash with variables
    self.variables = { 'available_variables' => vars.uniq }
  rescue StandardError => e
    # If there's any error, just set an empty array
    self.variables = { 'available_variables' => [] }
    Rails.logger.error("Error extracting variables: #{e.message}")
  end
  
  # Render template with variables (Liquid-style)
  def render(context = {})
    rendered_body = body.dup
    rendered_subject = subject&.dup
    
    # Replace {{variable}} or {{ variable }} with context values
    context.each do |key, value|
      # Handle both {{key}} and {{ key }} formats
      placeholder_no_space = "{{#{key}}}"
      placeholder_with_space = "{{ #{key} }}"
      
      rendered_body.gsub!(placeholder_no_space, value.to_s) if rendered_body
      rendered_body.gsub!(placeholder_with_space, value.to_s) if rendered_body
      
      if rendered_subject
        rendered_subject.gsub!(placeholder_no_space, value.to_s)
        rendered_subject.gsub!(placeholder_with_space, value.to_s)
      end
    end
    
    {
      subject: rendered_subject,
      body: rendered_body
    }
  end
  
  # Alias for backwards compatibility
  alias_method :render_with_variables, :render
  
  # Get list of available variables for this template
  def available_variables
    variables&.dig('available_variables') || []
  end
  
  # Get expected variables for template type
  def expected_variables
    MERGE_VARIABLES[template_type] || []
  end
end
