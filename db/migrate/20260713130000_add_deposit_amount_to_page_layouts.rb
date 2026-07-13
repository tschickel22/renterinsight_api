class AddDepositAmountToPageLayouts < ActiveRecord::Migration[8.0]
  # Deposit is now a standard column on leads/contacts/accounts, but every
  # tenant that customized their page layout has a saved snapshot in
  # `page_layouts.layout_data` — and the FE renders forms and detail views
  # from that snapshot, so the new field is invisible until we add it.
  #
  # Insert a `deposit_amount` standard field entry into the 'details' section
  # (present in every tenant's layout for these modules). Skip layouts that
  # already reference deposit_amount anywhere.
  #
  # Deals are hardcoded in DealDetail/DealForm, not layout-driven — skipped.

  FIELD_ENTRY = {
    'key'      => 'deposit_amount',
    'type'     => 'standard',
    'label'    => 'Deposit',
    'width'    => 1,
    'visible'  => true,
    'required' => false
  }.freeze

  MODULES = %w[leads contacts accounts].freeze

  def up
    PageLayout.where(module_name: MODULES).find_each do |layout|
      sections = layout.layout_data&.dig('sections')
      next unless sections.is_a?(Array)

      already_present = sections.any? do |s|
        s['fields'].is_a?(Array) && s['fields'].any? { |f| f['key'] == 'deposit_amount' }
      end
      next if already_present

      target = sections.find { |s| s['id'] == 'details' } || sections.first
      target['fields'] ||= []
      target['fields'] << FIELD_ENTRY.dup

      layout.update_columns(layout_data: { 'sections' => sections }, updated_at: Time.current)
    end
  end

  def down
    PageLayout.where(module_name: MODULES).find_each do |layout|
      sections = layout.layout_data&.dig('sections')
      next unless sections.is_a?(Array)

      changed = false
      sections.each do |s|
        next unless s['fields'].is_a?(Array)
        before = s['fields'].size
        s['fields'] = s['fields'].reject { |f| f['key'] == 'deposit_amount' }
        changed = true if s['fields'].size != before
      end

      layout.update_columns(layout_data: { 'sections' => sections }, updated_at: Time.current) if changed
    end
  end
end
