# frozen_string_literal: true

require 'rails_helper'

# Lead create validated every active required custom field for the module,
# whether or not the form asked for it. Evangeline had a required question that
# no layout section placed, so every create came back 422 naming a field that
# was never on screen. Required is only enforceable where the form asks.
RSpec.describe Api::Crm::LeadsController, type: :controller do
  let(:company) { FactoryBot.create(:company) }
  let(:controller_instance) do
    described_class.new.tap { |c| c.instance_variable_set(:@company, company) }
  end

  let!(:placed) do
    CustomField.create!(company: company, module: 'leads', name: 'Living situation',
                        field_type: 'text', required: true, is_active: true)
  end

  let!(:unplaced) do
    CustomField.create!(company: company, module: 'leads', name: 'Goal time frame',
                        field_type: 'text', required: true, is_active: true)
  end

  def build_layout(fields)
    company.page_layouts.create!(
      module_name: 'leads', layout_type: 'detail',
      layout_data: { 'sections' => [{ 'id' => 'facebook', 'title' => 'Intake', 'fields' => fields }] }
    )
  end

  def validate(values, partial: false)
    controller_instance.send(:validate_custom_field_values, 'leads', values, partial: partial)
  end

  context 'when a required field is not placed in the layout' do
    before do
      build_layout([{ 'key' => placed.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 }])
    end

    it 'does not demand the unplaced field' do
      expect(validate({ placed.field_key => 'Renting' })).to be_empty
    end

    it 'still demands the field the form does ask for' do
      errors = validate({ placed.field_key => '' , 'something_else' => 'x' })

      expect(errors).to include(a_string_matching(/Living situation is required/))
      expect(errors).not_to include(a_string_matching(/Goal time frame/))
    end

    # Placement decides whether a field is *demanded*, never whether a value
    # that did arrive is checked.
    it 'validates a value submitted for an unplaced field' do
      number = CustomField.create!(company: company, module: 'leads', name: 'Budget',
                                   field_type: 'number', required: false, is_active: true)

      errors = validate({ placed.field_key => 'Renting', number.field_key => 'not a number' })

      expect(errors).to include(a_string_matching(/Budget must be a number/))
    end
  end

  context 'when a required field is placed but hidden' do
    before do
      build_layout([
                     { 'key' => placed.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 },
                     { 'key' => unplaced.field_key, 'type' => 'custom', 'visible' => false, 'required' => true, 'width' => 1 }
                   ])
    end

    it 'does not demand the hidden field' do
      expect(validate({ placed.field_key => 'Renting' })).to be_empty
    end
  end

  context 'when both required fields are placed and visible' do
    before do
      build_layout([
                     { 'key' => placed.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 },
                     { 'key' => unplaced.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 }
                   ])
    end

    it 'demands both' do
      errors = validate({ placed.field_key => 'Renting' })

      expect(errors).to include(a_string_matching(/Goal time frame is required/))
    end
  end

  context 'with no layout to consult' do
    it 'falls back to validating every required field' do
      errors = validate({ placed.field_key => 'Renting' })

      expect(errors).to include(a_string_matching(/Goal time frame is required/))
    end
  end

  it 'still checks only submitted keys on a partial update' do
    build_layout([
                   { 'key' => placed.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 },
                   { 'key' => unplaced.field_key, 'type' => 'custom', 'visible' => true, 'required' => true, 'width' => 1 }
                 ])

    expect(validate({ placed.field_key => 'Renting' }, partial: true)).to be_empty
  end
end
