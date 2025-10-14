module Api
  module Portal
    class CommunicationsController < ApplicationController
      before_action :authenticate_portal_buyer!
      
      def index
        communications = current_portal_buyer.buyer
          .communications
          .where(portal_visible: true)
          .order(created_at: :desc)
        
        # Filter by read status if requested
        if params[:read] == 'false'
          communications = communications.where(read_at: nil)
        elsif params[:read] == 'true'
          communications = communications.where.not(read_at: nil)
        end
        
        # Pagination
        page = params[:page]&.to_i || 1
        per_page = params[:per_page]&.to_i || 20
        total = communications.count
        communications = communications.limit(per_page).offset((page - 1) * per_page)
        
        render json: {
          ok: true,
          communications: communications.map { |c| communication_json(c) },
          pagination: {
            page: page,
            per_page: per_page,
            total: total,
            pages: (total.to_f / per_page).ceil
          }
        }
      end
      
      def show
        communication = current_portal_buyer.buyer
          .communications
          .where(portal_visible: true)
          .find_by(id: params[:id])
        
        return render json: { ok: false, error: 'Not found' }, status: :not_found unless communication
        
        # Mark as read on first view
        communication.update(read_at: Time.current) if communication.read_at.nil?
        
        render json: {
          ok: true,
          communication: communication_json(communication)
        }
      end
      
      def create
        thread = CommunicationThread.find_by(id: params[:thread_id])
        
        return render json: { ok: false, error: 'Thread not found' }, status: :not_found unless thread
        return render json: { ok: false, error: 'Body is required' }, status: :unprocessable_entity unless params[:body].present?
        
        # Verify thread belongs to buyer
        unless thread.participant_id == current_portal_buyer.buyer_id && 
               thread.participant_type == current_portal_buyer.buyer_type
          return render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
        end
        
        communication = Communication.create!(
          communicable: current_portal_buyer.buyer,
          communication_thread: thread,
          direction: 'inbound',
          channel: 'portal_message',
          provider: 'portal',
          status: 'sent',
          subject: "Re: #{thread.subject}",
          body: params[:body],
          from_address: current_portal_buyer.email,
          to_address: ENV.fetch('SUPPORT_EMAIL', 'support@renterinsight.com'),
          portal_visible: true,
          received_at: Time.current
        )
        
        # Send notification to internal team
        BuyerPortalService.notify_internal_of_reply(communication)
        
        render json: {
          ok: true,
          communication: communication_json(communication)
        }, status: :created
      end
      
      def mark_as_read
        communication = current_portal_buyer.buyer
          .communications
          .where(portal_visible: true)
          .find_by(id: params[:id])
        
        return render json: { ok: false, error: 'Not found' }, status: :not_found unless communication
        
        communication.update(read_at: Time.current) if communication.read_at.nil?
        
        render json: {
          ok: true,
          communication: communication_json(communication)
        }
      end
      
      def threads
        threads = CommunicationThread.where(
          participant_type: current_portal_buyer.buyer_type,
          participant_id: current_portal_buyer.buyer_id
        ).order(last_message_at: :desc)
        
        render json: {
          ok: true,
          threads: threads.map { |t| thread_json(t) }
        }
      end
      
      private
      
      def communication_json(communication)
        {
          id: communication.id,
          thread_id: communication.communication_thread_id,
          direction: communication.direction,
          channel: communication.channel,
          subject: communication.subject,
          body: communication.body,
          from_address: communication.from_address,
          to_address: communication.to_address,
          read_at: communication.read_at,
          sent_at: communication.sent_at,
          received_at: communication.received_at,
          created_at: communication.created_at
        }
      end
      
      def thread_json(thread)
        {
          id: thread.id,
          subject: thread.subject,
          channel: thread.channel,
          status: thread.status,
          last_message_at: thread.last_message_at,
          created_at: thread.created_at,
          message_count: thread.communications.count
        }
      end
    end
  end
end
