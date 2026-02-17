# frozen_string_literal: true

module Api
  module Partner
    module V1
      class UsersController < BaseController
        before_action :authorize_users
        before_action :set_user, only: [:show]

        # GET /api/partner/v1/users
        # Read-only: partners can list users for reference (owner assignments, etc.)
        def index
          users = company_scope(User).where(deleted_at: nil)

          # Filters
          users = users.where(status: params[:status]) if params[:status].present?
          users = users.where(role: params[:role]) if params[:role].present?
          users = users.where(department: params[:department]) if params[:department].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            users = users.where(
              "first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q OR CONCAT(first_name, ' ', last_name) ILIKE :q",
              q: q
            )
          end

          # Cursor-based pagination
          users = users.order(:id)
          users = users.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          users = users.limit(limit + 1)

          records = users.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |u| user_json(u) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/users/:id
        def show
          render json: { data: user_json(@user, detailed: true) }
        end

        private

        def authorize_users
          authorize_permission!(:users, :read)
        end

        def set_user
          @user = company_scope(User).where(deleted_at: nil).find(params[:id])
        end

        def user_json(user, detailed: false)
          json = {
            id: user.id,
            first_name: user.first_name,
            last_name: user.last_name,
            email: user.email,
            phone: user.phone,
            status: user.status,
            role: user.role,
            title: user.title,
            department: user.department,
            created_at: user.created_at&.iso8601,
            updated_at: user.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              last_sign_in_at: user.last_sign_in_at&.iso8601,
              mfa_enabled: user.mfa_enabled
            )
          end

          json
        end
      end
    end
  end
end
