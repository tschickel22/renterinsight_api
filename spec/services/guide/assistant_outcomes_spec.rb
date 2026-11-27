# frozen_string_literal: true

require 'rails_helper'

# Every help reply has an outcome (E118). Only no_help is a gap in the help;
# looks_wrong and needs_support show fixed text and go to support; "we don't
# offer that" only on the maintained list's word.
RSpec.describe Guide::Assistant do
  let(:company) { create(:company) }

  # Plays Claude: optionally calls one tool, then replies with the given input.
  def client_for(reply, tool: nil)
    Class.new do
      define_method(:initialize) { @n = 0 }
      define_method(:call) do |**|
        @n += 1
        if tool && @n == 1
          { 'content' => [{ 'type' => 'tool_use', 'id' => 't1', 'name' => tool[0], 'input' => tool[1] }],
            'usage' => { 'input_tokens' => 100, 'output_tokens' => 10 } }
        else
          { 'content' => [{ 'type' => 'tool_use', 'id' => 't2', 'name' => 'reply', 'input' => reply }],
            'usage' => { 'input_tokens' => 100, 'output_tokens' => 10, 'cache_read_input_tokens' => 1000 } }
        end
      end
    end.new
  end

  def ask(reply, tool: nil)
    described_class.new(user: nil, company: company, client: client_for(reply, tool: tool), data_assistant: true).ask('q')
  end

  it 'shows fixed text when something looks wrong, never the model\'s words' do
    result = ask({ 'answer_markdown' => 'That is a bug, we will fix it by Friday.', 'outcome' => 'looks_wrong',
                   'assistant_reason' => 'Tax missing on save' })
    expect(result.outcome).to eq('looks_wrong')
    expect(result.answer).to eq(described_class::FIXED_ANSWERS['looks_wrong'])
    expect(result.assistant_reason).to eq('Tax missing on save')
    expect(result.answered).to be(false)
  end

  it 'shows fixed text for a change request' do
    result = ask({ 'answer_markdown' => 'Done!', 'outcome' => 'needs_support' })
    expect(result.answer).to eq(described_class::FIXED_ANSWERS['needs_support'])
  end

  it 'will not say "we don\'t offer that" without the list saying so, in the outcome or the words' do
    result = ask({ 'answer_markdown' => 'We do not offer invoices.', 'outcome' => 'not_offered' })
    expect(result.outcome).to eq('no_help')
    expect(result.answer).to eq(described_class::UNCONFIRMED)
  end

  it 'catches the claim under another outcome too (how do I delete a deal, staging 2026-11-24)' do
    brand = Brand.current(company: company).name
    result = ask({ 'answer_markdown' => "#{brand} does not offer a way to permanently delete a deal.", 'outcome' => 'no_help' })
    expect(result.answer).to eq(described_class::UNCONFIRMED)
  end

  it 'leaves a fact about a record alone' do
    result = ask({ 'answer_markdown' => "It doesn't have a selling price yet, so approving it would post no sale.", 'outcome' => 'answered' })
    expect(result.answer).to include('selling price')
    expect(result.outcome).to eq('answered')
  end

  it 'says a feature is not offered when the list says so' do
    result = ask({ 'answer_markdown' => "DealerTide doesn't have a lot map.", 'outcome' => 'not_offered' },
                 tool: ['product_facts', { 'topic' => 'lot map' }])
    expect(result.outcome).to eq('not_offered')
    expect(result.trace.map { |t| t['tool'] }).to eq(['product_facts'])
  end

  it 'counts cached input at a tenth' do
    result = ask({ 'answer_markdown' => 'Open Settings.', 'outcome' => 'answered' })
    expect(result.input_tokens).to eq(100 + 100)
    expect(result.cache_read_tokens).to eq(1000)
  end

  it 'still reads the older answered flag' do
    expect(ask({ 'answer_markdown' => 'x', 'answered' => false }).outcome).to eq('no_help')
    expect(ask({ 'answer_markdown' => 'x', 'answered' => true }).outcome).to eq('answered')
  end
end

RSpec.describe Guide::ProductFacts do
  it 'knows what is not offered' do
    match = described_class.call('do you have a lot map')[:matches].first
    expect(match[:offered]).to be(false)
  end

  it 'knows what is offered' do
    matches = described_class.call('can we add followers to a deal')[:matches]
    expect(matches.first[:offered]).to be(true)
  end

  it 'knows deals can be deleted' do
    expect(described_class.call('how do I delete a deal')[:matches].first).to include(offered: true)
  end

  it 'admits when it has nothing on record' do
    expect(described_class.call('zzzz qqqq')[:found]).to be(false)
  end
end

RSpec.describe Guide::ProductFacts, 'sold but not built' do
  it "says Text Us replies are not offered, not the module's planned description" do
    matches = described_class.call('do texts from the website text us widget get routed to a rep')[:matches]
    text_us = matches.select { |m| m[:module] == 'marketing.text_us' }
    expect(text_us).not_to be_empty
    expect(text_us).to all(include(offered: false))
  end
end
