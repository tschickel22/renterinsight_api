# frozen_string_literal: true

require 'rails_helper'

# The text a rep gets when a customer answers. It comes from our number, so
# replying to it goes nowhere near the customer, and a rep did exactly that.
RSpec.describe 'The reply a rep is forwarded', type: :request do
  let(:company) { Company.create!(name: "Fwd #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:lead) { Lead.create!(company: company, first_name: 'Rosa', last_name: 'Delgado', phone: '3035550142') }
  let(:sent) { [] }

  before { allow(TwilioSmsService).to receive(:send_via_master) { |**args| sent << args } }

  def forward(body, communicable: lead, token: 'tok123')
    Webhooks::TwilioController.new.send(:forward_sms_to_sender, to_cell: '+13035550100', from_number: '+13035550142',
                                                                 body: body, communicable: communicable, reply_token: token)
    sent.last[:body]
  end

  it 'names the customer and says only the link reaches them' do
    text = forward('Are you open Saturday?')

    expect(text).to start_with(%(Rosa Delgado texted you:\n"Are you open Saturday?"))
    expect(text).to include('Tap the link to answer. Replying to this text will not reach them.')
    expect(text).to end_with('/reply/tok123')
    expect(text).not_to include('Lead #')
  end

  it 'keeps the link when the customer wrote a lot' do
    text = forward('x' * 900)

    expect(text.length).to be <= 320
    expect(text).to end_with('/reply/tok123')
  end

  it 'falls back to the number when nothing names them' do
    expect(forward('Hello', communicable: nil)).to start_with('+13035550142 texted you:')
  end
end
