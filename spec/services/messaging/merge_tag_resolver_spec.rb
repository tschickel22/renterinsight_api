# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::MergeTagResolver do
  describe '.resolve' do
    let(:context) do
      {
        'first_name' => 'Alex',
        'last_name'  => 'Rivera',
        'full_name'  => 'Alex Rivera',
        'email'      => 'alex@example.com',
        'company'    => { 'name' => 'Acme MH', 'website' => 'https://acme.test' },
        'public_inventory_url' => 'https://acme.test/inv'
      }
    end

    it 'resolves simple top-level tags' do
      out = described_class.resolve("Hi {{first_name}}!", context)
      expect(out).to eq("Hi Alex!")
    end

    it 'resolves nested dotted paths' do
      out = described_class.resolve("Visit {{company.name}} at {{company.website}}", context)
      expect(out).to eq("Visit Acme MH at https://acme.test")
    end

    it 'returns empty string for missing tags rather than raising' do
      out = described_class.resolve("Hello {{missing_field}} done", context)
      expect(out).to eq("Hello  done")
    end

    it 'returns empty string when input is nil' do
      expect(described_class.resolve(nil, context)).to eq('')
    end

    it 'tolerates whitespace inside braces' do
      out = described_class.resolve("Hi {{  first_name  }}", context)
      expect(out).to eq("Hi Alex")
    end

    it 'is case-insensitive for tag names' do
      out = described_class.resolve("{{FIRST_NAME}}", context)
      expect(out).to eq("Alex")
    end
  end

  describe '.build_context' do
    let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
    let(:source)  { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
    let(:lead) do
      Lead.create!(company: company, source: source,
                   first_name: 'Sam', last_name: 'Kim', email: 's@example.com', phone: '555')
    end

    it 'extracts first/last/full name from a Lead' do
      ctx = described_class.build_context(recipient: lead, company: company, urls: { unsubscribe_url: 'https://u' })
      expect(ctx['first_name']).to eq('Sam')
      expect(ctx['last_name']).to eq('Kim')
      expect(ctx['full_name']).to eq('Sam Kim')
      expect(ctx['email']).to eq('s@example.com')
      expect(ctx['company']['name']).to eq(company.name)
      expect(ctx['unsubscribe_url']).to eq('https://u')
    end

    it 'falls back to record.name when first/last missing' do
      account = Class.new do
        def name; 'Northwest Modular'; end
        def email; 'info@nw.test'; end
        def phone; nil; end
      end.new
      ctx = described_class.build_context(recipient: account, company: company)
      expect(ctx['first_name']).to eq('Northwest')
      expect(ctx['last_name']).to eq('Modular')
      expect(ctx['full_name']).to eq('Northwest Modular')
    end
  end
end
