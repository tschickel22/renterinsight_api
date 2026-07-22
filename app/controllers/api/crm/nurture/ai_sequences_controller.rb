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
          attachment_context = params[:attachment_context].to_s
          attachments_payload = sanitize_attachments_param(params[:attachments])
          include_inventory = ActiveModel::Type::Boolean.new.cast(params[:include_inventory])

          company_profile = Setting.get('Company', @company.id, 'company_profile') || {}
          sender_context = build_sender_context(current_user)
          business_name = business_display_name(current_location, @company)

          system_prompt = build_sequence_system_prompt(company_profile, sender_context, business_name)
          user_prompt = build_sequence_user_prompt(
            goal, entity_type, audience_stage, channels, max_steps, custom_instructions,
            attachment_context: attachment_context, attachments: attachments_payload,
            include_inventory: include_inventory
          )

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
          rescue Net::ReadTimeout, Net::OpenTimeout => e
            AiQueryLog.create!(
              company: @company,
              user: current_user,
              feature: 'ai_sequence_generate',
              module_key: 'nurture',
              question: "Generate sequence: #{goal}",
              execution_status: 'error',
              input_tokens: 0, output_tokens: 0, cost_cents: 0,
              generated_params: { error: "Timeout: #{e.message}" }
            )
            Rails.logger.error "[AI Sequence] Timeout: #{e.message}"
            render json: {
              error: 'ai_timeout',
              message: "The AI took too long to respond. This usually happens with very detailed goals or many uploaded files — try a shorter goal or fewer attachments and retry."
            }, status: :gateway_timeout
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
            render json: {
              error: 'ai_generation_failed',
              message: "AI generation failed: #{e.message.to_s.first(200)}"
            }, status: :unprocessable_entity
          end
        end

        # POST /api/crm/nurture/ai_sequences/save
        # Creates the NurtureSequence + NurtureSteps + Templates in one transaction
        def save
          sequence_data = params[:sequence] || {}
          steps_data = params[:steps] || []
          available_attachments = sanitize_attachments_param(params[:attachments])
          attachments_by_filename = available_attachments.index_by { |a| a['filename'] }

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

              step_attachments = build_step_attachments(step[:attachments], attachments_by_filename)

              step_include_inventory = ActiveModel::Type::Boolean.new.cast(
                step[:include_inventory].nil? ? step['include_inventory'] : step[:include_inventory]
              )

              step_inventory_display_mode =
                (step[:inventory_display_mode].presence || step['inventory_display_mode'].presence || 'auto').to_s

              # Optional admin-selected inventory filters from the AI modal —
              # applied per step so the AI plan's inventory recommendations
              # honor the same filters the runtime resolver uses.
              step_inventory_statuses = Array(
                step[:inventory_statuses] || step['inventory_statuses'] ||
                step[:inventoryStatuses] || step['inventoryStatuses']
              ).map(&:to_s).reject(&:blank?)

              step_inventory_require_images = ActiveModel::Type::Boolean.new.cast(
                step[:inventory_require_images] || step['inventory_require_images'] ||
                step[:inventoryRequireImages] || step['inventoryRequireImages'] || false
              )

              sequence.nurture_steps.create!(
                position: index,
                step_type: step[:step_type] || step[:channel] || 'email',
                channel: step[:channel] || 'email',
                wait_days: step[:wait_days] || 0,
                subject: step[:subject],
                body: step[:body],
                template_id: template&.id,
                attachments: step_attachments,
                include_inventory: step_include_inventory ? true : false,
                inventory_display_mode: step_inventory_display_mode,
                inventory_statuses: step_inventory_statuses,
                inventory_require_images: step_inventory_require_images
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

        def build_sequence_user_prompt(goal, entity_type, audience_stage, channels, max_steps, custom_instructions,
                                       attachment_context: '', attachments: [], include_inventory: false)
          stage_descriptions = {
            'cold' => 'Never interacted or very first contact. They may not know the business.',
            'warm' => 'Showed interest — visited website, downloaded content, inquired, attended event.',
            'hot' => 'Actively shopping, requested pricing, toured/visited. Ready to buy soon.',
            'customer' => 'Already purchased. Goal is relationship building, upsell, review/referral.',
            'churned' => 'Was interested or was a customer but went silent. Need to re-engage.'
          }

          attachment_block = build_attachment_prompt_block(attachment_context, attachments)
          inventory_block  = build_inventory_prompt_block(include_inventory)

          <<~PROMPT
            Build a nurture sequence with these specifications:

            GOAL: #{goal}
            ENTITY TYPE: #{entity_type}
            AUDIENCE STAGE: #{audience_stage} — #{stage_descriptions[audience_stage] || audience_stage}
            CHANNELS TO USE: #{Array(channels).join(', ')}
            MAX STEPS: #{max_steps}

            #{custom_instructions.present? ? "ADDITIONAL INSTRUCTIONS: #{custom_instructions}" : ''}

            #{attachment_block}

            #{inventory_block}

            Generate the full sequence as a JSON object.
          PROMPT
        end

        # When the user opts in to inventory injection, tell the model to mark
        # email steps with include_inventory: true. The runtime swaps in matching
        # homes at send time based on the recipient's preferences.
        def build_inventory_prompt_block(include_inventory)
          return '' unless include_inventory
          <<~INV.strip
            INVENTORY:
            Include personalized home recommendations in email steps. Set "include_inventory": true on email steps.
            The system auto-injects matching homes at send time based on the recipient's preferences, prior clicks, and budget.
            Write copy that naturally references available homes (e.g. "I picked a few homes that match what you're looking for") so the injected gallery feels intentional.
          INV
        end

        # Sanitize attachment metadata coming from the frontend so we only retain
        # the small set of fields we actually use downstream.
        def sanitize_attachments_param(raw)
          return [] if raw.blank?
          arr = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h.values : Array(raw)
          arr.map do |a|
            h = a.respond_to?(:to_unsafe_h) ? a.to_unsafe_h : a.to_h
            {
              'filename'      => h['filename'] || h[:filename],
              's3_key'        => h['s3_key']   || h[:s3_key],
              'content_type'  => h['content_type'] || h[:content_type],
              'size'          => h['size'] || h[:size],
              'delivery_mode' => h['delivery_mode'] || h[:delivery_mode] || 'tracked_link'
            }.compact
          end.select { |a| a['filename'].present? && a['s3_key'].present? }
        end

        # Build the attachment-aware prompt block. Only injected when the user
        # has actually uploaded documents.
        def build_attachment_prompt_block(attachment_context, attachments)
          return '' if attachment_context.blank? && attachments.blank?

          lines = []
          lines << 'ATTACHMENTS AVAILABLE:'
          if attachments.any?
            lines << 'The user has uploaded the following files. Each step may reference zero or more of them by filename.'
            attachments.each do |a|
              lines << "  - #{a['filename']} (#{a['content_type'] || 'file'})"
            end
          end

          if attachment_context.present?
            lines << ''
            lines << 'The user has uploaded the following documents that should be referenced in the sequence:'
            lines << '---'
            # Cap to keep prompt size reasonable
            lines << attachment_context.to_s.first(8000)
            lines << '---'
            lines << 'When appropriate, reference these documents naturally in your email copy. Indicate which step should include each attachment.'
          end

          lines << ''
          lines << 'For each step you generate, include an "attachments" array. Each entry should be:'
          lines << '  { "filename": "<exact filename from list above>", "recommended": true }'
          lines << 'Only include an attachment when it is genuinely relevant to that step. Omit the array if no files apply.'

          lines.join("\n")
        end

        # Map AI step-level attachment hints to step.attachments JSONB entries,
        # only honoring files the user actually uploaded.
        def build_step_attachments(step_attachments, attachments_by_filename)
          return [] if step_attachments.blank? || attachments_by_filename.blank?

          list = if step_attachments.respond_to?(:to_unsafe_h)
                   step_attachments.to_unsafe_h.values
                 else
                   Array(step_attachments)
                 end

          list.map do |hint|
            h = hint.respond_to?(:to_unsafe_h) ? hint.to_unsafe_h : hint.to_h
            recommended = h['recommended']
            recommended = h[:recommended] if recommended.nil?
            next nil if recommended == false

            filename = h['filename'] || h[:filename]
            source   = attachments_by_filename[filename]
            next nil unless source

            {
              's3_key'        => source['s3_key'],
              'filename'      => source['filename'],
              'content_type'  => source['content_type'],
              'size'          => source['size'],
              'delivery_mode' => source['delivery_mode'] || 'tracked_link'
            }
          end.compact
        end

        def call_anthropic(api_key, system_prompt, user_prompt)
          uri = URI('https://api.anthropic.com/v1/messages')
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 10
          http.read_timeout = 90

          request = Net::HTTP::Post.new(uri)
          request['Content-Type'] = 'application/json'
          request['x-api-key'] = api_key
          request['anthropic-version'] = '2023-06-01'
          request.body = {
            model: AiModel.for(:generation),
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
