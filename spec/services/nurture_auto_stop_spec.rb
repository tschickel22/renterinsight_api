# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NurtureAutoStop, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:lead) { Lead.create!(company_id: company.id, first_name: 'A', last_name: 'A', email: "a-#{SecureRandom.hex(3)}@example.com") }

  def sequence(**flags)
    NurtureSequence.create!(company_id: company.id, name: "Seq #{SecureRandom.hex(3)}", **flags)
  end

  def enroll(seq)
    NurtureEnrollment.create!(enrollable: lead, nurture_sequence: seq, company: company, status: 'running')
  end

  describe '.for_reply' do
    it 'pauses sequences that stop on reply' do
      enrollment = enroll(sequence(stop_on_reply: true))

      described_class.for_reply(Communication.new(direction: 'inbound', communicable: lead))

      expect(enrollment.reload.status).to eq('paused')
    end

    it 'leaves sequences that did not opt in running' do
      enrollment = enroll(sequence)

      described_class.for_reply(Communication.new(direction: 'inbound', communicable: lead))

      expect(enrollment.reload.status).to eq('running')
    end

    it 'ignores outbound messages' do
      enrollment = enroll(sequence(stop_on_reply: true))

      described_class.for_reply(Communication.new(direction: 'outbound', communicable: lead))

      expect(enrollment.reload.status).to eq('running')
    end
  end

  describe 'on lead conversion' do
    it 'pauses sequences that stop on conversion' do
      enrollment = enroll(sequence(stop_on_conversion: true))

      lead.update!(is_converted: true, converted_at: Time.current)

      expect(enrollment.reload.status).to eq('paused')
    end

    it 'leaves sequences that did not opt in running' do
      enrollment = enroll(sequence(stop_on_reply: true))

      lead.update!(is_converted: true, converted_at: Time.current)

      expect(enrollment.reload.status).to eq('running')
    end
  end
end
