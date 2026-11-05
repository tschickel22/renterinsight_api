# frozen_string_literal: true

require 'rails_helper'

# A new company starts with its own copy of the standard invitation templates.
RSpec.describe 'New company invitation templates' do
  def standard(channel, subject)
    CommunicationTemplate.create!(company_id: nil, name: "Standard #{channel}", template_type: 'company_user_invitation', channel: channel,
                                  subject: subject, body: "Body #{channel}", is_active: true, is_default: true)
  end

  it 'copies the standard email and text, and leaves the standard ones alone' do
    email = standard('email', 'Join us')
    text = standard('sms', nil)
    company = Company.create!(name: "New #{SecureRandom.hex(3)}")

    own = CommunicationTemplate.where(company_id: company.id, template_type: 'company_user_invitation').index_by(&:channel)
    expect(own.keys).to match_array(%w[email sms])
    expect(own['email']).to have_attributes(name: 'Invitation Email', subject: 'Join us', body: 'Body email', is_active: true, is_default: false)
    expect(own['sms']).to have_attributes(name: 'Invitation Text', body: 'Body sms', is_active: true, is_default: false)
    expect(email.reload.company_id).to be_nil
    expect(text.reload.company_id).to be_nil
  end

  it 'gives each company its own copy' do
    standard('email', 'Join us')
    first = Company.create!(name: "A #{SecureRandom.hex(3)}")
    second = Company.create!(name: "B #{SecureRandom.hex(3)}")
    CommunicationTemplate.find_by!(company_id: first.id, channel: 'email').update!(subject: 'Changed by first')

    expect(CommunicationTemplate.find_by!(company_id: second.id, channel: 'email').subject).to eq('Join us')
  end

  it 'still creates the company when no standard exists' do
    CommunicationTemplate.where(company_id: nil, template_type: 'company_user_invitation').delete_all
    company = Company.create!(name: "None #{SecureRandom.hex(3)}")
    expect(company).to be_persisted
    expect(CommunicationTemplate.where(company_id: company.id, template_type: 'company_user_invitation')).to be_empty
  end
end
