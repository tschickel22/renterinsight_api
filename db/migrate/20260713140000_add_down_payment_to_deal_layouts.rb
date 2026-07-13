class AddDownPaymentToDealLayouts < ActiveRecord::Migration[8.0]
  # DealDetail overview + inline edit are layout-driven for tenants who
  # customized their deal page layout. The deposit column (deals.down_payment)
  # won't render there until the field appears in the saved layout_data.
  #
  # For Evangeline (company 17), their layout already has a custom-field entry
  # named "deposit_amount" that pointed at the now-deactivated custom_fields
  # row — rename that entry to the standard `down_payment` key so it keeps the
  # exact position the user already picked (currently in deal_info section).
  #
  # For every other tenant with a saved deal layout, insert a `down_payment`
  # entry into the deal_info section just after owner_id (per the user's
  # request "below owner/sales rep name").

  FIELD_ENTRY = {
    'key'      => 'down_payment',
    'type'     => 'standard',
    'label'    => 'Deposit',
    'width'    => 1,
    'visible'  => true,
    'required' => false
  }.freeze

  def up
    PageLayout.where(module_name: 'deals').find_each do |layout|
      sections = layout.layout_data&.dig('sections')
      next unless sections.is_a?(Array)

      changed = false

      # Rename any existing deposit_amount entry to down_payment. This preserves
      # the placement the tenant already chose. Keeps the entry's own width /
      # visible / required flags but forces type to 'standard'.
      sections.each do |s|
        next unless s['fields'].is_a?(Array)
        s['fields'].each do |f|
          next unless f['key'] == 'deposit_amount'
          f['key']  = 'down_payment'
          f['type'] = 'standard'
          f['label'] = 'Deposit' if f['label'].blank? || f['label'] == 'Deposit Amount'
          changed = true
        end
      end

      # If no down_payment entry now exists (either renamed or already there),
      # add one to the deal_info section after owner_id.
      already_present = sections.any? do |s|
        s['fields'].is_a?(Array) && s['fields'].any? { |f| f['key'] == 'down_payment' }
      end

      unless already_present
        target = sections.find { |s| s['id'] == 'deal_info' } || sections.first
        target['fields'] ||= []
        insert_index = target['fields'].index { |f| f['key'] == 'owner_id' }
        insert_at = insert_index ? insert_index + 1 : target['fields'].length
        target['fields'].insert(insert_at, FIELD_ENTRY.dup)
        changed = true
      end

      layout.update_columns(layout_data: { 'sections' => sections }, updated_at: Time.current) if changed
    end
  end

  def down
    PageLayout.where(module_name: 'deals').find_each do |layout|
      sections = layout.layout_data&.dig('sections')
      next unless sections.is_a?(Array)

      changed = false
      sections.each do |s|
        next unless s['fields'].is_a?(Array)
        before = s['fields'].size
        s['fields'] = s['fields'].reject { |f| f['key'] == 'down_payment' }
        changed = true if s['fields'].size != before
      end

      layout.update_columns(layout_data: { 'sections' => sections }, updated_at: Time.current) if changed
    end
  end
end
