# frozen_string_literal: true

require 'rails_helper'

# A landing page's auto-built form had no source, so every lead it produced
# was filed under "Web Form" and a dealer could not tell landing page leads
# apart from any other website inquiry.
RSpec.describe 'Landing page form source', type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def source_for(params)
    controller = Api::V1::LandingPagesController.new
    controller.instance_variable_set(:@company, company)
    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(params))
    controller.send(:landing_page_source)
  end

  it 'files the form under one "Landing Page" source by default' do
    first = source_for({})
    second = source_for({})

    expect(first.name).to eq('Landing Page')
    expect(second.id).to eq(first.id)
    expect(first.company_id).to eq(company.id)
  end

  it 'uses a source the caller names' do
    facebook = company.sources.create!(name: 'Facebook', is_active: true)

    expect(source_for(source_id: facebook.id)).to eq(facebook)
  end

  it "ignores another company's source" do
    other = Company.create!(name: "X-#{SecureRandom.hex(4)}", industry: 'manufactured_housing')
    theirs = other.sources.create!(name: 'Theirs', is_active: true)

    expect(source_for(source_id: theirs.id).name).to eq('Landing Page')
  end

  it 'saves the source on the form it builds' do
    source = source_for({})

    form = Marketing::LandingPageFormBuilder.new(company: company, title: 'Spring sale', source: source).call

    expect(form.source_id).to eq(source.id)
  end
end
