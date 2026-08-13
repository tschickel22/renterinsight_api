# frozen_string_literal: true

require 'rails_helper'

# Who hears about a deduped inbound inquiry. The record's owner and the key's
# assigned_user_id were already handled; an ownerless record on a round-robin
# key notified nobody, so the note was written and no human was told.
RSpec.describe 'Api::Partner::V1 Leads repeat-inquiry recipient', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }

  def make_user(status: 'active')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: status)
  end

  let(:creator) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def make_key(webhook_config)
    ApiKey.new(company_id: company.id, name: 'Facebook Leads',
               key: "ri_live_#{SecureRandom.hex(24)}",
               permissions: { 'leads' => %w[read create] }, status: 'active',
               created_by_user_id: creator.id,
               webhook_config: { default_location_id: location.id, dedupe_enabled: true }.merge(webhook_config))
          .tap { |k| k.save!(validate: false) }
  end

  def post_inquiry(key, payload)
    post '/api/partner/v1/leads',
         params: payload.to_json,
         headers: { 'Authorization' => "Bearer #{key.key}", 'Content-Type' => 'application/json' }
  end

  # Ownerless on purpose — this is the record that used to notify nobody.
  let!(:ownerless_contact) do
    Contact.create!(company_id: company.id, first_name: 'Bob', last_name: 'Smith',
                    email: 'shared@example.com')
  end

  def assignee_of_contact_reminder
    ContactActivity.find_by(contact_id: ownerless_contact.id, activity_type: 'reminder')&.assigned_to_id
  end

  describe 'round-robin key' do
    let(:rep_one) { make_user }
    let(:rep_two) { make_user }
    let(:key) { make_key(assignment_mode: 'round_robin', assigned_user_ids: [rep_one.id, rep_two.id]) }

    it 'notifies the next person on the list' do
      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')

      expect(response).to have_http_status(:accepted)
      expect(assignee_of_contact_reminder).to eq(rep_one.id)
    end

    it 'advances the rotation, so the next inquiry goes to the next rep' do
      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')
      ContactActivity.where(contact_id: ownerless_contact.id).delete_all
      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')

      expect(assignee_of_contact_reminder).to eq(rep_two.id)
    end

    it 'skips an inactive rep' do
      inactive = make_user(status: 'inactive')
      key = make_key(assignment_mode: 'round_robin', assigned_user_ids: [inactive.id, rep_two.id])

      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')
      expect(assignee_of_contact_reminder).to eq(rep_two.id)
    end
  end

  describe 'a key with no assignment at all' do
    let(:key) { make_key(assignment_mode: 'unassigned') }
    let(:form_watcher) { make_user }

    it 'falls back to the lead intake form\'s notified user' do
      IntakeForm.create!(company_id: company.id, name: 'Website Inquiry', is_active: true,
                         notified_user_id: form_watcher.id)

      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')
      expect(assignee_of_contact_reminder).to eq(form_watcher.id)
    end

    it 'prefers the form bound to this inquiry\'s location' do
      other_location = Location.create!(company_id: company.id, name: 'Boulder', code: 'BLD', active: true)
      wrong_watcher = make_user
      IntakeForm.create!(company_id: company.id, name: 'Boulder Form', is_active: true,
                         location_id: other_location.id, notified_user_id: wrong_watcher.id)
      IntakeForm.create!(company_id: company.id, name: 'Denver Form', is_active: true,
                         location_id: location.id, notified_user_id: form_watcher.id)

      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')
      expect(assignee_of_contact_reminder).to eq(form_watcher.id)
    end

    it 'ignores inactive forms' do
      IntakeForm.create!(company_id: company.id, name: 'Retired Form', is_active: false,
                         notified_user_id: form_watcher.id)

      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')
      expect(assignee_of_contact_reminder).to be_nil
    end
  end

  describe 'precedence' do
    let(:designated) { make_user }
    let(:form_watcher) { make_user }
    let(:key) { make_key(assignment_mode: 'specific', assigned_user_id: designated.id) }

    it 'keeps the key\'s assigned user ahead of the intake form' do
      IntakeForm.create!(company_id: company.id, name: 'Website Inquiry', is_active: true,
                         notified_user_id: form_watcher.id)

      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')
      expect(assignee_of_contact_reminder).to eq(designated.id)
    end

    it 'keeps the record owner ahead of everything' do
      owner = make_user
      ownerless_contact.update!(owner_id: owner.id)
      IntakeForm.create!(company_id: company.id, name: 'Website Inquiry', is_active: true,
                         notified_user_id: form_watcher.id)

      post_inquiry(key, full_name: 'Tia May', email: 'shared@example.com')
      expect(assignee_of_contact_reminder).to eq(owner.id)
    end
  end
end
