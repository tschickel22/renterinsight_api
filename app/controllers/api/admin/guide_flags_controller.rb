# frozen_string_literal: true

module Api
  module Admin
    # Questions the help assistant handed to support (E118): things that look
    # wrong, change requests, features we lack, and Report AI questions it
    # could not express. Platform admins only; across every company.
    class GuideFlagsController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!

      # GET /api/admin/guide/flags?kind=&status=open|all|<status>&company_id=
      # Feature requests also come back grouped by question, so "asked by 3
      # dealers" shows.
      def index
        flags = GuideFlag.order(created_at: :desc)
        flags = flags.where(kind: params[:kind]) if GuideFlag::KINDS.include?(params[:kind].to_s)
        status = params[:status].presence || 'open'
        flags = status == 'open' ? flags.open_items : flags
        flags = flags.where(status: status) if GuideFlag::STATUSES.include?(status)
        flags = flags.where(company_id: params[:company_id]) if params[:company_id].present?
        rows = flags.limit(200).to_a
        companies = ::Company.where(id: rows.map(&:company_id).compact.uniq).pluck(:id, :name).to_h
        users = ::User.where(id: rows.map(&:user_id).compact.uniq).pluck(:id, :first_name, :last_name, :email)
                    .to_h { |id, f, l, e| [id, [f, l].compact.join(' ').presence || e] }

        render json: {
          flags: rows.map { |f| flag_json(f, companies, users) },
          feature_requests: feature_request_groups,
          counts: GuideFlag.open_items.group(:kind).count
        }
      end

      # PATCH /api/admin/guide/flags/:id  { status, notes }
      def update
        flag = GuideFlag.find(params[:id])
        attrs = {}
        attrs[:status] = params[:status] if GuideFlag::STATUSES.include?(params[:status].to_s)
        attrs[:notes] = params[:notes].to_s.first(4_000) if params.key?(:notes)
        if attrs[:status] && !%w[new triaged].include?(attrs[:status])
          attrs[:resolved_at] = Time.current
          attrs[:resolved_by_id] = current_user.id
        end
        flag.update!(attrs)
        render json: { flag: flag_json(flag, { flag.company_id => flag.company&.name }, {}) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      private

      def flag_json(flag, companies, users)
        {
          id: flag.id, kind: flag.kind, status: flag.status, source: flag.source, question: flag.question,
          page: flag.page, assistant_reason: flag.assistant_reason, answer_shown: flag.answer_shown,
          company_id: flag.company_id, company_name: companies[flag.company_id], user_id: flag.user_id,
          user_name: users[flag.user_id], conversation_id: flag.guide_conversation_id, tool_trace: flag.tool_trace,
          notes: flag.notes, resolved_at: flag.resolved_at, created_at: flag.created_at
        }
      end

      def feature_request_groups
        GuideFlag.where(kind: 'feature_request').where('created_at > ?', 90.days.ago)
                 .pluck(:question, :assistant_reason, :company_id, :created_at)
                 .group_by { |q, reason, _, _| Guide::Gaps.normalize(reason.presence || q).first(80) }
                 .map do |_, group|
                   { topic: group.max_by { |*, at| at }[1].presence || group.first[0], asked: group.size,
                     companies: group.map { |_, _, c, _| c }.compact.uniq.size, last_asked_at: group.map(&:last).max }
                 end
                 .sort_by { |g| [-g[:companies], -g[:asked]] }.first(50)
      end
    end
  end
end
