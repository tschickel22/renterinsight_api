# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Api
  module Crm
    module Nurture
      class AiTemplatesController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        before_action :set_company_scope
        before_action :check_ai_limit!

        # POST /api/crm/nurture/ai_templates/generate
        def generate
          channel = params[:channel] || 'email'
          category = params[:category] || 'general'
          custom_instructions = params[:custom_instructions] || ''
          variant_count = [params[:variant_count]&.to_i || 2, 3].min

          company_profile = Setting.get('Company', @company.id, 'company_profile') || {}
          sender_context = build_sender_context(current_user)
          business_name = business_display_name(current_location, @company)

          system_prompt = build_system_prompt(company_profile, sender_context, business_name, channel, category)
          user_prompt = build_user_prompt(channel, category, custom_instructions, variant_count)

          api_key = Rails.application.credentials.dig(:anthropic, :api_key) ||
                    ENV['ANTHROPIC_API_KEY']

          unless api_key.present?
            return render json: { error: 'AI service not configured' }, status: :service_unavailable
          end

          begin
            response = call_anthropic(api_key, system_prompt, user_prompt)

            content = response.dig('content', 0, 'text') || ''
            variants = parse_template_variants(content, channel, category)

            AiQueryLog.create!(
              company: @company,
              user: current_user,
              feature: 'ai_template_generate',
              module_key: 'nurture',
              question: "Generate #{channel} template for #{category}",
              execution_status: 'success',
              input_tokens: response.dig('usage', 'input_tokens') || 0,
              output_tokens: response.dig('usage', 'output_tokens') || 0,
              cost_cents: compute_cost_cents(
                response.dig('usage', 'input_tokens') || 0,
                response.dig('usage', 'output_tokens') || 0
              ),
              generated_params: { channel: channel, category: category, variant_count: variants.size }
            )

            render json: {
              variants: variants,
              usage: {
                input_tokens: response.dig('usage', 'input_tokens'),
                output_tokens: response.dig('usage', 'output_tokens')
              }
            }
          rescue Net::ReadTimeout, Net::OpenTimeout => e
            AiQueryLog.create!(
              company: @company,
              user: current_user,
              feature: 'ai_template_generate',
              module_key: 'nurture',
              question: "Generate #{channel} template for #{category}",
              execution_status: 'error',
              input_tokens: 0, output_tokens: 0, cost_cents: 0,
              generated_params: { error: "Timeout: #{e.message}" }
            )
            Rails.logger.error "[AI Template] Timeout: #{e.message}"
            render json: {
              error: 'ai_timeout',
              message: 'The AI took too long to respond. Try shorter instructions and retry.'
            }, status: :gateway_timeout
          rescue => e
            AiQueryLog.create!(
              company: @company,
              user: current_user,
              feature: 'ai_template_generate',
              module_key: 'nurture',
              question: "Generate #{channel} template for #{category}",
              execution_status: 'error',
              input_tokens: 0,
              output_tokens: 0,
              cost_cents: 0,
              generated_params: { error: e.message }
            )

            Rails.logger.error "[AI Template] Error: #{e.message}"
            render json: {
              error: 'ai_generation_failed',
              message: "AI generation failed: #{e.message.to_s.first(200)}"
            }, status: :unprocessable_entity
          end
        end

        # POST /api/crm/nurture/ai_templates/save
        def save
          template = @company.templates.new(
            name: params[:name],
            template_type: params[:channel] || 'email',
            subject: params[:subject],
            body: params[:body],
            category: params[:category] || 'general',
            source: 'ai_generated',
            is_active: true
          )

          if template.save
            render json: template_json(template), status: :created
          else
            render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def set_company_scope
          unless current_user
            Rails.logger.error "🚫 [Nurture::AiTemplatesController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end

          company_id = current_company_id

          unless company_id.present?
            Rails.logger.error "🚫 [Nurture::AiTemplatesController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end

          @company = ::Company.find_by(id: company_id)

          if @company.nil?
            Rails.logger.error "🚫 [Nurture::AiTemplatesController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end

          Rails.logger.info "✅ [Nurture::AiTemplatesController] Company scope set: #{@company.name} (ID: #{@company.id})"
        end

        def check_ai_limit!
          return if current_user.respond_to?(:platform_admin?) && current_user.platform_admin?
          return if current_user.try(:user_type) == 'platform_admin'

          if defined?(SubscriptionLimitService)
            service = SubscriptionLimitService.new(@company)
            limit = service.effective_limit('max_ai_credits')
            used = AiQueryLog.where(company_id: @company.id).this_month.count

            if used >= limit
              render json: {
                error: "Monthly AI credit limit reached (#{limit}). Contact support to upgrade.",
                usage: { used: used, limit: limit, remaining: 0 }
              }, status: :too_many_requests
              return
            end
          end
        end

        def business_display_name(location, company)
          loc_name = location&.name.to_s.strip
          return loc_name if loc_name.present? && loc_name.downcase != 'main'
          company.name
        end

        def build_sender_context(user)
          return {} unless user
          {
            signature: user.try(:typed_signature).to_s.strip,
            booking_url: user.try(:booking_url).to_s.strip,
            full_name: [user.try(:first_name), user.try(:last_name)].compact.join(' ').strip,
            title: user.try(:title).to_s.strip,
            phone: user.try(:phone).to_s.strip
          }
        end

        def sender_context_block(sender, business_name)
          return '' if sender.blank? && business_name.blank?
          lines = []
          if sender[:signature].present?
            lines << "Sender's email signature (use this verbatim at the end of email bodies; for SMS, just sign with first name):"
            lines << sender[:signature]
          elsif sender[:full_name].present?
            lines << '  - REQUIRED: build a sign-off at the bottom of email bodies on its own lines, in this order (omit fields that are blank, but always end with the business name):'
            lines << "      Name: #{sender[:full_name]}"
            lines << "      Title: #{sender[:title]}" if sender[:title].present?
            lines << "      Phone: #{sender[:phone]}" if sender[:phone].present?
            lines << "      Business: #{business_name}" if business_name.present?
            lines << '  - The business name MUST appear in the sign-off — this is how the recipient knows what dealership / company is reaching out. Do not omit it.'
            lines << '  - For SMS, sign with first name only (no title/phone/business).'
          end
          if sender[:booking_url].present?
            lines << ''
            lines << "Sender's booking link: #{sender[:booking_url]}"
            lines << '  - For EMAIL bodies: render the booking link as an HTML anchor with short link text — `<a href="URL">Book here</a>` or `<a href="URL">View my calendar</a>`. Do NOT expose the raw URL.'
            lines << '  - When emitting an `<a>` tag, the ENTIRE email body MUST be valid HTML — wrap each paragraph in `<p>...</p>` and the sign-off in `<p>` with `<br>` between sign-off lines. Without `<p>` wrappers the mail renderer falls back to plain text and the `<a>` tag shows raw.'
            lines << '  - For SMS bodies: include the raw URL after framing text like "Book a time:" — SMS can\'t hyperlink.'
            lines << "  - Don't shoehorn it into every step — only where booking is the right next action."
          end
          return '' if lines.empty?
          "SENDER CONTEXT:\n#{lines.join("\n")}\n"
        end

        def build_system_prompt(profile, sender, business_name, channel, category)
          industry = profile['industry_vertical'] || 'general business'
          voice = profile['brand_voice'] || 'professional'

          <<~PROMPT
            You are a marketing copywriter generating #{channel} templates for a business.

            BUSINESS CONTEXT:
            Business name (use this when referring to the sender's business in copy): #{business_name}
            #{profile['business_description'].present? ? "About: #{profile['business_description']}" : ''}
            #{profile['target_audience'].present? ? "Target audience: #{profile['target_audience']}" : ''}
            #{profile['products_services'].present? ? "Products/services: #{profile['products_services']}" : ''}
            #{profile['unique_value_props'].present? ? "Value proposition: #{profile['unique_value_props']}" : ''}
            Industry: #{industry}
            Brand voice: #{voice}

            #{sender_context_block(sender, business_name)}
            RULES:
            - Use merge tags: {{first_name}}, {{last_name}} for personalization of the recipient
            - {{company_name}} refers to the RECIPIENT's company, not the sender. When mentioning the sender's own business, use the business name above directly.
            - Keep #{channel == 'sms' ? 'messages under 160 characters when possible, max 320' : 'emails concise and scannable'}
            - Match the brand voice: #{voice}
            - Include a clear call-to-action
            - #{channel == 'email' ? 'Write a compelling subject line' : 'Front-load the important info'}
            - Do NOT use generic filler like "I hope this email finds you well"
            - Write like a real person, not a template
            - Never use placeholder like "[Your name]" — use the sender signature/name provided above

            RESPOND IN THIS EXACT JSON FORMAT (no markdown, no backticks):
            [
              {
                "name": "Template display name",
                "subject": "Email subject line (email only, omit for SMS)",
                "body": "The template body text with {{merge_tags}}",
                "category": "#{category}"
              }
            ]
          PROMPT
        end

        def build_user_prompt(channel, category, custom_instructions, variant_count)
          category_descriptions = {
            'cold_outreach' => 'First contact with someone who has never interacted with the business',
            'warm_followup' => 'Following up with someone who showed interest (visited, inquired, etc.)',
            'nurture' => 'Part of an ongoing drip sequence to build relationship over time',
            're_engagement' => 'Reaching out to someone who went quiet/cold after previous interaction',
            'appointment' => 'Scheduling, confirming, or following up on an appointment or tour',
            'post_sale' => 'After a purchase — thank you, onboarding, review request',
            'onboarding' => 'Welcoming and getting a new customer set up',
            'service' => 'Service-related communication (maintenance, support, follow-up)',
            'referral_request' => 'Asking happy customers for referrals',
            'announcement' => 'Company news, new arrivals, policy changes',
            'event_promo' => 'Promoting an open house, sale event, or community event',
            'seasonal' => 'Holiday or seasonal themed communication',
            'general' => 'General purpose communication'
          }

          <<~PROMPT
            Generate #{variant_count} #{channel} template variants for the purpose: #{category}

            Purpose description: #{category_descriptions[category] || category}

            #{custom_instructions.present? ? "Additional instructions: #{custom_instructions}" : ''}

            Each variant should take a different angle or tone while staying on-purpose.
            Return a JSON array with #{variant_count} objects.
          PROMPT
        end

        def call_anthropic(api_key, system_prompt, user_prompt)
          uri = URI('https://api.anthropic.com/v1/messages')
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 10
          http.read_timeout = 60

          request = Net::HTTP::Post.new(uri)
          request['Content-Type'] = 'application/json'
          request['x-api-key'] = api_key
          request['anthropic-version'] = '2023-06-01'
          request.body = {
            model: AiModel.for(:generation),
            max_tokens: 2000,
            system: system_prompt,
            messages: [{ role: 'user', content: user_prompt }]
          }.to_json

          response = http.request(request)

          unless response.code == '200'
            raise "Anthropic API error: #{response.code} - #{response.body}"
          end

          JSON.parse(response.body)
        end

        def parse_template_variants(content, channel, category)
          json_match = content.match(/\[[\s\S]*\]/)
          return [] unless json_match

          variants = JSON.parse(json_match[0])
          variants.map do |v|
            {
              name: v['name'] || 'AI Generated Template',
              subject: channel == 'email' ? (v['subject'] || '') : nil,
              body: v['body'] || '',
              channel: channel,
              category: v['category'] || category,
              source: 'ai_generated'
            }
          end
        rescue JSON::ParserError => e
          Rails.logger.error "[AI Template] JSON parse error: #{e.message}"
          []
        end

        def compute_cost_cents(input_tokens, output_tokens)
          input_cost = (input_tokens.to_f / 1_000_000) * 3.0
          output_cost = (output_tokens.to_f / 1_000_000) * 15.0
          ((input_cost + output_cost) * 100).round(2)
        end

        def template_json(template)
          {
            id: template.id,
            name: template.name,
            template_type: template.template_type,
            type: template.template_type,
            subject: template.subject,
            body: template.body,
            category: template.category,
            source: template.source,
            isActive: template.is_active,
            is_active: template.is_active,
            createdAt: template.created_at&.iso8601,
            updatedAt: template.updated_at&.iso8601
          }
        end
      end
    end
  end
end
