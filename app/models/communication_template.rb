# frozen_string_literal: true

class CommunicationTemplate < ApplicationRecord
  # Constants
  TEMPLATE_TYPES = %w[
    general
    password_reset
    company_user_invitation
    portal_user_invitation
    tenant_invitation
  ].freeze
  
  # Validations
  validates :name, presence: true, length: { maximum: 255 }
  validates :channel, presence: true, inclusion: { in: %w[email sms] }
  validates :body_template, presence: true
  validates :subject_template, presence: true, if: -> { channel == 'email' }
  validates :template_type, inclusion: { in: TEMPLATE_TYPES }, allow_nil: true
  
  # Scopes
  scope :active, -> { where(active: true) }
  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :by_category, ->(category) { where(category: category) }
  scope :by_type, ->(type) { where(template_type: type) }
  scope :platform, -> { where(scope_type: 'Platform').or(where(scope_type: nil)) }
  scope :for_company, ->(company_id) { where(scope_type: 'Company', scope_id: company_id) }
  
  # Associations
  has_many :communications, foreign_key: :template_id, dependent: :nullify
  belongs_to :scope, polymorphic: true, optional: true
  
  # Callbacks
  before_validation :extract_variables
  
  # Extract variables from templates using Liquid syntax
  # Looks for {{ variable_name }} patterns
  def extract_variables
    return if body_template.blank?
    
    vars = []
    
    # Extract from body template
    vars += body_template.scan(/\{\{\s*(\w+(?:\.\w+)*)\s*\}\}/).flatten
    
    # Extract from subject template if email
    if channel == 'email' && subject_template.present?
      vars += subject_template.scan(/\{\{\s*(\w+(?:\.\w+)*)\s*\}\}/).flatten
    end
    
    # Store unique variables
    self.variables = { 'available_variables' => vars.uniq.sort }
  end
  
  # Render the template with provided context
  def render(context = {})
    {
      subject: render_subject(context),
      body: render_body(context)
    }
  end
  
  def render_subject(context = {})
    return nil unless channel == 'email'
    TemplateRenderingService.render(subject_template, context)
  end
  
  def render_body(context = {})
    TemplateRenderingService.render(body_template, context)
  end
  
  # Get list of available variables
  def available_variables
    variables['available_variables'] || []
  end
end
