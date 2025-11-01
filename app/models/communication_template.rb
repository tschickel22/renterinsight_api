# frozen_string_literal: true

class CommunicationTemplate < ApplicationRecord
  # Validations
  validates :name, presence: true
  validates :template_type, presence: true
  validates :channel, presence: true, inclusion: { in: %w[email sms] }
  validates :body, presence: true
  validates :subject, presence: true, if: -> { channel == 'email' }

  # Scopes
  scope :active, -> { where(is_active: true) }
  scope :for_type, ->(type) { where(template_type: type) }
  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :platform_wide, -> { where(company_id: nil) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :defaults, -> { where(is_default: true) }

  # Template types
  TEMPLATE_TYPES = %w[
    company_user_invitation
    password_reset
    magic_link
    portal_welcome
    quote_sent
    quote_accepted
    document_shared
  ].freeze

  # Available merge variables
  MERGE_VARIABLES = {
    'company_user_invitation' => %w[
      user_name
      company_name
      login_url
      invitation_expires
      admin_name
      admin_email
    ],
    'password_reset' => %w[
      user_name
      reset_link
      reset_expires
    ],
    'magic_link' => %w[
      user_name
      magic_link
      link_expires
    ]
  }.freeze

  # Process template with variables
  def render_with_variables(variables = {})
    content = body.dup
    rendered_subject = subject&.dup

    variables.each do |key, value|
      placeholder = "{{#{key}}}"
      content.gsub!(placeholder, value.to_s)
      rendered_subject&.gsub!(placeholder, value.to_s)
    end

    {
      subject: rendered_subject,
      body: content
    }
  end
end
