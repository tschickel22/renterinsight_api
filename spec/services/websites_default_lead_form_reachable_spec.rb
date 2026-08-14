# frozen_string_literal: true

require 'rails_helper'

# The resolver chose on a form's name alone. A form called "Contact Us" that
# asks for a first name and a budget reads as the ideal general form and is the
# one form guaranteed to waste every enquiry it receives, because the lead
# arrives with no way to answer it.
RSpec.describe Websites::DefaultLeadForm, 'preferring a form you can reply to' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def form(name, fields)
    company.intake_forms.create!(name: name, is_active: true, schema: fields)
  end

  def field(attrs)
    { 'id' => SecureRandom.uuid, 'isActive' => true }.merge(attrs)
  end

  before { company.intake_forms.destroy_all }

  describe '.reachable?' do
    it 'accepts a form mapping a field to email' do
      f = form('A', [field('name' => 'Email', 'type' => 'email', 'leadField' => 'email')])
      expect(described_class.reachable?(f)).to be true
    end

    it 'accepts a phone field typed tel' do
      f = form('A', [field('name' => 'Mobile', 'type' => 'tel')])
      expect(described_class.reachable?(f)).to be true
    end

    it 'accepts a field only its wording identifies' do
      f = form('A', [field('name' => 'Best phone to reach you', 'type' => 'text')])
      expect(described_class.reachable?(f)).to be true
    end

    it 'rejects a form asking only for a name and a budget' do
      f = form('Contact Us', [
        field('name' => 'First Name', 'type' => 'text'),
        field('name' => 'Budget', 'type' => 'number')
      ])
      expect(described_class.reachable?(f)).to be false
    end

    it 'ignores a contact field that is switched off' do
      f = form('A', [field('name' => 'Email', 'type' => 'email', 'isActive' => false)])
      expect(described_class.reachable?(f)).to be false
    end
  end

  describe '.for' do
    it 'prefers a campaign form that collects a phone over a pretty one that collects nothing' do
      form('Contact Us', [field('name' => 'First Name', 'type' => 'text')])
      usable = form('Facebook Promo', [field('name' => 'Phone', 'type' => 'tel')])

      expect(described_class.for(company)).to eq(usable)
    end

    it 'still prefers a general name among forms that are all reachable' do
      form('Facebook Promo', [field('name' => 'Phone', 'type' => 'tel')])
      general = form('Contact Us', [field('name' => 'Email', 'type' => 'email')])

      expect(described_class.for(company)).to eq(general)
    end

    # Something beats nothing: a form that cannot collect a contact still shows
    # a dealer's brand and still beats an empty box.
    it 'falls back to an unreachable form when there is no alternative' do
      only = form('Contact Us', [field('name' => 'First Name', 'type' => 'text')])

      expect(described_class.for(company)).to eq(only)
    end
  end

  describe '.ensure_for' do
    it 'builds a proper form when the only one collects no contact' do
      form('Contact Us', [field('name' => 'First Name', 'type' => 'text')])

      created = described_class.ensure_for(company)

      expect(described_class.reachable?(created)).to be true
      expect(created.schema.map { |f| f['leadField'] }).to include('email', 'phone')
    end

    it 'leaves a company alone when its form is already reachable' do
      good = form('Contact Us', [field('name' => 'Email', 'type' => 'email')])

      expect(described_class.ensure_for(company)).to eq(good)
    end
  end
end
