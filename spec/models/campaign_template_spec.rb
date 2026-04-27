# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignTemplate, type: :model do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }

  it "validates slug, name, category, vertical presence" do
    t = CampaignTemplate.new
    expect(t).not_to be_valid
    %i[slug name category vertical].each { |k| expect(t.errors[k]).to be_present }
  end

  it "validates category inclusion" do
    t = CampaignTemplate.new(slug: "x", name: "X", category: "bogus", vertical: "b2b")
    expect(t).not_to be_valid
    expect(t.errors[:category]).to be_present
  end

  describe ".for_company_or_seeded" do
    let!(:seeded) do
      CampaignTemplate.create!(slug: "platform-#{SecureRandom.hex(4)}", name: "P", category: "b2b_saas_sales",
                               vertical: "b2b", is_seeded: true)
    end
    let!(:owned) do
      CampaignTemplate.create!(company_id: company.id, slug: "owned-#{SecureRandom.hex(4)}",
                               name: "O", category: "b2b_saas_sales", vertical: "b2b")
    end
    let!(:other_company_owned) do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      CampaignTemplate.create!(company_id: other.id, slug: "other-#{SecureRandom.hex(4)}",
                               name: "X", category: "b2b_saas_sales", vertical: "b2b")
    end

    it "returns both company-owned and seeded templates" do
      result = CampaignTemplate.for_company_or_seeded(company.id)
      expect(result).to include(seeded)
      expect(result).to include(owned)
    end

    it "excludes other companies' owned templates" do
      result = CampaignTemplate.for_company_or_seeded(company.id)
      expect(result).not_to include(other_company_owned)
    end
  end
end
