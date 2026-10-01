# frozen_string_literal: true

module Api
  module V1
    # The React consent page's API. The user is signed in normally (MFA
    # included) and decides whether an AI app may act as them at their company.
    class OauthConsentsController < ApplicationController
      before_action :set_company_scope
      before_action :load_request

      # GET /api/v1/oauth/consent?request=...
      def show
        render json: {
          client: client_json(@auth.client),
          redirect_host: URI.parse(@auth.redirect_uri).host,
          scopes: @auth.scopes,
          company: { id: @company.id, name: @company.name },
          user: { name: current_user.full_name, email: current_user.email },
          can_connect: blocking_reason.nil?,
          can_allow_changes: blocking_reason.nil? && Oauth::AccessPolicy.changes_permitted?(current_user, @company),
          blocking_reason: blocking_reason,
          existing_connection: existing_grant.present?,
          shows_costs: McpTools::Context.new(user: current_user, company: @company, grant: nil).show_costs?
        }
      end

      # POST /api/v1/oauth/consent { request, decision: approve|deny, allow_write }
      def create
        issuer = Oauth::Config.issuer(request)

        if params[:decision] != 'approve'
          return render json: { redirect_url: Oauth::AuthorizationRequest.redirect_with(
            @auth.redirect_uri, error: 'access_denied', error_description: 'The user declined',
                                state: @auth.state, iss: issuer
          ) }
        end

        if (reason = blocking_reason)
          return render json: { error: reason }, status: :forbidden
        end

        allow_write = ActiveModel::Type::Boolean.new.cast(params[:allow_write]) &&
                      Oauth::AccessPolicy.changes_permitted?(current_user, @company)
        scopes = allow_write ? @auth.scopes : (@auth.scopes - ['mcp:write'])
        scopes = ['mcp:read'] if scopes.empty?

        grant = existing_grant || OauthGrant.new(oauth_client: @auth.client, user: current_user, company: @company)
        grant.update!(scopes: scopes.join(' '), resource: @auth.resource)

        _record, code = OauthAuthorizationCode.issue!(
          grant: grant, redirect_uri: @auth.redirect_uri, code_challenge: @auth.code_challenge, scopes: scopes
        )

        ActivityLogService.log(
          company: @company, user: current_user, action: 'connected', module_name: 'ai_connector',
          description: "Connected #{@auth.client.client_name} (#{scopes.join(', ')})",
          metadata: { oauth_grant_id: grant.id, client_id: @auth.client.client_id }
        )

        render json: { redirect_url: Oauth::AuthorizationRequest.redirect_with(
          @auth.redirect_uri, code: code, state: @auth.state, iss: issuer
        ) }
      end

      private

      def load_request
        @auth = Oauth::AuthorizationRequest.from_signed(params[:request])
      rescue Oauth::AuthorizationRequest::Untrusted => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def blocking_reason
        @blocking_reason ||=
          if original_user != current_user
            'You cannot connect an AI app while viewing as another user.'
          elsif current_user.platform_admin? || current_user.super_admin?
            'Platform administrators cannot connect AI apps. Sign in as a company user.'
          elsif !Oauth::AccessPolicy.user_may_connect?(current_user)
            'Your user account is not active.'
          elsif current_user.company_id != @company.id
            'You can only connect AI apps to your own company.'
          elsif !Oauth::AccessPolicy.module_enabled?(@company)
            'The AI connector is not part of your plan. Ask us to turn it on.'
          elsif !Oauth::AccessPolicy.permitted?(current_user, @company)
            'Your role does not include the AI connector. Ask your admin to turn it on for your role under Users, Roles & Permissions.'
          end
      end

      def existing_grant
        @existing_grant ||= OauthGrant.active.find_by(oauth_client: @auth.client, user: current_user, company: @company)
      end

      def client_json(client)
        {
          name: client.client_name,
          client_uri: client.client_uri,
          logo_uri: client.logo_uri,
          verified_host: client.registration_type == 'cimd' ? URI.parse(client.client_id).host : nil
        }
      end
    end
  end
end
