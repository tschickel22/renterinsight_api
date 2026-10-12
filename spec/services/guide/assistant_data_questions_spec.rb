# frozen_string_literal: true

require 'rails_helper'

# Questions about a dealership's own numbers are not help: the help assistant
# sends them to the AI Assistant when the company has it, otherwise to the
# report or list that shows them.
RSpec.describe Guide::Assistant do
  let(:company) { create(:company) }
  let(:client) do
    Class.new do
      attr_reader :system

      def call(system:, **)
        @system = system
        { 'content' => [{ 'type' => 'tool_use', 'name' => 'reply', 'id' => 't1',
                          'input' => { 'answer_markdown' => 'x', 'answered' => true } }], 'usage' => {} }
      end
    end.new
  end

  it 'points to the AI Assistant when the company has it' do
    described_class.new(user: nil, company: company, client: client, data_assistant: true).ask('how many leads this week')
    expect(client.system).to include('sparkle icon')
  end

  it 'points to the report or list otherwise' do
    described_class.new(user: nil, company: company, client: client, data_assistant: false).ask('how many leads this week')
    expect(client.system).to include('report or list')
    expect(client.system).not_to include('sparkle')
  end
end
