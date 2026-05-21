# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Api
  module Crm
    module Nurture
      class AiSequencesController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        before_action :set_company_scope
        before_action :check_ai_limit!

        # POST /api/crm/nurture/ai_sequences/generate
        def generate
          goal = params[:goal]
          entity_type = params[:entity_type] || 'Lead'
          audience_stage = params[:audience_stage] || 'cold'
          channels = params[:channels] || ['email']
          max_steps = [params[:max_steps]&.to_i || 6, 12].min
          custom_instructions = params[:custom_instructions] || ''

          company_profile = Setting.get('Company', @company.id, 'company_profile') || {}
          sender_context = build_sender_context(current_user)
          business_name = business_display_name(current_location, @company)

          system_prompt = build_sequence_system_prompt(company_profile, sender_context, business_name)
          user_prompt = build_sequence_user_prompt(goal, entity_type, audience_stage, channels, max_steps, custom_instructions)

          api_key = Rails.application.credentials.dig(:anthropic, :api_key) || ENV['ANTHROPIC_API_KEY']
          unless api_key.present?
            return render json: { error: 'AI service not configured' }, status: :service_unavailable
          end

          begin
            response = call_anthropic(api_key, system_prompt, user_prompt)
            content = response.dig('content', 0, 'text') || ''
            sequence_plan = parse_sequence_plan(content)

            AiQueryLog.create!(
              company: @company,
              user: current_user,
              feature: 'ai_sequence_generate',
              module_key: 'nurture',
              question: "Generate sequence: #{goal}",
              execution_status: 'success',
              input_tokens: response.dig('usage', 'input_tokens') || 0,
              output_tokens: response.dig('usage', 'output_tokens') || 0,
              cost_cents: compute_cost_cents(
                response.dig('usage', 'input_tokens') || 0,
                response.dig('usage', 'output_tokens') || 0
              ),
              generated_params: { goal: goal, entity_type: entity_type, audience_stage: audience_stage, steps_count: sequence_plan['steps']&.size }
            )

            render json: {
              sequence: sequence_plan,
              usage: {
                input_tokens: response.dig('usage', 'input_tokens'),
                output_tokens: response.dig('usage', 'output_tokens')
              }
            }
          rescue => e
            AiQueryLog.create!(
              company: @company,
              user: current_user,
              feature: 'ai_sequence_generate',
              module_key: 'nurture',
              question: "Generate sequence: #{goal}",
              execution_status: 'error',
              input_tokens: 0, output_tokens: 0, cost_cents: 0,
              generated_params: { error: e.message }
            )
            Rails.logger.error "[AI Sequence] Error: #{e.message}"
            render json: { error: 'AI generation failed. Please try again.' }, status: :unprocessable_entity
          end
        end

        # POST /api/crm/nurture/ai_sequences/save
        # Creates the NurtureSequence + NurtureSteps + Templates in one transaction
        def save
          sequence_data = params[:sequence] || {}
          steps_data = params[:steps] || []

          ActiveRecord::Base.transaction do
            sequence = @company.nurture_sequences.create!(
              name: sequence_data[:name] || 'AI Generated Sequence',
              description: sequence_data[:description]
            )

            steps_data.each_with_index do |step, index|
              template = nil
              if step[:body].present?
                template = @company.templates.create!(
                  name: "#{sequence.name} - Step #{index + 1}",
                  template_type: step[:channel] || 'email',
                  subject: step[:subject],
                  body: step[:body],
                  category: 'nurture',
                  source: 'ai_generated',
                  is_active: true
                )
              end

              sequence.nurture_steps.create!(
                position: index,
                step_type: step[:step_type] || step[:channel] || 'email',
                channel: step[:channel] || 'email',
                wait_days: step[:wait_days] || 0,
                subject: step[:subject],
                body: step[:body],
                template_id: template&.id
              )
            end

            render json: {
              sequence: {
                id: sequence.id,
                name: sequence.name,
                steps_count: sequence.nurture_steps.count
              },
              message: 'Sequence created successfully'
            }, status: :created
          end
        rescue => e
          Rails.logger.error "[AI Sequence Save] Error: #{e.message}"
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_company_scope
          unless current_user
            Rails.logger.error "🚫 [Nurture::AiSequencesController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end

          company_id = current_company_id

          unless company_id.present?
            Rails.logger.error "🚫 [Nurture::AiSequencesController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end

          @company = ::Company.find_by(id: company_id)

          if @company.nil?
            Rails.logger.error "🚫 [Nurture::AiSequencesController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end

          Rails.logger.info "✅ [Nurture::AiSequencesController] Company scope set: #{@company.name} (ID: #{@company.id})"
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
                error: "Monthly AI credit limit reached (#{limit}).",
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
            lines << "Sender's email signature (use this verbatim at the end of email bodies; for SMS, just sign with first name; for call scripts, use sender's first name):"
            lines << sender[:signature]
          elsif sender[:full_name].present?
            lines << '  - REQUIRED: build a sign-off at the bottom of email bodies on its own lines, in this order (omit fields that are blank, but always end with the business name):'
            lines << "      Name: #{sender[:full_name]}"
            lines << "      Title: #{sender[:title]}" if sender[:title].present?
            lines << "      Phone: #{sender[:phone]}" if sender[:phone].present?
            lines << "      Business: #{business_name}" if business_name.present?
            lines << '  - The business name MUST appear in the sign-off — this is how the recipient knows what dealership / company is reaching out. Do not omit it.'
            lines << '  - For SMS, sign with first name only. For call scripts, just use the first name.'
          end
          if sender[:booking_url].present?
            lines << ''
            lines << "Sender's booking link: #{sender[:booking_url]}"
            lines << '  - For EMAIL bodies on steps where the CTA is booking: render the booking link as an HTML anchor with short link text — `<a href="URL">Book here</a>` or `<a href="URL">View my calendar</a>`. Do NOT expose the raw URL.'
            lines << '  - When emitting an `<a>` tag, the ENTIRE email body for that step MUST be valid HTML — wrap each paragraph in `<p>...</p>` and the sign-off in `<p>` with `<br>` between sign-off lines. Without `<p>` wrappers the mail renderer falls back to plain text and the `<a>` tag shows raw.'
            lines << '  - For SMS / call scripts: include the raw URL with framing text like "Book a time:" — SMS can\'t hyperlink.'
            lines << "  - Don't include the booking link in every step — only where it's the right next action."
          end
          return '' if lines.empty?
          "SENDER CONTEXT:\n#{lines.join("\n")}\n"
        end

        def build_sequence_system_prompt(profile, sender = {}, business_name = nil)
          <<~PROMPT
            You are an expert marketing automation strategist building nurture sequences.

            BUSINESS CONTEXT:
            Business name (use this when referring to the sender's business in copy): #{business_name}
            #{profile['business_description'].present? ? "About: #{profile['business_description']}" : ''}
            #{profile['target_audience'].present? ? "Target audience: #{profile['target_audience']}" : ''}
            #{profile['products_services'].present? ? "Products/services: #{profile['products_services']}" : ''}
            #{profile['unique_value_props'].present? ? "Value proposition: #{profile['unique_value_props']}" : ''}
            Industry: #{profile['industry_vertical'] || 'general'}
            Brand voice: #{profile['brand_voice'] || 'professional'}

            #{sender_context_block(sender, business_name)}
            RULES:
            - Each step needs: channel (email/sms/call), wait_days, subject (for email), body
            - Use merge tags: {{first_name}}, {{last_name}} for the recipient
            - {{company_name}} refers to the RECIPIENT's company. When mentioning the sender's own business, use the business name above directly
            - SMS should be under 320 characters
            - Call steps should have a brief talking-points body (what to say)
            - Escalate urgency gradually — early steps are soft, later steps are more direct
            - Final step should be a polite break-up or last-chance message
            - Space steps intelligently: don't send daily, don't wait too long
            - Typical spacing: Day 0, Day 2, Day 5, Day 10, Day 17, Day 30
            - Mix channels when multiple are requested (don't do all email)
            - Never use placeholder like "[Your name]" — use the sender signature/name provided above

            RESPOND IN THIS EXACT JSON FORMAT (no markdown, no backticks):
            {
              "name": "Sequence name",
              "description": "Brief description of the sequence goal",
              "steps": [
                {
                  "channel": "email",
                  "step_type": "email",
                  "wait_days": 0,
                  "subject": "Subject line (email only)",
                  "body": "Template body with {{merge_tags}}",
                  "rationale": "Why this step exists and its timing"
                }
              ]
            }
          PROMPT
        end

        def build_sequence_user_prompt(goal, entity_type, audience_stage, channels, max_steps, custom_instructions)
          stage_descriptions = {
            'cold' => 'Never interacted or very first contact. They may not know the business.',
            'warm' => 'Showed interest — visited website, downloaded content, inquired, attended event.',
            'hot' => 'Actively shopping, requested pricing, toured/visited. Ready to buy soon.',
            'customer' => 'Already purchased. Goal is relationship building, upsell, review/referral.',
            'churned' => 'Was interested or was a customer but went silent. Need to re-engage.'
          }

          <<~PROMPT
            Build a nurture sequence with these specifications:

            GOAL: #{goal}
            ENTITY TYPE: #{entity_type}
            AUDIENCE STAGE: #{audience_stage} — #{stage_descriptions[audience_stage] || audience_stage}
            CHANNELS TO USE: #{Array(channels).join(', ')}
            MAX STEPS: #{max_steps}

            #{custom_instructions.present? ? "ADDITIONAL INSTRUCTIONS: #{custom_instructions}" : ''}

            Generate the full sequence as a JSON object.
          PROMPT
        end

        def call_anthropic(api_key, system_prompt, user_prompt)
          uri = URI('https://api.anthropic.com/v1/messages')
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.read_timeout = 45

          request = Net::HTTP::Post.new(uri)
          request['Content-Type'] = 'application/json'
          request['x-api-key'] = api_key
          request['anthropic-version'] = '2023-06-01'
          request.body = {
            model: 'claude-sonnet-4-20250514',
            max_tokens: 4000,
            system: system_prompt,
            messages: [{ role: 'user', content: user_prompt }]
          }.to_json

          response = http.request(request)
          unless response.code == '200'
            raise "Anthropic API error: #{response.code} - #{response.body}"
          end
          JSON.parse(response.body)
        end

        def parse_sequence_plan(content)
          json_match = content.match(/\{[\s\S]*\}/)
          return { 'name' => 'AI Sequence', 'steps' => [] } unless json_match
          JSON.parse(json_match[0])
        rescue JSON::ParserError => e
          Rails.logger.error "[AI Sequence] JSON parse error: #{e.message}"
          { 'name' => 'AI Sequence', 'steps' => [] }
        end

        def compute_cost_cents(input_tokens, output_tokens)
          input_cost = (input_tokens.to_f / 1_000_000) * 3.0
          output_cost = (output_tokens.to_f / 1_000_000) * 15.0
          ((input_cost + output_cost) * 100).round(2)
        end
      end
    end
  end
end
