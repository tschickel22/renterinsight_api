# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PushNotificationService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end

  # skip_push so the model's after_commit hook does not fire here: these
  # examples call PushNotificationService directly and would otherwise count
  # the hook's send as well. The hook itself is covered further down.
  def notification(type: 'lead_assigned', **attrs)
    config = Notification::TYPES[type.to_sym]
    record = Notification.new(
      {
        recipient: user,
        company_id: company.id,
        notification_type: type,
        category: config[:category],
        priority: config[:priority],
        title: config[:title],
        message: 'Something happened'
      }.merge(attrs)
    )
    record.skip_push = true
    record.save!
    record
  end

  def register_device(owner: user, player_id: SecureRandom.uuid)
    PushSubscription.register!(owner: owner, player_id: player_id, platform: 'ios')
  end

  describe '.deliver' do
    it 'queues a push for an eligible type the user has enabled' do
      register_device
      NotificationPreference.get_or_create_for(user, 'lead_assigned').update!(push_enabled: true)

      expect(SendPushNotificationJob).to receive(:perform_later)
      expect(described_class.deliver(notification)).to be true
    end

    it 'sends nothing when the user has no registered device' do
      NotificationPreference.get_or_create_for(user, 'lead_assigned').update!(push_enabled: true)

      expect(SendPushNotificationJob).not_to receive(:perform_later)
      expect(described_class.deliver(notification)).to be false
    end

    it 'sends nothing for a type outside PUSH_ELIGIBLE_TYPES, however the preference is set' do
      register_device
      pref = NotificationPreference.get_or_create_for(user, 'contact_updated')
      pref.update!(push_enabled: true)

      # The model refuses to store it in the first place, which is the point.
      expect(pref.reload.push_enabled).to be false

      expect(SendPushNotificationJob).not_to receive(:perform_later)
      expect(described_class.deliver(notification(type: 'contact_updated'))).to be false
    end

    it 'respects an opted-out preference on an eligible type' do
      register_device
      NotificationPreference.get_or_create_for(user, 'lead_assigned').update!(push_enabled: false)

      expect(SendPushNotificationJob).not_to receive(:perform_later)
      expect(described_class.deliver(notification)).to be false
    end

    it 'holds a push during the user\'s quiet hours' do
      register_device
      # Stored as the wall-clock string a time picker submits, which is what
      # should_deliver_now? compares against.
      now = Time.current.in_time_zone('America/Denver')
      NotificationPreference.get_or_create_for(user, 'lead_assigned').update!(
        push_enabled: true,
        respect_quiet_hours: true,
        quiet_hours_start: (now - 1.hour).strftime('%H:%M'),
        quiet_hours_end: (now + 1.hour).strftime('%H:%M')
      )

      expect(SendPushNotificationJob).not_to receive(:perform_later)
      expect(described_class.deliver(notification)).to be false
    end

    it 'ignores a revoked device' do
      device = register_device
      device.revoke!('uninstalled')
      NotificationPreference.get_or_create_for(user, 'lead_assigned').update!(push_enabled: true)

      expect(SendPushNotificationJob).not_to receive(:perform_later)
      expect(described_class.deliver(notification)).to be false
    end
  end

  describe '.deliver_now' do
    let(:provider) { instance_double(Providers::Push::OneSignalProvider) }

    before do
      allow(Providers::Push::OneSignalProvider).to receive(:new).and_return(provider)
      register_device
    end

    it 'targets the user alias and records the send' do
      note = notification(action_url: '/crm/leads/9')

      expect(provider).to receive(:send_message).with(
        hash_including(external_ids: ["staff:#{user.id}"])
      ).and_return({ success: true, recipients: 1, invalid_external_ids: [], invalid_subscription_ids: [] })

      expect(described_class.deliver_now(note)).to be true
      expect(note.reload.push_sent).to be true
      expect(note.push_sent_at).to be_present
    end

    it 'revokes every device when OneSignal does not recognise the alias' do
      expect(provider).to receive(:send_message).and_return(
        { success: false, recipients: 0, invalid_external_ids: ["staff:#{user.id}"], invalid_subscription_ids: [] }
      )

      described_class.deliver_now(notification)

      expect(PushSubscription.where(owner: user).active.count).to eq(0)
    end
  end

  describe '.notify_portal' do
    let(:buyer) do
      Contact.create!(company_id: company.id, first_name: 'B', last_name: 'Uyer',
                      email: "b-#{SecureRandom.hex(3)}@example.com")
    end
    let(:access) do
      BuyerPortalAccess.create!(buyer: buyer, company_id: company.id,
                                email: "p-#{SecureRandom.hex(3)}@example.com",
                                password: 'Password123!', password_confirmation: 'Password123!')
    end
    let(:provider) { instance_double(Providers::Push::OneSignalProvider) }

    before { allow(Providers::Push::OneSignalProvider).to receive(:new).and_return(provider) }

    it 'pushes to a registered portal device' do
      register_device(owner: access)

      expect(provider).to receive(:send_message).with(
        hash_including(external_ids: ["portal:#{access.id}"])
      ).and_return({ success: true, recipients: 1, invalid_external_ids: [], invalid_subscription_ids: [] })

      expect(
        described_class.notify_portal(buyer_access: access, event: 'invoice_created', title: 'T', body: 'B')
      ).to be true
    end

    it 'sends nothing once the customer has opted out' do
      register_device(owner: access)
      access.update!(push_opt_in: false)

      expect(provider).not_to receive(:send_message)
      expect(
        described_class.notify_portal(buyer_access: access, event: 'invoice_created', title: 'T', body: 'B')
      ).to be false
    end

    it 'sends nothing when portal access is disabled' do
      register_device(owner: access)
      access.update!(portal_enabled: false)

      expect(provider).not_to receive(:send_message)
      expect(
        described_class.notify_portal(buyer_access: access, event: 'invoice_created', title: 'T', body: 'B')
      ).to be false
    end
  end

  # The reason push moved onto the model: three call sites build Notification
  # records directly, and an inbound email reply is one of them.
  describe 'creation paths that bypass NotificationService' do
    it 'pushes for a Notification built directly through the model' do
      register_device
      NotificationPreference.get_or_create_for(user, 'email_reply_received').update!(push_enabled: true)

      expect(SendPushNotificationJob).to receive(:perform_later)

      Notification.create!(
        recipient: user, company_id: company.id,
        notification_type: 'email_reply_received',
        category: 'communications', priority: 'high',
        title: 'Reply from a customer', message: 'They replied'
      )
    end

    it 'stays silent when the caller sets skip_push' do
      register_device
      NotificationPreference.get_or_create_for(user, 'email_reply_received').update!(push_enabled: true)

      expect(SendPushNotificationJob).not_to receive(:perform_later)

      note = Notification.new(
        recipient: user, company_id: company.id,
        notification_type: 'email_reply_received',
        category: 'communications', priority: 'high',
        title: 'Reply from a customer', message: 'They replied'
      )
      note.skip_push = true
      note.save!
    end

    it 'pushes once, not twice, when created through NotificationService' do
      register_device
      NotificationPreference.get_or_create_for(user, 'lead_assigned').update!(push_enabled: true)

      expect(SendPushNotificationJob).to receive(:perform_later).once

      NotificationService.create(
        recipient: user, notification_type: :lead_assigned,
        message: 'A lead was assigned', deliver_now: false
      )
    end
  end

  describe 'PushSubscription.register!' do
    it 'is idempotent across relaunches' do
      id = SecureRandom.uuid
      register_device(player_id: id)

      expect { register_device(player_id: id) }.not_to change(PushSubscription, :count)
    end

    it 'moves a player id to whoever signed in on that device last' do
      id = SecureRandom.uuid
      register_device(player_id: id)

      other = User.create!(email: "o-#{SecureRandom.hex(3)}@example.com", first_name: 'O', last_name: 'U',
                           password: 'Pass1234!', company_id: company.id)
      subscription = PushSubscription.register!(owner: other, player_id: id)

      expect(PushSubscription.where(player_id: id).count).to eq(1)
      expect(subscription.owner).to eq(other)
      expect(subscription.external_id).to eq("staff:#{other.id}")
    end

    it 'un-revokes a device that comes back' do
      id = SecureRandom.uuid
      register_device(player_id: id).revoke!('uninstalled')

      expect(register_device(player_id: id).revoked_at).to be_nil
    end
  end
end
