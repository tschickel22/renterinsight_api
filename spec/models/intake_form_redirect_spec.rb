# frozen_string_literal: true

require 'rails_helper'

# After a submit the public form sends the visitor's browser to redirect_url,
# for example on to a lender's application once the lead is captured.
RSpec.describe IntakeForm, 'redirect after submit', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def form_with(url)
    IntakeForm.new(company_id: company.id, name: 'Get Pre-Qualified', redirect_url: url,
                   schema: [{ 'name' => 'email', 'type' => 'email', 'leadField' => 'email' }])
  end

  it 'takes a web address and trims it' do
    form = form_with('  https://askcade.cascadeloans.com/dealer/352-558-8888/applyprocess/steps ')
    expect(form).to be_valid
    expect(form.redirect_url).to eq('https://askcade.cascadeloans.com/dealer/352-558-8888/applyprocess/steps')
  end

  it 'stores a blank address as none' do
    expect(form_with('   ').tap(&:valid?).redirect_url).to be_nil
  end

  it 'refuses anything that is not a web page' do
    ['javascript:alert(1)', 'cascadeloans.com/apply', 'data:text/html,hi', 'https://'].each do |url|
      expect(form_with(url)).not_to be_valid, url
    end
  end
end
