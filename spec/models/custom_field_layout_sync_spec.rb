# frozen_string_literal: true

require 'rails_helper'

# Forms decide what to enforce from the layout's copy of `required`, not from
# CustomField#required. When the two drift, an admin who un-requires a field
# sees nothing change, and a field that was deleted becomes a required field
# with no definition to render from — invisible on the form, but still blocking
# every save in the module.
RSpec.describe 'CustomField → PageLayout sync' do
  let(:company) { FactoryBot.create(:company) }

  let!(:field) do
    CustomField.create!(
      company: company,
      module: 'leads',
      name: 'Preferred move date',
      field_type: 'date',
      required: true,
      is_active: true
    )
  end

  let!(:layout) do
    company.page_layouts.create!(
      module_name: 'leads',
      layout_type: 'detail',
      layout_data: {
        'sections' => [
          {
            'id' => 'details',
            'title' => 'Details',
            'fields' => [
              { 'key' => 'first_name', 'type' => 'standard', 'visible' => true, 'required' => true, 'width' => 1 },
              { 'key' => field.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 }
            ]
          }
        ]
      }
    )
  end

  def layout_entry(key)
    layout.reload.layout_data['sections'].flat_map { |s| s['fields'] }.find { |f| f['key'] == key }
  end

  it 'clears the layout required flag when the field is made optional' do
    field.update!(required: false)

    expect(layout_entry(field.field_key)['required']).to be false
    expect(layout_entry('first_name')['required']).to be true
  end

  it 'sets the layout required flag when the field is made required' do
    field.update!(required: false)
    field.update!(required: true)

    expect(layout_entry(field.field_key)['required']).to be true
  end

  it 'drops the entry when the field is deactivated' do
    field.update!(is_active: false)

    expect(layout_entry(field.field_key)).to be_nil
    expect(layout_entry('first_name')).to be_present
  end

  it 'leaves layouts for other modules alone' do
    contacts = company.page_layouts.create!(
      module_name: 'contacts',
      layout_type: 'detail',
      layout_data: {
        'sections' => [
          { 'id' => 'main', 'title' => 'Main',
            'fields' => [{ 'key' => field.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 }] }
        ]
      }
    )

    field.update!(required: false)

    entry = contacts.reload.layout_data['sections'].first['fields'].first
    expect(entry['required']).to be true
  end

  it 'reaches layout variants that share the module catalog' do
    inventory_field = CustomField.create!(
      company: company,
      module: 'inventory',
      name: 'Lot number',
      field_type: 'text',
      required: true,
      is_active: true
    )
    rv_layout = company.page_layouts.create!(
      module_name: 'inventory_rv',
      layout_type: 'detail',
      layout_data: {
        'sections' => [
          { 'id' => 'main', 'title' => 'Main',
            'fields' => [{ 'key' => inventory_field.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 }] }
        ]
      }
    )

    inventory_field.update!(required: false)

    entry = rv_layout.reload.layout_data['sections'].first['fields'].first
    expect(entry['required']).to be false
  end

  it 'does not rewrite the layout when an unrelated attribute changes' do
    expect { field.update!(label: 'Move date') }
      .not_to(change { layout.reload.updated_at })
  end

  describe '#reconcile_custom_fields!' do
    # The blocking case from production: a required entry pointing at a key no
    # custom field answers to. It renders nothing and fails validation forever.
    before do
      data = layout.layout_data.deep_dup
      data['sections'].first['fields'] << {
        'key' => 'question_nobody_owns', 'type' => 'custom',
        'visible' => true, 'required' => true, 'width' => 1
      }
      layout.update!(layout_data: data)
    end

    it 'removes entries with no live custom field and keeps the rest' do
      result = layout.reconcile_custom_fields!({ field.field_key => true })

      expect(result[:removed]).to eq(['question_nobody_owns'])
      expect(layout_entry('question_nobody_owns')).to be_nil
      expect(layout_entry(field.field_key)).to be_present
      expect(layout_entry('first_name')).to be_present
    end

    it 'never touches standard entries, whose definitions are code, not rows' do
      layout.reconcile_custom_fields!({})

      expect(layout_entry('first_name')).to be_present
    end

    # deposit_amount lives in a few tenants as a 'custom'-typed entry left over
    # from before it became a standard field. Forms render it from the standard
    # definition, so pruning it would delete a field that works.
    it 'keeps custom-typed entries whose key is now a standard field' do
      data = layout.layout_data.deep_dup
      data['sections'].first['fields'] << {
        'key' => 'deposit_amount', 'type' => 'custom',
        'visible' => true, 'required' => false, 'width' => 1
      }
      layout.update!(layout_data: data)

      layout.reconcile_custom_fields!({}, standard_keys: ['deposit_amount'])

      expect(layout_entry('deposit_amount')).to be_present
    end

    # The drift case: the field was un-required somewhere that didn't write the
    # layout, so the form kept demanding it.
    it 'pulls the required flag back in line with the field' do
      result = layout.reconcile_custom_fields!({ field.field_key => false, 'question_nobody_owns' => true })

      expect(result[:updated]).to eq([field.field_key])
      expect(layout_entry(field.field_key)['required']).to be false
    end

    it 'leaves the layout untouched when everything already agrees' do
      state = { field.field_key => true, 'question_nobody_owns' => true }
      layout.reconcile_custom_fields!(state)

      expect { layout.reconcile_custom_fields!(state) }
        .not_to(change { layout.reload.updated_at })
    end

    it 'covers layout variants sharing the inventory catalog' do
      rv = company.page_layouts.create!(module_name: 'inventory_rv', layout_type: 'detail', layout_data: { 'sections' => [] })
      expect(rv.custom_field_modules).to contain_exactly('inventory_rv', 'inventory')
    end
  end
end
