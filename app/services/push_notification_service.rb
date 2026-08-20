# frozen_string_literal: true

# Mobile push, delivered by OneSignal through the Natively native shell.
#
# Two audiences with deliberately different rules:
#
#   Staff (the DMS app) get a short list of key events. A push interrupts
#   someone mid-task, so Notification::PUSH_ELIGIBLE_TYPES gates what may ever
#   be sent and NotificationPreference decides what actually is. Everything
#   else still lands in the notification center.
#
#   Customers (the portal app) get every portal event: a document waiting on a
#   signature, a new invoice, a reply. They open the app when we ask them to,
#   not habitually, so a missed push is a stalled deal. They can still turn the
#   channel off wholesale via BuyerPortalAccess#push_opt_in.
class PushNotificationService
  class << self
    # Fan a saved Notification out to the recipient's devices. Safe to call for
    # every notification; the gates below drop the ones that should not push.
    def deliver(notification)
      return false unless notification.is_a?(Notification)
      return false unless notification.recipient.is_a?(User)
      return false unless notification.push_eligible?
      return false unless devices?(notification.recipient)

      preference = NotificationPreference.get_or_create_for(notification.recipient, notification.notification_type)
      return false unless preference&.push_active?

      # Quiet hours are the user's own setting; a push at 2am is the loudest
      # way to ignore it.
      return false unless preference.should_deliver_now?

      SendPushNotificationJob.perform_later(notification.id)
      true
    rescue StandardError => e
      Rails.logger.error("[Push] Failed to queue push for notification #{notification&.id}: #{e.message}")
      false
    end

    # Send a queued Notification now. Called by SendPushNotificationJob.
    def deliver_now(notification)
      user = notification.recipient
      return false unless user.is_a?(User)

      # Cheap guard before the network call. deliver? already checks this, but
      # the forced-broadcast path calls the job directly, and a 50-recipient
      # broadcast should not become 50 OneSignal calls for people who have never
      # installed the app.
      return false unless devices?(user)

      result = push!(
        owner: user,
        title: notification.title,
        body: notification.message,
        url: notification_target_url(notification),
        priority: notification.priority,
        collapse_id: notification.push_collapse_id,
        badge_count: unread_badge_count(user),
        data: {
          notification_id: notification.id,
          notification_type: notification.notification_type,
          category: notification.category,
          entity_type: notification.notifiable_type,
          entity_id: notification.notifiable_id,
          path: notification.computed_action_url
        }.compact
      )

      if result[:success]
        notification.update_columns(push_sent: true, push_sent_at: Time.current, updated_at: Time.current)
      end

      result[:success]
    end

    # Portal events. No per-type preference table for buyers by design: the
    # portal only ever pushes things that are waiting on them.
    #
    # event is a short slug ('document_to_sign', 'invoice_created', ...) used
    # for the collapse key and passed to the app for routing.
    def notify_portal(buyer_access:, event:, title:, body:, path: nil, data: {}, priority: 'normal', collapse_key: nil)
      return false unless buyer_access.is_a?(BuyerPortalAccess)
      return false unless buyer_access.portal_enabled
      return false if buyer_access.push_opt_in == false
      return false unless devices?(buyer_access)

      result = push!(
        owner: buyer_access,
        title: title,
        body: body,
        url: portal_url(path),
        priority: priority,
        collapse_id: collapse_key || event,
        data: data.merge(event: event, path: path).compact
      )

      result[:success]
    rescue StandardError => e
      Rails.logger.error("[Push] Portal push failed for buyer access #{buyer_access&.id}: #{e.message}")
      false
    end

    # Resolve the portal login for a contact/entity and push, so callers do not
    # each re-derive it. Returns false when the buyer has no portal account.
    def notify_portal_buyer(buyer:, **args)
      return false if buyer.blank?

      access = BuyerPortalAccess.find_by(buyer_type: buyer.class.name, buyer_id: buyer.id)
      return false if access.blank?

      notify_portal(buyer_access: access, **args)
    end

    # "Send a test notification to this device" from the app's settings screen.
    def send_test(owner:, player_id: nil)
      subscription_ids = player_id.present? ? [player_id] : []
      external_ids = player_id.present? ? [] : [PushSubscription.external_id_for(owner)]

      provider(PushSubscription.app_for(owner)).send_message(
        title: Brand.current.name,
        body: 'Push notifications are working on this device.',
        external_ids: external_ids,
        subscription_ids: subscription_ids,
        url: owner.is_a?(BuyerPortalAccess) ? portal_url(nil) : staff_url('/notifications'),
        data: { event: 'test' }
      )
    end

    # Low-level send. Targets the owner's alias so every signed-in device gets
    # it in one call, then prunes anything OneSignal reports as dead.
    def push!(owner:, title:, body:, url: nil, data: {}, priority: 'normal', collapse_id: nil,
              badge_count: nil, silent: false)
      app = PushSubscription.app_for(owner)
      external_id = PushSubscription.external_id_for(owner)

      result = provider(app).send_message(
        title: title,
        body: body,
        external_ids: [external_id],
        url: url,
        data: data,
        priority: priority,
        collapse_id: collapse_id,
        badge_count: badge_count,
        silent: silent
      )

      record_outcome(owner: owner, app: app, external_id: external_id, result: result)
      result
    rescue Providers::Push::OneSignalProvider::ConfigurationError => e
      Rails.logger.warn("[Push] Not configured, skipping send: #{e.message}")
      { success: false, error: 'not_configured' }
    rescue Providers::Push::OneSignalProvider::DeliveryError => e
      Rails.logger.error("[Push] Delivery error for #{external_id}: #{e.message}")
      # to_a first: record_failure! can set revoked_at, which drops the row out
      # of the `active` scope find_each re-queries between batches.
      owner_subscriptions(owner).to_a.each { |sub| sub.record_failure!(e.message) }
      { success: false, error: e.message }
    end

    # Push the user's unread count to their devices without showing anything.
    #
    # iOS clears a badge only when told to, and the Natively bridge exposes no
    # badge API, so the count has to be corrected from here: when someone reads
    # their notifications on a laptop, this is what takes the number off their
    # phone. Silent, so it never announces something already read.
    def sync_badge(user)
      return false unless user.is_a?(User)
      return false unless devices?(user)

      result = push!(
        owner: user,
        title: nil,
        body: nil,
        silent: true,
        badge_count: unread_badge_count(user),
        data: { event: 'badge_sync' }
      )

      result[:success] == true
    rescue StandardError => e
      Rails.logger.error("[Push] Badge sync failed for user #{user&.id}: #{e.message}")
      false
    end

    # Out of band: a read receipt should never wait on OneSignal.
    def sync_badge_later(user)
      return false unless user.is_a?(User)
      return false unless devices?(user)

      SyncPushBadgeJob.perform_later(user.id)
      true
    rescue StandardError => e
      Rails.logger.error("[Push] Could not queue badge sync for user #{user&.id}: #{e.message}")
      false
    end

    def configured?(app = 'staff')
      provider(app).enabled?
    end

    private

    def provider(app)
      Providers::Push::OneSignalProvider.new(app: app)
    end

    # Counted across companies rather than through the current company scope:
    # a badge is a property of the phone, and there is no "currently viewing"
    # company in a background job. For everyone but a platform admin the two
    # are the same number anyway.
    def unread_badge_count(user)
      user.notifications.unread.count
    rescue StandardError
      nil
    end

    def devices?(owner)
      owner_subscriptions(owner).exists?
    end

    def owner_subscriptions(owner)
      PushSubscription.active.where(owner_type: owner.class.name, owner_id: owner.id)
    end

    def record_outcome(owner:, app:, external_id:, result:)
      # Loaded up front: revoking a row removes it from the `active` scope, and
      # a re-querying find_each would skip past the ones it has already moved.
      subscriptions = owner_subscriptions(owner).to_a

      # OneSignal answers per alias, not per device, so an alias it does not
      # recognise means none of this owner's rows are reachable.
      if result[:invalid_external_ids].to_a.include?(external_id)
        subscriptions.each { |sub| sub.revoke!('invalid_external_id') }
        Rails.logger.info("[Push] Revoked #{external_id}: OneSignal does not know the alias")
        return
      end

      if result[:success]
        subscriptions.each(&:record_success!)
      else
        Rails.logger.info("[Push] No recipients for #{external_id} (#{app})")
      end
    end

    # A push tap opens the resolver, never the entity path directly.
    #
    # The raw path assumes the app is already signed in, already looking at the
    # right location, and that the route still exists. /n/:id makes none of
    # those assumptions: it signs the user in if needed, switches location to
    # match the notification, marks it read, and only then navigates. A stale
    # target lands on the notification center instead of a 404.
    def notification_target_url(notification)
      staff_url("/n/#{notification.id}")
    end

    def staff_url(path)
      return nil if path.blank?

      "#{Brand.app_url.to_s.chomp('/')}#{path}"
    end

    # Base URL the portal native app wraps. Defaults to the portal's real route
    # inside the main SPA, because that one is known to resolve; PORTAL_APP_URL
    # overrides it if the portal ever gets its own host. Deliberately not
    # PORTAL_URL, which the mailers point at a bare portal host and which would
    # produce a 404 for these paths.
    def portal_base_url
      ENV['PORTAL_APP_URL'].presence || "#{Brand.app_url.to_s.chomp('/')}/portalclient"
    end

    def portal_url(path)
      base = portal_base_url.chomp('/')
      return base if path.blank?

      "#{base}/#{path.to_s.delete_prefix('/')}"
    end
  end
end
