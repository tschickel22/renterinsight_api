# frozen_string_literal: true

class CustomFieldMigrationService
  # Sets up migration mappings for a source custom field.
  #
  # @param source_custom_field [CustomField] the lead custom field to migrate from
  # @param mappings [Array<Hash>] each: { target_module:, migration_type:, target_custom_field_id: (optional) }
  # @param company [Company]
  # @return [Hash] { success: true, migrations: [...] } or { success: false, errors: [...] }
  def self.setup_migrations(source_custom_field, mappings, company)
    errors = []
    created_migrations = []

    ActiveRecord::Base.transaction do
      mappings.each do |mapping|
        target_module = mapping[:target_module]
        migration_type = mapping[:migration_type] || 'create_new'

        # Remove any existing mapping for this source + target_module
        company.custom_field_migrations
          .where(source_custom_field: source_custom_field, target_module: target_module)
          .destroy_all

        target_field = nil

        case migration_type
        when 'create_new'
          # Eagerly create a matching custom field on the target module
          target_field = company.custom_fields.create!(
            name: source_custom_field.name,
            label: source_custom_field.label,
            field_type: source_custom_field.field_type,
            module: target_module,
            options: source_custom_field.options,
            validation_rules: source_custom_field.validation_rules,
            required: false,
            is_active: true,
            is_system_field: false,
            section: source_custom_field.section,
            description: source_custom_field.description,
            placeholder: source_custom_field.placeholder,
            display_order: source_custom_field.display_order,
            visibility: source_custom_field.visibility
          )
          Rails.logger.info "[CustomFieldMigrationService] Created target field #{target_field.id} (#{target_field.field_key}) on #{target_module}"

          # Add the new field to the target module's page layout so it's visible in the UI
          add_field_to_page_layout(company, target_module, target_field)

        when 'map_to_existing'
          target_field_id = mapping[:target_custom_field_id]
          target_field = company.custom_fields.find_by(id: target_field_id)
          unless target_field
            errors << "Target custom field #{target_field_id} not found for module #{target_module}"
            next
          end

        when 'skip'
          # No target field needed
        else
          errors << "Unknown migration_type: #{migration_type}"
          next
        end

        cfm = company.custom_field_migrations.create!(
          source_custom_field: source_custom_field,
          target_module: target_module,
          target_custom_field: target_field,
          migration_type: migration_type
        )

        created_migrations << cfm
        Rails.logger.info "[CustomFieldMigrationService] Created migration #{cfm.id}: #{migration_type} -> #{target_module}"
      end

      if errors.any?
        raise ActiveRecord::Rollback
      end
    end

    if errors.any?
      { success: false, errors: errors }
    else
      { success: true, migrations: created_migrations }
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "[CustomFieldMigrationService] Validation error: #{e.message}"
    { success: false, errors: [e.message] }
  end

  # Copies custom field values from a lead to its converted entities.
  # Called during lead conversion.
  #
  # @param lead [Lead]
  # @param contact [Contact, nil]
  # @param account [Account, nil]
  # @param deal [Deal, nil]
  # @return [Hash] { copied: N, gaps: [...] }
  def self.copy_values(lead, contact: nil, account: nil, deal: nil)
    targets = { 'contacts' => contact, 'accounts' => account, 'deals' => deal }
    copied = 0
    gaps = []

    migrations = CustomFieldMigration.for_company(lead.company)
      .where(source_custom_field_id: lead.company.custom_fields.for_module('leads').select(:id))
      .includes(:source_custom_field, :target_custom_field)

    migrations.each do |migration|
      next if migration.skip?

      target = targets[migration.target_module]
      next unless target # Target entity wasn't created during this conversion

      source_field = migration.source_custom_field
      target_field = migration.target_custom_field

      # Check if target field was deleted
      if migration.target_custom_field_id.present? && target_field.nil?
        value = lead.custom_field_values&.dig(source_field.field_key)
        gaps << {
          source_field_label: source_field.label,
          target_module: migration.target_module,
          lead_value: value,
          reason: 'target_field_deleted'
        }
        Rails.logger.warn "[CustomFieldMigrationService] Gap: target field deleted for migration #{migration.id}"
        next
      end

      next unless target_field

      value = lead.custom_field_values&.dig(source_field.field_key)
      next if value.nil?

      target.custom_field_values ||= {}
      target.custom_field_values[target_field.field_key] = value
      copied += 1
    end

    # Save all modified targets
    targets.each_value do |entity|
      next unless entity
      entity.save! if entity.changed?
    end

    Rails.logger.info "[CustomFieldMigrationService] Copied #{copied} field values, #{gaps.size} gaps"
    { copied: copied, gaps: gaps }
  rescue => e
    Rails.logger.error "[CustomFieldMigrationService] Error copying values: #{e.message}"
    { copied: copied, gaps: gaps, error: e.message }
  end

  # Checks integrity of custom field migration mappings for a lead.
  # Returns gaps where target fields no longer exist.
  #
  # @param lead [Lead]
  # @return [Array<Hash>] array of gap hashes
  def self.check_integrity(lead)
    gaps = []

    migrations = CustomFieldMigration.for_company(lead.company)
      .where(source_custom_field_id: lead.company.custom_fields.for_module('leads').select(:id))
      .includes(:source_custom_field, :target_custom_field)

    migrations.each do |migration|
      next if migration.skip?
      next if migration.target_custom_field_id.blank?

      if migration.target_custom_field.nil?
        value = lead.custom_field_values&.dig(migration.source_custom_field.field_key)
        gaps << {
          source_field_label: migration.source_custom_field.label,
          target_module: migration.target_module,
          lead_value: value,
          reason: 'target_field_deleted'
        }
      end
    end

    gaps
  end

  # Adds a custom field entry to the best-matching section of the target
  # module's page layout based on keyword heuristics on the field label.
  def self.add_field_to_page_layout(company, module_name, custom_field)
    layout = company.page_layouts.find_by(module_name: module_name, layout_type: 'detail')
    return unless layout

    sections = layout.layout_data&.dig('sections')
    return unless sections.is_a?(Array)

    field_entry = {
      'key' => custom_field.field_key,
      'type' => 'custom',
      'width' => 1,
      'visible' => true,
      'required' => false
    }

    # Check if field already exists in any section
    already_exists = sections.any? do |s|
      s['fields']&.any? { |f| f['key'] == custom_field.field_key }
    end
    return if already_exists

    target_section = best_section_for_field(sections, custom_field) || sections.first
    target_section['fields'] ||= []
    target_section['fields'] << field_entry

    layout.update!(layout_data: { 'sections' => sections })
    Rails.logger.info "[CustomFieldMigrationService] Added #{custom_field.field_key} to section '#{target_section['title']}' in #{module_name} page layout"
  rescue => e
    Rails.logger.warn "[CustomFieldMigrationService] Could not update page layout for #{module_name}: #{e.message}"
  end

  # Keyword-to-section-id mapping for each module.
  # Keys are section IDs, values are arrays of keywords that indicate a field
  # belongs in that section.
  SECTION_HINTS = {
    'accounts' => {
      'account_info'     => %w[name email phone website company type industry],
      'details'          => %w[status rating source owner revenue employee size annual],
      'billing_address'  => %w[billing address],
      'shipping_address' => %w[shipping],
      'notes_section'    => %w[note description comment]
    },
    'contacts' => {
      'contact_info' => %w[name email phone cell mobile call],
      'details'      => %w[title department company account owner role job position],
      'address'      => %w[address street city state zip country],
      'preferences'  => %w[opt preference sms notification],
      'notes_section' => %w[note description comment]
    },
    'deals' => {
      'deal_info'      => %w[name customer stage value probability type source owner referral lead],
      'deal_dates'     => %w[date close delivery expected deadline timeline schedule],
      'deal_economics' => %w[price cost revenue budget amount fee margin discount trade selling payment finance financing],
      'deal_outcome'   => %w[win loss reason competitor outcome result],
      'deal_notes'     => %w[note description comment]
    }
  }.freeze

  # Returns the best-matching section for a field, or nil if no strong match.
  def self.best_section_for_field(sections, custom_field)
    label = custom_field.label&.downcase || custom_field.name&.downcase || ''
    key   = custom_field.field_key&.downcase || ''
    text  = "#{label} #{key}"

    section_ids = sections.map { |s| s['id'] }

    # Try all modules' hints (the layout sections will only match their own IDs)
    best_id = nil
    best_score = 0

    SECTION_HINTS.each_value do |hint_map|
      hint_map.each do |section_id, keywords|
        next unless section_ids.include?(section_id)

        score = keywords.count { |kw| text.include?(kw) }
        if score > best_score
          best_score = score
          best_id = section_id
        end
      end
    end

    return sections.find { |s| s['id'] == best_id } if best_id

    # Fallback: prefer first section that already has custom-type fields,
    # then the generic "custom_fields" section, then nil
    sections.find { |s| s['fields']&.any? { |f| f['type'] == 'custom' } } ||
      sections.find { |s| s['id'] == 'custom_fields' }
  end
end
