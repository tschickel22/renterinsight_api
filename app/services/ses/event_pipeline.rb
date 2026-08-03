# frozen_string_literal: true

require 'aws-sdk-sesv2'
require 'aws-sdk-sns'

module Ses
  # Provisions the AWS side of the bounce / complaint / delivery pipeline.
  #
  # The receiving half already existed: Webhooks::SesEventsController verifies the SNS
  # signature and Ses::EventProcessor applies the event. What was never built is the half
  # that makes AWS send anything at all, so both sat there waiting for traffic that could
  # not arrive.
  #
  # Four pieces have to line up, and missing any one of them fails silently rather than
  # loudly. That is the reason this is a service with a status report rather than a page of
  # console instructions:
  #
  #   1. a configuration set, named by Ses::ConfigurationSet, which outbound mail tags
  #   2. an SNS topic
  #   3. a topic policy letting ses.amazonaws.com publish to it
  #   4. an event destination on the set pointing at the topic
  #   5. an https subscription from the topic to our webhook
  #
  # Every step is idempotent, so this can be re-run after a partial failure or against an
  # account where someone already created some of it by hand.
  #
  # Scope note: this covers the platform account's sending, which includes tenant domains
  # verified through Ses::IdentityManager. Configuration sets are account-level and applied
  # per message, so a tenant's own verified domain gets the same events without any
  # per-tenant setup.
  class EventPipeline
    class SesError < StandardError; end

    # Only the events Ses::EventProcessor actually consumes. Subscribing to more would put
    # traffic on the webhook that it can do nothing with, and an SNS topic is billed and
    # rate-limited per message.
    EVENT_TYPES = %w[BOUNCE COMPLAINT DELIVERY].freeze

    DEFAULT_TOPIC_NAME = 'platform-ses-events'
    DESTINATION_NAME = 'platform-webhook'
    WEBHOOK_PATH = '/webhooks/ses/events'
    SES_PUBLISH_SID = 'AllowSESEventPublish'

    def self.provision!(ses: nil, sns: nil)
      new(ses: ses, sns: sns).provision!
    end

    def self.status(ses: nil, sns: nil)
      new(ses: ses, sns: sns).status
    end

    def self.topic_name
      ENV['SES_EVENT_TOPIC_NAME'].presence || DEFAULT_TOPIC_NAME
    end

    # Where SNS should deliver events. SES_EVENT_WEBHOOK_URL wins so setup can be run from
    # one machine against another environment's host; otherwise it is built from
    # RAILS_API_URL, which is this API's own origin and what the other server-to-server
    # callbacks already use.
    #
    # Deliberately not DMS_API_URL. That is the customer-facing host (api.dealertide.com)
    # which fronts the API through Cloudflare, and a bot rule there would silently drop SNS
    # posts. Deliberately not APP_URL or FRONTEND_URL either: those address the React app,
    # which cannot receive an SNS POST at all.
    def self.webhook_url
      explicit = ENV['SES_EVENT_WEBHOOK_URL'].presence
      return validate_webhook_url!(explicit) if explicit

      base = ENV['RAILS_API_URL'].presence || ENV['API_BASE_URL'].presence
      if base.blank?
        raise SesError, 'Set RAILS_API_URL (or SES_EVENT_WEBHOOK_URL) so SNS knows where to deliver events'
      end

      validate_webhook_url!(URI.join("#{base.chomp('/')}/", WEBHOOK_PATH.sub(%r{\A/}, '')).to_s)
    end

    def self.validate_webhook_url!(url)
      uri = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end

      # SNS will happily subscribe an http endpoint, and then every bounce notification
      # crosses the internet in the clear to a handler that suppresses customer addresses.
      unless uri.is_a?(URI::HTTPS)
        raise SesError, "SES event webhook must be an https URL, got #{url.inspect}"
      end

      uri.to_s
    end

    def initialize(ses: nil, sns: nil)
      @ses = ses
      @sns = sns
    end

    def provision!
      report = { configuration_set: configuration_set_name, webhook_url: self.class.webhook_url }

      report[:configuration_set_created] = ensure_configuration_set!
      topic_arn = ensure_topic!
      report[:topic_arn] = topic_arn
      report[:topic_policy_updated] = ensure_topic_policy!(topic_arn)
      report[:event_destination] = ensure_event_destination!(topic_arn)
      report[:subscription] = ensure_subscription!(topic_arn, report[:webhook_url])
      report
    end

    # Read-only counterpart, so "is this actually wired up?" can be answered without
    # mutating anything. Never raises for a missing piece: absence is the answer.
    #
    # Absence and "we were not allowed to look" are reported as different things. Collapsing
    # them is worse than useless here: an AccessDenied read as "MISSING" tells you to create
    # a configuration set that already exists and is working.
    def status
      @errors = []
      set_exists = configuration_set_exists?
      destination = find_event_destination
      topic_arn = destination&.dig(:topic_arn) || find_topic_arn
      url = begin
        self.class.webhook_url
      rescue SesError => e
        e.message
      end

      {
        region: Ses::Region.current,
        configuration_set: configuration_set_name,
        configuration_set_exists: set_exists,
        event_destination: destination,
        topic_arn: topic_arn,
        subscription: topic_arn ? find_subscription(topic_arn, url) : nil,
        webhook_url: url,
        errors: @errors
      }
    end

    private

    def record_error(message)
      (@errors ||= []) << message
      Rails.logger.warn("[Ses::EventPipeline] #{message}")
      nil
    end

    def configuration_set_name
      Ses::ConfigurationSet.current
    end

    def ses
      @ses ||= Aws::SESV2::Client.new(
        access_key_id: ENV['AWS_ACCESS_KEY_ID'],
        secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
        region: Ses::Region.current
      )
    end

    def sns
      @sns ||= Aws::SNS::Client.new(
        access_key_id: ENV['AWS_ACCESS_KEY_ID'],
        secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
        region: Ses::Region.current
      )
    end

    def ensure_configuration_set!
      ses.create_configuration_set(configuration_set_name: configuration_set_name)
      true
    rescue Aws::SESV2::Errors::AlreadyExistsException
      false
    rescue Aws::SESV2::Errors::ServiceError => e
      raise SesError, "Could not create configuration set #{configuration_set_name}: #{e.message}"
    end

    def configuration_set_exists?
      ses.get_configuration_set(configuration_set_name: configuration_set_name)
      true
    rescue Aws::SESV2::Errors::NotFoundException
      false
    rescue Aws::SESV2::Errors::ServiceError => e
      record_error("could not read configuration set #{configuration_set_name}: #{e.message}")
      :unknown
    end

    # create_topic returns the existing ARN when the topic is already there, so this needs
    # no exists-check of its own.
    def ensure_topic!
      sns.create_topic(name: self.class.topic_name).topic_arn
    rescue Aws::SNS::Errors::ServiceError => e
      raise SesError, "Could not create SNS topic #{self.class.topic_name}: #{e.message}"
    end

    def find_topic_arn
      suffix = ":#{self.class.topic_name}"
      token = nil
      loop do
        page = sns.list_topics(next_token: token)
        match = page.topics.find { |t| t.topic_arn.end_with?(suffix) }
        return match.topic_arn if match

        token = page.next_token
        break if token.blank?
      end
      nil
    rescue Aws::SNS::Errors::ServiceError => e
      record_error("could not list SNS topics: #{e.message}")
    end

    # Grants ses.amazonaws.com sns:Publish on the topic. Without this SES accepts the event
    # destination and then drops every notification, which looks identical to "no events are
    # happening" from our side.
    #
    # The existing policy is read and appended to rather than replaced: SNS writes a default
    # statement granting the account owner access, and overwriting it would leave the topic
    # unmanageable by the credentials that created it.
    def ensure_topic_policy!(topic_arn)
      account_id = account_id_from(topic_arn)
      policy = current_topic_policy(topic_arn) || default_policy_shell
      statements = Array(policy['Statement'])

      return false if statements.any? { |s| s['Sid'] == SES_PUBLISH_SID }

      statements << {
        'Sid' => SES_PUBLISH_SID,
        'Effect' => 'Allow',
        'Principal' => { 'Service' => 'ses.amazonaws.com' },
        'Action' => 'sns:Publish',
        'Resource' => topic_arn,
        # Scopes the grant to our own account's SES. Without the condition any AWS account's
        # SES could publish to this topic, and the webhook treats a topic message as
        # authoritative enough to suppress an address.
        'Condition' => { 'StringEquals' => { 'AWS:SourceAccount' => account_id } }
      }
      policy['Statement'] = statements

      sns.set_topic_attributes(
        topic_arn: topic_arn,
        attribute_name: 'Policy',
        attribute_value: policy.to_json
      )
      true
    rescue Aws::SNS::Errors::ServiceError => e
      raise SesError, "Could not set topic policy on #{topic_arn}: #{e.message}"
    end

    def current_topic_policy(topic_arn)
      raw = sns.get_topic_attributes(topic_arn: topic_arn).attributes['Policy']
      raw.present? ? JSON.parse(raw) : nil
    rescue JSON::ParserError, Aws::SNS::Errors::ServiceError => e
      # Raise rather than fall back to an empty policy. Writing one built from nothing would
      # drop the owner statement SNS created, leaving the topic unmanageable by the
      # credentials that own it. A policy we cannot read is a policy we must not replace.
      raise SesError, "Could not read the existing policy on #{topic_arn}, refusing to overwrite it: #{e.message}"
    end

    def default_policy_shell
      { 'Version' => '2012-10-17', 'Id' => 'ses-event-topic-policy', 'Statement' => [] }
    end

    # arn:aws:sns:<region>:<account-id>:<name>. Read from the ARN rather than called for via
    # STS so this needs no extra IAM permission beyond the SNS and SES ones it already uses.
    def account_id_from(topic_arn)
      id = topic_arn.to_s.split(':')[4]
      raise SesError, "Could not read account id from topic ARN #{topic_arn.inspect}" if id.blank?

      id
    end

    def ensure_event_destination!(topic_arn)
      destination = {
        enabled: true,
        matching_event_types: EVENT_TYPES,
        sns_destination: { topic_arn: topic_arn }
      }

      begin
        ses.create_configuration_set_event_destination(
          configuration_set_name: configuration_set_name,
          event_destination_name: DESTINATION_NAME,
          event_destination: destination
        )
        { name: DESTINATION_NAME, action: :created, event_types: EVENT_TYPES, topic_arn: topic_arn }
      rescue Aws::SESV2::Errors::AlreadyExistsException
        # Update rather than leave it: an existing destination may point at a stale topic or
        # be missing an event type, and "already exists" is not the same as "is correct".
        ses.update_configuration_set_event_destination(
          configuration_set_name: configuration_set_name,
          event_destination_name: DESTINATION_NAME,
          event_destination: destination
        )
        { name: DESTINATION_NAME, action: :updated, event_types: EVENT_TYPES, topic_arn: topic_arn }
      end
    rescue Aws::SESV2::Errors::ServiceError => e
      raise SesError, "Could not attach event destination to #{configuration_set_name}: #{e.message}"
    end

    def find_event_destination
      response = ses.get_configuration_set_event_destinations(configuration_set_name: configuration_set_name)
      dest = Array(response.event_destinations).find { |d| d.name == DESTINATION_NAME }
      return nil if dest.nil?

      {
        name: dest.name,
        enabled: dest.enabled,
        event_types: Array(dest.matching_event_types),
        topic_arn: dest.sns_destination&.topic_arn
      }
    rescue Aws::SESV2::Errors::NotFoundException
      nil
    rescue Aws::SESV2::Errors::ServiceError => e
      record_error("could not read event destinations: #{e.message}")
    end

    # Subscribing an endpoint that is already subscribed is a no-op that returns the same
    # ARN, but a subscription left in PendingConfirmation has to be re-sent: SNS delivers
    # the confirmation once, so one deploy where the webhook was down strands it forever.
    def ensure_subscription!(topic_arn, url)
      existing = find_subscription(topic_arn, url)
      return existing.merge(action: :existing) if existing && existing[:confirmed]

      response = sns.subscribe(
        topic_arn: topic_arn,
        protocol: 'https',
        endpoint: url,
        return_subscription_arn: true
      )
      arn = response.subscription_arn
      # The controller confirms automatically when SNS posts the confirmation, so a pending
      # result here usually resolves within seconds. It is reported rather than waited on.
      { endpoint: url, subscription_arn: arn, confirmed: confirmed?(arn), action: :subscribed }
    rescue Aws::SNS::Errors::ServiceError => e
      raise SesError, "Could not subscribe #{url} to #{topic_arn}: #{e.message}"
    end

    def find_subscription(topic_arn, url)
      token = nil
      loop do
        page = sns.list_subscriptions_by_topic(topic_arn: topic_arn, next_token: token)
        match = Array(page.subscriptions).find { |s| s.endpoint == url }
        if match
          return {
            endpoint: match.endpoint,
            subscription_arn: match.subscription_arn,
            confirmed: confirmed?(match.subscription_arn)
          }
        end

        token = page.next_token
        break if token.blank?
      end
      nil
    rescue Aws::SNS::Errors::ServiceError => e
      record_error("could not list subscriptions on #{topic_arn}: #{e.message}")
    end

    def confirmed?(subscription_arn)
      subscription_arn.to_s.start_with?('arn:')
    end
  end
end
