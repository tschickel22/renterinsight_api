# frozen_string_literal: true

module Api
  module Crm
    # The Inbox (backlog E96): one row per person a buyer conversation is with,
    # whoever is handling it, the Lead Assistant or a person. Messages are read
    # and sent through the existing communication endpoints; this lists the
    # conversations and changes who has them.
    class ConversationsController < ApplicationController
      before_action :set_company_scope
      before_action :set_conversation, except: %i[index for_record]

      VIEWS = %w[all needs_you mine unassigned done].freeze
      PER_PAGE = 50

      def index
        return unless authorize_action!('leads', 'read')

        base = visible_scope
        counts = view_counts(base)

        scope = apply_view(base, params[:view].presence_in(VIEWS) || 'all')
        scope = apply_filters(scope)
        total = scope.count
        page = [params[:page].to_i, 1].max
        rows = scope.includes(:conversable, :assigned_user, :handed_off_to_user)
                    .order(Arel.sql('last_message_at DESC NULLS LAST'))
                    .offset((page - 1) * PER_PAGE).limit(PER_PAGE).to_a
        reads = ConversationRead.where(user_id: current_user.id, conversation_id: rows.map(&:id))
                                .pluck(:conversation_id, :last_read_at).to_h

        @next_appointments = next_appointments(rows)
        render json: {
          items: rows.map { |c| row_json(c, reads[c.id]) },
          meta: { total: total, page: page, per_page: PER_PAGE, total_pages: (total.to_f / PER_PAGE).ceil, counts: counts,
                  # The Lead Assistant is a paid add-on; without it the Inbox shows
                  # no assistant controls.
                  assistant: assistant_meta }
        }
      end

      def show
        return unless authorize_action!('leads', 'read')

        read = ConversationRead.find_by(user_id: current_user.id, conversation_id: @conversation.id)&.last_read_at
        render json: row_json(@conversation, read)
      end

      # The open conversation on a lead or contact, for the record page banner.
      def for_record
        return unless authorize_action!('leads', 'read')

        type = params[:type].presence_in(%w[Lead Contact])
        return render(json: { conversation: nil }) unless type

        conversation = visible_scope.where(conversable_type: type, conversable_id: params[:id])
                                    .order(Arel.sql("CASE WHEN status = 'closed' THEN 1 ELSE 0 END, last_message_at DESC NULLS LAST")).first
        render json: { conversation: conversation && row_json(conversation, nil) }
      end

      def read
        return unless authorize_action!('leads', 'read')

        row = ConversationRead.find_or_initialize_by(conversation_id: @conversation.id, user_id: current_user.id)
        row.update!(last_read_at: Time.current)
        render json: { ok: true }
      end

      def assign
        return unless authorize_action!('leads', 'update')

        user = params[:user_id].present? ? @company.users.find_by(id: params[:user_id]) : nil
        return render(json: { error: 'User not found' }, status: :unprocessable_entity) if params[:user_id].present? && user.nil?

        @conversation.update!(assigned_user_id: user&.id)
        render json: row_json(@conversation.reload, nil)
      end

      def snooze
        return unless authorize_action!('leads', 'update')

        until_time = params[:until].present? ? Time.zone.parse(params[:until].to_s) : nil
        @conversation.update!(snoozed_until: until_time)
        render json: row_json(@conversation, nil)
      rescue ArgumentError
        render json: { error: 'Invalid time' }, status: :unprocessable_entity
      end

      def done
        return unless authorize_action!('leads', 'update')

        @conversation.update!(status: 'closed', ended_at: Time.current)
        render json: row_json(@conversation, nil)
      end

      def reopen
        return unless authorize_action!('leads', 'update')

        unless @conversation.status == 'closed'
          return render(json: row_json(@conversation, nil))
        end

        clash = Conversation.open_now.where(sender_number: @conversation.sender_number, buyer_phone: @conversation.buyer_phone)
                            .where.not(id: @conversation.id).exists?
        return render(json: { error: 'A newer conversation with this buyer is already open' }, status: :conflict) if clash

        @conversation.update!(status: 'handed_off', ended_at: nil, handed_off_to_user_id: current_user.id,
                              handed_off_at: Time.current, handoff_reason: 'reopened')
        render json: row_json(@conversation, nil)
      end

      # "I'll take it": the assistant stops answering.
      def take_over
        return unless authorize_action!('leads', 'update')

        Assistant::Handoff.taken_over!(@conversation, current_user) if @conversation.status == 'active'
        render json: row_json(@conversation.reload, nil)
      end

      # A website chat's messages, oldest first (after: only newer ones, for
      # the Inbox's own few-second check while the thread is open).
      def chat_messages
        return unless authorize_action!('leads', 'read')
        return render(json: { error: 'Not a website chat' }, status: :unprocessable_entity) unless @conversation.web_chat?

        scope = @conversation.chat_messages.order(:id)
        scope = scope.where('id > ?', params[:after].to_i) if params[:after].present?
        users = User.where(id: scope.map(&:user_id).compact.uniq).index_by(&:id)
        render json: {
          messages: scope.last(200).map { |m| m.as_chat_json.merge(user_name: users[m.user_id]&.first_name) },
          visitor_on_page: @conversation.visitor_on_page?, visitor_seen_at: @conversation.visitor_seen_at,
          page_url: @conversation.chat_page_url, conversation: row_json(@conversation, nil)
        }
      end

      # A rep answers in the website chat. Quinn stops answering from here on.
      def chat_reply
        return unless authorize_action!('leads', 'update')
        return render(json: { error: 'Not a website chat' }, status: :unprocessable_entity) unless @conversation.web_chat?

        body = params[:body].to_s.strip.truncate(2000)
        return render(json: { error: 'Type a message' }, status: :unprocessable_entity) if body.blank?

        Assistant::Handoff.taken_over!(@conversation, current_user) if @conversation.status == 'active'
        @conversation.update!(status: 'handed_off', ended_at: nil) if @conversation.status == 'closed'
        result = Assistant::Messenger.deliver!(@conversation, body: body, sent_by: 'user', user: current_user)
        render json: { message: result[:chat_message].as_chat_json.merge(user_name: current_user.first_name),
                       visitor_on_page: @conversation.visitor_on_page? }
      end

      def hand_back
        return unless authorize_action!('leads', 'update')
        settings = Assistant::Settings.for(@company)
        allowed = @conversation.web_chat? ? settings.chat_add_on? : (@conversation.channel == 'sms' && settings.enabled?)
        unless allowed
          return render(json: { error: 'The Lead Assistant is not on for this account' }, status: :unprocessable_entity)
        end
        return render(json: { error: 'This conversation is closed' }, status: :unprocessable_entity) if @conversation.status == 'closed'

        Assistant::Handoff.hand_back!(@conversation)
        render json: row_json(@conversation.reload, nil)
      end

      private

      # The next pending visit for each conversation's lead or contact, in two
      # queries for the page, so the Inbox can link to it on the calendar.
      def next_appointments(conversations)
        found = {}
        { 'Lead' => [LeadActivity, :lead_id], 'Contact' => [ContactActivity, :contact_id] }.each do |type, (model, key)|
          ids = conversations.select { |c| c.conversable_type == type }.map(&:conversable_id)
          next if ids.empty?

          model.where(key => ids, activity_type: 'meeting', status: 'pending').where('start_time >= ?', Time.current)
               .order(:start_time).each { |a| found[[type, a.public_send(key)]] ||= a }
        end
        found
      end

      def next_appointment_json(c)
        @next_appointments ||= next_appointments([c])
        a = @next_appointments[[c.conversable_type, c.conversable_id]]
        a && { id: a.id, start_time: a.start_time, subject: a.subject }
      end

      def assistant_meta
        settings = Assistant::Settings.for(@company)
        { available: settings.add_on?, enabled: settings.enabled?, name: settings.assistant_name,
          chat: settings.chat_add_on? }
      end

      def set_conversation
        @conversation = visible_scope.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      # Same rule as the lead list: admins and people who read every lead see
      # all; everyone else sees their locations (and conversations with no
      # location). Then the location picker.
      def visible_scope
        # A website chat counts once the visitor has said something: a greeting
        # nobody answered (after a form, or an opened chat) is not a conversation.
        scope = @company.conversations.where("conversations.channel <> 'web_chat' OR conversations.last_inbound_at IS NOT NULL")
        if current_user.uses_rbac? && !current_user.effective_admin? && !permission_service.can?('leads', 'read', 'all')
          location_ids = permission_service.accessible_location_ids
          scope = scope.where('conversations.location_id IN (?) OR conversations.location_id IS NULL', location_ids) if location_ids.any?
        end
        scope.for_current_location
      end

      def not_snoozed(scope)
        scope.where('conversations.snoozed_until IS NULL OR conversations.snoozed_until <= ?', Time.current)
      end

      NEEDS_YOU_SQL = <<~SQL.squish
        conversations.status <> 'closed'
        AND NOT (conversations.status = 'active' AND conversations.assistant_enabled)
        AND conversations.last_inbound_at IS NOT NULL
        AND (conversations.last_person_reply_at IS NULL OR conversations.last_inbound_at > conversations.last_person_reply_at)
      SQL

      def apply_view(scope, view)
        case view
        when 'needs_you' then not_snoozed(scope.where(NEEDS_YOU_SQL))
        when 'mine'
          scope.where(status: Conversation::OPEN_STATUSES)
               .where('conversations.assigned_user_id = :id OR conversations.handed_off_to_user_id = :id', id: current_user.id)
        when 'unassigned' then scope.where(status: Conversation::OPEN_STATUSES, assigned_user_id: nil)
        when 'done' then scope.where(status: 'closed')
        else scope.where(status: Conversation::OPEN_STATUSES)
        end
      end

      def view_counts(base)
        {
          needs_you: apply_view(base, 'needs_you').count,
          mine: apply_view(base, 'mine').count,
          unassigned: apply_view(base, 'unassigned').count
        }
      end

      def apply_filters(scope)
        # Any conversation with a message on that channel: one row is one person,
        # so a text conversation they later answered by email is an email one too.
        if params[:channel].present? && Conversation::CHANNELS.include?(params[:channel])
          with_messages = Communication.where(channel: params[:channel]).where.not(conversation_id: nil).select(:conversation_id)
          scope = scope.where(channel: params[:channel]).or(scope.where(id: with_messages))
        end
        case params[:handled_by]
        when 'assistant' then scope = scope.where(status: 'active', assistant_enabled: true)
        when 'person' then scope = scope.where.not(status: 'active').or(scope.where(assistant_enabled: false))
        end
        if params[:source_id].present?
          scope = scope.where(conversable_type: 'Lead', conversable_id: @company.leads.where(source_id: params[:source_id]).select(:id))
        end
        if params[:q].present?
          term = "%#{params[:q].to_s.strip}%"
          digits = params[:q].to_s.gsub(/\D/, '')
          lead_ids = @company.leads.where("first_name ILIKE :t OR last_name ILIKE :t OR CONCAT(first_name, ' ', last_name) ILIKE :t OR email ILIKE :t", t: term).select(:id)
          contact_ids = @company.contacts.where("first_name ILIKE :t OR last_name ILIKE :t OR CONCAT(first_name, ' ', last_name) ILIKE :t OR email ILIKE :t", t: term).select(:id)
          cond = scope.where(conversable_type: 'Lead', conversable_id: lead_ids)
                      .or(scope.where(conversable_type: 'Contact', conversable_id: contact_ids))
                      .or(scope.where('conversations.last_message_preview ILIKE ?', term))
          cond = cond.or(scope.where('conversations.buyer_phone LIKE ?', "%#{digits}%")) if digits.length >= 4
          scope = cond
        end
        scope
      end

      def needs_you?(c)
        c.status != 'closed' && !c.assistant_answering? && c.last_inbound_at.present? &&
          (c.last_person_reply_at.nil? || c.last_inbound_at > c.last_person_reply_at)
      end

      def handler_label(c)
        return 'Done' if c.status == 'closed'
        return 'Assistant' if c.assistant_answering?
        return 'Needs you' if needs_you?(c)

        'Waiting on buyer'
      end

      def row_json(c, last_read_at)
        record = c.conversable
        name = [record.try(:first_name), record.try(:last_name)].compact_blank.join(' ').presence ||
               record.try(:display_name).presence
        {
          id: c.id,
          status: c.status,
          state: handler_label(c),
          assistant_answering: c.assistant_answering?,
          needs_you: needs_you?(c),
          unread: c.last_inbound_at.present? && (last_read_at.nil? || c.last_inbound_at > last_read_at),
          channel: c.channel,
          pool: c.pool,
          record: record && { type: c.conversable_type, id: c.conversable_id, name: name, phone: record.try(:phone),
                              email: record.try(:email), source: record.try(:source).try(:name) },
          buyer_phone: c.buyer_phone,
          assigned_user: c.assigned_user && { id: c.assigned_user.id, name: c.assigned_user.try(:full_name).presence || c.assigned_user.email },
          handed_off_to: c.handed_off_to_user && { id: c.handed_off_to_user.id, name: c.handed_off_to_user.try(:full_name).presence || c.handed_off_to_user.email },
          handoff_reason: c.handoff_reason,
          handoff_label: c.handoff_reason && Assistant::Handoff::REASON_LABELS[c.handoff_reason],
          qualification: c.qualification || {},
          last_message_at: c.last_message_at,
          last_message_preview: c.last_message_preview,
          snoozed_until: c.snoozed_until,
          started_at: c.started_at,
          next_appointment: next_appointment_json(c),
          visitor_on_page: c.visitor_on_page?,
          chat_page_url: c.chat_page_url
        }
      end
    end
  end
end
