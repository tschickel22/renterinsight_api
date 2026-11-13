# frozen_string_literal: true

module Assistant
  # What Quinn learns about a software prospect, put where the team works
  # (Tom, 2026-11-13): the company's own lead fields (custom fields, filled
  # only with their listed choices) and one "Quinn AI learned" note per chat
  # on the lead's Notes tab.
  #
  # Software companies only (Assistant::Software). Never overwrites a value a
  # person or a form already set; a multi-choice field only gains choices.
  module CrmFields
    TYPES = %w[text number select multiselect].freeze
    MAX_FIELDS = 25
    # Fields that hold what a person typed elsewhere, not something a
    # prospect says in a chat.
    SKIP_KEYS = /\Aold_|notes?\z|mobile|phone|email/i

    NOTE_LABELS = {
      'business_name' => 'Business', 'business_type' => 'Kind of business', 'locations' => 'Locations',
      'team_size' => 'Salespeople', 'current_system' => 'Uses today', 'demo_focus' => 'Wants covered on the demo',
      'timeline' => 'Timeline', 'budget' => 'Budget'
    }.freeze

    module_function

    def fields_for(company)
      return [] unless company

      CustomField.active.for_module('leads').where(company_id: company.id, field_type: TYPES)
                 .order(:display_order, :id).limit(MAX_FIELDS * 2).to_a
                 .reject { |f| f.field_key.to_s.match?(SKIP_KEYS) }.first(MAX_FIELDS)
    end

    # Lines for Quinn's prompt: each field it may fill, with its choices.
    def prompt_lines(company)
      fields_for(company).map do |f|
        choices = Array(f.options).compact_blank
        kind = case f.field_type
               when 'number' then 'a number'
               when 'select' then "one of: #{choices.join(' | ')}"
               when 'multiselect' then "any of: #{choices.join(' | ')}"
               else 'text'
               end
        "#{f.field_key} (#{f.label}): #{kind}"
      end.join("\n")
    end

    # The tool schema's crm_fields properties.
    def schema(company)
      fields_for(company).to_h do |f|
        type = f.field_type == 'multiselect' ? { type: 'array', items: { type: 'string' } } : { type: 'string' }
        [f.field_key, type.merge(description: f.label.to_s)]
      end
    end

    def apply!(lead, values)
      return if lead.nil? || values.blank? || !lead.has_attribute?(:custom_field_values)

      fields = fields_for(lead.company).index_by(&:field_key)
      current = (lead.custom_field_values || {}).deep_stringify_keys
      changes = {}
      values.to_h.each do |key, raw|
        field = fields[key.to_s]
        next unless field

        value = clean(field, raw)
        next if value.blank?

        if field.field_type == 'multiselect'
          have = Array(current[field.field_key])
          merged = (have + value).uniq
          changes[field.field_key] = merged if merged != have
        elsif current[field.field_key].blank?
          changes[field.field_key] = value
        end
      end
      lead.update_columns(custom_field_values: current.merge(changes), updated_at: Time.current) if changes.any?
    rescue StandardError => e
      Rails.logger.warn("[Assistant::CrmFields] lead #{lead&.id}: #{e.class}: #{e.message}")
    end

    def clean(field, raw)
      choices = Array(field.options).compact_blank
      case field.field_type
      when 'number' then raw.to_s[/\d+(\.\d+)?/]
      when 'select' then match_choice(choices, raw)
      when 'multiselect' then Array(raw).filter_map { |v| match_choice(choices, v) }.uniq.presence
      else raw.to_s.squish.truncate(250).presence
      end
    end

    def match_choice(choices, raw)
      text = raw.to_s.strip.downcase
      text.present? ? choices.detect { |c| c.to_s.downcase == text } : nil
    end

    # One note per chat, rewritten as they tell Quinn more.
    def note!(conversation)
      lead = conversation.conversable
      return unless lead.is_a?(Lead)

      details = (conversation.qualification || {}).slice(*NOTE_LABELS.keys).compact_blank
      return if details.empty?

      heading = "#{Assistant::Settings.for(conversation.company).assistant_name} AI learned (conversation #{conversation.id})"
      content = "#{heading}\n\n#{details.map { |k, v| "#{NOTE_LABELS[k]}: #{v.to_s.truncate(300)}" }.join("\n")}"
      note = Note.where(entity_type: 'lead', entity_id: lead.id.to_s).where('content LIKE ?', "#{Note.sanitize_sql_like(heading)}%").first
      if note
        note.update!(content: content) if note.content != content
      else
        Note.create!(entity_type: 'lead', entity_id: lead.id.to_s, content: content, created_by_name: heading.split(' learned').first)
      end
    rescue StandardError => e
      Rails.logger.warn("[Assistant::CrmFields] note for conversation #{conversation.id}: #{e.class}: #{e.message}")
    end
  end
end
