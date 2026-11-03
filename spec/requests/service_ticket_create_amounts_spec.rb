# frozen_string_literal: true

require 'rails_helper'

# Issues sent with a new ticket skipped the amount rule that adding an issue to a
# saved ticket enforces, so a barred role could price through the new ticket form.
RSpec.describe 'New ticket issue amounts', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:ticket) { instance_double('ticket') }
  let(:controller_instance) { Api::V1::ServiceTicketsController.new }
  let(:issues) { double('issues') }
  let(:row) { { 'title' => 'Leak', 'pricing_status' => 'estimate', 'parts' => [{ 'name' => 'Seal', 'unit_price' => 9 }], 'labor' => [{ 'hours' => 1, 'rate' => 85 }] } }

  before do
    controller_instance.instance_variable_set(:@company, company)
    allow(controller_instance).to receive(:current_user).and_return(user)
    allow(ticket).to receive(:issues).and_return(issues)
    allow(ticket).to receive(:company_id).and_return(company.id)
    allow(ticket).to receive(:id).and_return(1)
  end

  it 'drops prices for a role barred from setting them' do
    allow_any_instance_of(ServiceWarrantyPolicy).to receive(:amount_setter?).and_return(false)
    expect(issues).to receive(:create!) do |attrs|
      expect(attrs[:parts]).to eq([])
      expect(attrs[:labor]).to eq([])
      expect(attrs[:pricing_status]).to eq('unpriced')
    end
    controller_instance.send(:create_submitted_issues, ticket, [row])
  end

  it 'keeps prices for a role allowed to set them' do
    allow_any_instance_of(ServiceWarrantyPolicy).to receive(:amount_setter?).and_return(true)
    expect(issues).to receive(:create!) do |attrs|
      expect(attrs[:labor]).to eq(row['labor'])
      expect(attrs[:pricing_status]).to eq('estimate')
    end
    controller_instance.send(:create_submitted_issues, ticket, [row])
  end
end
