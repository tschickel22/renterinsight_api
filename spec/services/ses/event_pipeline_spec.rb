# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ses::EventPipeline do
  let(:ses) { instance_double(Aws::SESV2::Client) }
  let(:sns) { instance_double(Aws::SNS::Client) }

  let(:topic_arn) { 'arn:aws:sns:us-east-1:123456789012:platform-ses-events' }
  let(:webhook_url) { 'https://api.example.com/webhooks/ses/events' }

  def stub_env(vars)
    vars.each { |k, v| allow(ENV).to receive(:[]).with(k).and_return(v) }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    stub_env(
      'RAILS_API_URL' => 'https://api.example.com',
      'API_BASE_URL' => nil,
      'SES_EVENT_WEBHOOK_URL' => nil,
      'SES_CONFIGURATION_SET' => nil,
      'AWS_SES_CONFIGURATION_SET' => nil,
      'SES_EVENT_TOPIC_NAME' => nil
    )
  end

  describe '.webhook_url' do
    it 'builds the endpoint from RAILS_API_URL' do
      expect(described_class.webhook_url).to eq(webhook_url)
    end

    it 'does not double the slash when RAILS_API_URL has a trailing one' do
      stub_env('RAILS_API_URL' => 'https://api.example.com/')

      expect(described_class.webhook_url).to eq(webhook_url)
    end

    # DMS_API_URL is the customer-facing host and is fronted by Cloudflare, so it is never
    # used for a machine-to-machine callback even though it also addresses the API.
    it 'ignores DMS_API_URL' do
      stub_env('RAILS_API_URL' => nil, 'API_BASE_URL' => nil, 'DMS_API_URL' => 'https://api.dealertide.com')

      expect { described_class.webhook_url }.to raise_error(described_class::SesError, /RAILS_API_URL/)
    end

    it 'prefers an explicit override' do
      stub_env('SES_EVENT_WEBHOOK_URL' => 'https://tunnel.example.org/webhooks/ses/events')

      expect(described_class.webhook_url).to eq('https://tunnel.example.org/webhooks/ses/events')
    end

    # Bounce notifications name customer email addresses and the handler suppresses on
    # them, so plaintext delivery is refused rather than warned about.
    it 'refuses a plaintext endpoint' do
      stub_env('RAILS_API_URL' => 'http://api.example.com')

      expect { described_class.webhook_url }.to raise_error(described_class::SesError, /https/)
    end

    it 'refuses to guess when no base URL is configured' do
      stub_env('RAILS_API_URL' => nil)

      expect { described_class.webhook_url }.to raise_error(described_class::SesError, /RAILS_API_URL/)
    end
  end

  describe '#provision!' do
    before do
      allow(ses).to receive(:create_configuration_set)
      allow(ses).to receive(:create_configuration_set_event_destination)
      allow(sns).to receive(:create_topic).and_return(double(topic_arn: topic_arn))
      allow(sns).to receive(:get_topic_attributes).and_return(double(attributes: {}))
      allow(sns).to receive(:set_topic_attributes)
      allow(sns).to receive(:list_subscriptions_by_topic)
        .and_return(double(subscriptions: [], next_token: nil))
      allow(sns).to receive(:subscribe)
        .and_return(double(subscription_arn: "#{topic_arn}:8f3a"))
    end

    subject(:pipeline) { described_class.new(ses: ses, sns: sns) }

    it 'creates the configuration set outbound mail is already tagged with' do
      pipeline.provision!

      expect(ses).to have_received(:create_configuration_set)
        .with(configuration_set_name: 'platform-email-events')
    end

    it 'points the event destination at the topic for the events the processor handles' do
      pipeline.provision!

      expect(ses).to have_received(:create_configuration_set_event_destination).with(
        configuration_set_name: 'platform-email-events',
        event_destination_name: 'platform-webhook',
        event_destination: {
          enabled: true,
          matching_event_types: %w[BOUNCE COMPLAINT DELIVERY],
          sns_destination: { topic_arn: topic_arn }
        }
      )
    end

    # Without the topic policy SES accepts the destination and then silently drops every
    # notification, which is indistinguishable from "no bounces are happening".
    it 'grants ses.amazonaws.com publish rights, scoped to our own account' do
      pipeline.provision!

      expect(sns).to have_received(:set_topic_attributes) do |args|
        statement = JSON.parse(args[:attribute_value])['Statement'].first
        expect(statement['Principal']).to eq('Service' => 'ses.amazonaws.com')
        expect(statement['Action']).to eq('sns:Publish')
        expect(statement.dig('Condition', 'StringEquals', 'AWS:SourceAccount')).to eq('123456789012')
      end
    end

    it 'keeps the statements SNS wrote for the topic owner' do
      owner = { 'Sid' => 'owner', 'Effect' => 'Allow', 'Principal' => { 'AWS' => '123456789012' } }
      allow(sns).to receive(:get_topic_attributes)
        .and_return(double(attributes: { 'Policy' => { 'Statement' => [owner] }.to_json }))

      pipeline.provision!

      expect(sns).to have_received(:set_topic_attributes) do |args|
        sids = JSON.parse(args[:attribute_value])['Statement'].map { |s| s['Sid'] }
        expect(sids).to eq(%w[owner AllowSESEventPublish])
      end
    end

    it 'leaves an already-granted policy alone' do
      granted = { 'Sid' => 'AllowSESEventPublish' }
      allow(sns).to receive(:get_topic_attributes)
        .and_return(double(attributes: { 'Policy' => { 'Statement' => [granted] }.to_json }))

      report = pipeline.provision!

      expect(report[:topic_policy_updated]).to be false
      expect(sns).not_to have_received(:set_topic_attributes)
    end

    it 'subscribes the webhook' do
      report = pipeline.provision!

      expect(sns).to have_received(:subscribe).with(
        topic_arn: topic_arn, protocol: 'https', endpoint: webhook_url, return_subscription_arn: true
      )
      expect(report[:subscription][:confirmed]).to be true
    end

    it 'does not resubscribe an endpoint that is already confirmed' do
      allow(sns).to receive(:list_subscriptions_by_topic).and_return(
        double(subscriptions: [double(endpoint: webhook_url, subscription_arn: "#{topic_arn}:8f3a")], next_token: nil)
      )

      report = pipeline.provision!

      expect(sns).not_to have_received(:subscribe)
      expect(report[:subscription][:action]).to eq(:existing)
    end

    # SNS delivers the confirmation once. A subscription stranded in PendingConfirmation
    # because the webhook was down at that moment never recovers on its own.
    it 'resubscribes a stranded pending subscription' do
      allow(sns).to receive(:list_subscriptions_by_topic).and_return(
        double(subscriptions: [double(endpoint: webhook_url, subscription_arn: 'PendingConfirmation')], next_token: nil)
      )

      pipeline.provision!

      expect(sns).to have_received(:subscribe)
    end

    it 'is safe to re-run when everything already exists' do
      allow(ses).to receive(:create_configuration_set)
        .and_raise(Aws::SESV2::Errors::AlreadyExistsException.new(nil, 'exists'))
      allow(ses).to receive(:create_configuration_set_event_destination)
        .and_raise(Aws::SESV2::Errors::AlreadyExistsException.new(nil, 'exists'))
      allow(ses).to receive(:update_configuration_set_event_destination)

      report = pipeline.provision!

      expect(report[:configuration_set_created]).to be false
      expect(report[:event_destination][:action]).to eq(:updated)
    end

    # An existing destination is not necessarily a correct one: it may point at a topic that
    # was deleted, or predate an event type we now depend on.
    it 'repairs an existing destination rather than trusting it' do
      allow(ses).to receive(:create_configuration_set_event_destination)
        .and_raise(Aws::SESV2::Errors::AlreadyExistsException.new(nil, 'exists'))
      allow(ses).to receive(:update_configuration_set_event_destination)

      pipeline.provision!

      expect(ses).to have_received(:update_configuration_set_event_destination).with(
        hash_including(event_destination: hash_including(sns_destination: { topic_arn: topic_arn }))
      )
    end
  end

  describe '#status' do
    subject(:pipeline) { described_class.new(ses: ses, sns: sns) }

    it 'reports a fully wired pipeline' do
      allow(ses).to receive(:get_configuration_set)
      allow(ses).to receive(:get_configuration_set_event_destinations).and_return(
        double(event_destinations: [
                 double(name: 'platform-webhook', enabled: true,
                        matching_event_types: %w[BOUNCE COMPLAINT DELIVERY],
                        sns_destination: double(topic_arn: topic_arn))
               ])
      )
      allow(sns).to receive(:list_subscriptions_by_topic).and_return(
        double(subscriptions: [double(endpoint: webhook_url, subscription_arn: "#{topic_arn}:8f3a")], next_token: nil)
      )

      status = pipeline.status

      expect(status[:configuration_set_exists]).to be true
      expect(status[:event_destination][:enabled]).to be true
      expect(status[:subscription][:confirmed]).to be true
    end

    # A denied read is not an absent resource. Reporting it as MISSING sends you off to
    # create a configuration set that already exists and is working.
    it 'distinguishes a permission failure from a missing configuration set' do
      denied = Aws::SESV2::Errors::AccessDeniedException.new(nil, 'not authorized')
      allow(ses).to receive(:get_configuration_set).and_raise(denied)
      allow(ses).to receive(:get_configuration_set_event_destinations).and_raise(denied)
      allow(sns).to receive(:list_topics).and_return(double(topics: [], next_token: nil))

      status = pipeline.status

      expect(status[:configuration_set_exists]).to eq(:unknown)
      expect(status[:errors]).to include(/not authorized/)
    end

    it 'reports a missing configuration set without raising' do
      allow(ses).to receive(:get_configuration_set)
        .and_raise(Aws::SESV2::Errors::NotFoundException.new(nil, 'nope'))
      allow(ses).to receive(:get_configuration_set_event_destinations)
        .and_raise(Aws::SESV2::Errors::NotFoundException.new(nil, 'nope'))
      allow(sns).to receive(:list_topics).and_return(double(topics: [], next_token: nil))

      status = pipeline.status

      expect(status[:configuration_set_exists]).to be false
      expect(status[:event_destination]).to be_nil
      expect(status[:subscription]).to be_nil
    end
  end

  describe Ses::ConfigurationSet do
    it 'reads SES_CONFIGURATION_SET first' do
      stub_env('SES_CONFIGURATION_SET' => 'from-code-var', 'AWS_SES_CONFIGURATION_SET' => 'from-doc-var')

      expect(described_class.current).to eq('from-code-var')
    end

    # The docs and .env.example have always used AWS_SES_CONFIGURATION_SET while the code
    # read SES_CONFIGURATION_SET, so anyone who followed the documentation configured a
    # variable nothing consumed.
    it 'accepts the variable name the docs use' do
      stub_env('AWS_SES_CONFIGURATION_SET' => 'from-doc-var')

      expect(described_class.current).to eq('from-doc-var')
    end

    it 'falls back to a default so the pipeline is provisionable with no config' do
      expect(described_class.current).to eq('platform-email-events')
    end
  end
end
