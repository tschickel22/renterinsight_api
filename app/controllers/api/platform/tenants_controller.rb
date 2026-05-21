# frozen_string_literal: true

module Api
  module Platform
    class TenantsController < ApplicationController
      # Skip authentication for public availability checks
      skip_before_action :authenticate, only: [:check_subdomain_available, :check_domain_available]
      
      # Require platform admin for all tenant management actions
      before_action :require_platform_admin!, except: [:check_subdomain_available, :check_domain_available]
      before_action :set_tenant, only: [:show, :update, :destroy, :verify_domain, :generate_domain_token, :generate_email_dns_records, :verify_email_domain, :check_domain_dns, :check_email_dns, :send_owner_invitation, :update_owner_invitation]
      
      # GET /api/platform/tenants
      def index
        begin
          @tenants = ::Company.all.order(created_at: :desc)
          
          # Apply filters
          @tenants = @tenants.where(status: params[:status]) if params[:status].present?
          @tenants = @tenants.where(subscription_tier: params[:subscription_tier]) if params[:subscription_tier].present?
          
          # Search
          if params[:search].present?
            search_term = "%#{params[:search]}%"
            @tenants = @tenants.where(
              'name ILIKE ? OR subdomain ILIKE ? OR custom_domain ILIKE ?',
              search_term, search_term, search_term
            )
          end
          
          # Pagination
          page = params[:page]&.to_i || 1
          per_page = params[:per_page]&.to_i || 20
          total = @tenants.count
          @tenants = @tenants.offset((page - 1) * per_page).limit(per_page)
          
          # Serialize with error handling
          serialized_tenants = @tenants.map do |t|
            begin
              serialize_tenant(t)
            rescue => e
              Rails.logger.error "Error serializing tenant #{t.id}: #{e.message}"
              {
                id: t.id,
                name: t.try(:name) || 'Error',
                subdomain: t.try(:subdomain),
                custom_domain: nil,
                domain_verified: false,
                status: 'active',
                subscription_tier: nil,
                users_count: 0,
                created_at: Time.current,
                updated_at: Time.current
              }
            end
          end
          
          render json: {
            tenants: serialized_tenants,
            pagination: {
              page: page,
              per_page: per_page,
              total: total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        rescue => e
          Rails.logger.error "Tenants index error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            error: 'Failed to fetch tenants', 
            details: Rails.env.development? ? e.message : 'Internal error',
            tenants: [],
            pagination: { page: 1, per_page: 20, total: 0, total_pages: 0 }
          }, status: :ok
        end
      end
      
      # GET /api/platform/tenants/:id
      def show
        render json: { tenant: serialize_tenant(@tenant, detailed: true) }
      end
      
      # POST /api/platform/tenants
      def create
        begin
          # Extract subscription params before creating tenant
          subscription_plan_id = params.dig(:tenant, :subscription_plan_id)
          billing_cycle = params.dig(:tenant, :billing_cycle) || 'monthly'
          start_trial = params.dig(:tenant, :start_trial) == true || params.dig(:tenant, :start_trial) == 'true'
          
          @tenant = ::Company.new(tenant_params.except(
            :owner_email, :owner_first_name, :owner_last_name, :owner_phone, :send_invitation,
            :subscription_plan_id, :billing_cycle, :start_trial
          ))
          
          if @tenant.save
            subscription_error = nil
            
            # Create subscription if plan provided
            if subscription_plan_id.present?
              begin
                Rails.logger.info "Creating subscription for tenant #{@tenant.id} with plan_id=#{subscription_plan_id}, billing=#{billing_cycle}, trial=#{start_trial}"
                create_tenant_subscription(@tenant, subscription_plan_id, billing_cycle, start_trial)
                Rails.logger.info "✅ Subscription created successfully for tenant #{@tenant.id}"
              rescue => e
                subscription_error = e.message
                Rails.logger.error "❌ Failed to create tenant subscription: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
              end
            end
            
            # Auto-create tenant owner invitation if email provided
            if tenant_params[:owner_email].present?
              begin
                # Get send_invitation param (default: false for delayed sending)
                send_now = params.dig(:tenant, :send_invitation) == true || 
                           params.dig(:tenant, :send_invitation) == 'true'
                
                create_tenant_owner(@tenant, send_now: send_now)
              rescue => e
                Rails.logger.error "Failed to create tenant owner invitation: #{e.message}"
                # Don't fail the whole request if invitation creation fails
              end
            end
            
            response_data = { 
              tenant: serialize_tenant(@tenant.reload, detailed: true),
              message: 'Tenant created successfully'
            }
            
            # Include subscription warning if there was an error
            if subscription_error.present?
              response_data[:subscription_warning] = "Failed to create subscription: #{subscription_error}"
            end
            
            render json: response_data, status: :created
          else
            render json: { errors: @tenant.errors.full_messages }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "Tenant creation error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            errors: [Rails.env.development? ? e.message : 'Failed to create tenant']
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/platform/tenants/:id
      def update
        begin
          # Extract subscription params before updating tenant
          subscription_plan_id = params.dig(:tenant, :subscription_plan_id)
          billing_cycle = params.dig(:tenant, :billing_cycle)
          
          if @tenant.update(tenant_params.except(
            :subscription_plan_id, :billing_cycle, :start_trial,
            :owner_email, :owner_first_name, :owner_last_name, :owner_phone
          ))
            subscription_error = nil
            
            # Update subscription if plan_id provided
            if subscription_plan_id.present?
              begin
                Rails.logger.info "Updating subscription for tenant #{@tenant.id} with plan_id=#{subscription_plan_id}, billing=#{billing_cycle}"
                update_tenant_subscription(@tenant, subscription_plan_id, billing_cycle)
                Rails.logger.info "✅ Subscription updated successfully for tenant #{@tenant.id}"
              rescue => e
                subscription_error = e.message
                Rails.logger.error "❌ Failed to update tenant subscription: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
              end
            end
            
            response_data = { 
              tenant: serialize_tenant(@tenant.reload, detailed: true),
              message: 'Tenant updated successfully'
            }
            
            # Include subscription warning if there was an error
            if subscription_error.present?
              response_data[:subscription_warning] = "Failed to update subscription: #{subscription_error}"
            end
            
            render json: response_data
          else
            # Return detailed validation errors
            render json: { 
              errors: @tenant.errors.full_messages,
              field_errors: @tenant.errors.messages
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "Tenant update error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            errors: [Rails.env.development? ? e.message : 'Failed to update tenant']
          }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/platform/tenants/:id
      def destroy
        begin
          if @tenant.destroy
            render json: { message: 'Tenant deleted successfully' }
          else
            render json: { errors: ['Failed to delete tenant'] }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "Tenant delete error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            errors: [Rails.env.development? ? e.message : 'Failed to delete tenant']
          }, status: :unprocessable_entity
        end
      end
      
      # GET /api/platform/tenants/check_subdomain_available
      def check_subdomain_available
        begin
          subdomain = params[:subdomain]&.downcase&.strip
          
          if subdomain.blank?
            return render json: { available: false, error: 'Subdomain is required' }
          end
          
          # Check format - allow 1-63 characters, alphanumeric and dashes
          # Must start and end with alphanumeric
          unless subdomain.match?(/\A[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\z/)
            return render json: { 
              available: false, 
              error: 'Subdomain must be 1-63 characters, alphanumeric with dashes' 
            }
          end
          
          # Check availability
          exists = ::Company.where(subdomain: subdomain).exists?
          
          # Check reserved subdomains
          reserved = %w[www api app admin platform staging production demo test]
          is_reserved = reserved.include?(subdomain)
          
          render json: { 
            available: !exists && !is_reserved,
            error: if exists
                    'Subdomain is already taken'
                  elsif is_reserved
                    'Subdomain is reserved'
                  end
          }
        rescue => e
          Rails.logger.error "Subdomain check error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          render json: { available: true, error: nil }
        end
      end
      
      # GET /api/platform/tenants/check_domain_available
      def check_domain_available
        begin
          domain = params[:domain]&.downcase&.strip
          
          if domain.blank?
            return render json: { available: false, error: 'Domain is required' }
          end
          
          # Check format
          unless domain.match?(/\A[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,}\z/i)
            return render json: { 
              available: false, 
              error: 'Invalid domain format' 
            }
          end
          
          # Check availability
          exists = ::Company.where(custom_domain: domain).exists?
          
          render json: { 
            available: !exists,
            error: exists ? 'Domain is already in use' : nil
          }
        rescue => e
          Rails.logger.error "Domain check error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          render json: { available: true, error: nil }
        end
      end
      
      # POST /api/platform/tenants/:id/generate_domain_token
      def generate_domain_token
        begin
          @tenant.generate_domain_verification_token
          
          render json: { 
            verification_token: @tenant.domain_verification_token,
            message: 'Verification token generated'
          }
        rescue => e
          Rails.logger.error "Generate token error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            error: Rails.env.development? ? e.message : 'Failed to generate token'
          }, status: :unprocessable_entity
        end
      end
      
      # GET /api/platform/tenants/:id/check_domain_dns
      def check_domain_dns
        begin
          if @tenant.custom_domain.blank?
            return render json: { error: 'No custom domain configured' }, status: :unprocessable_entity
          end
          
          result = @tenant.check_domain_verification
          
          render json: result
        rescue => e
          Rails.logger.error "Check domain DNS error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            success: false,
            error: Rails.env.development? ? e.message : 'Failed to check domain DNS'
          }, status: :internal_server_error
        end
      end
      
      # POST /api/platform/tenants/:id/verify_domain
      def verify_domain
        begin
          if @tenant.custom_domain.blank?
            return render json: { error: 'No custom domain configured' }, status: :unprocessable_entity
          end
          
          result = @tenant.verify_domain!
          
          if result[:success]
            render json: { 
              tenant: serialize_tenant(@tenant, detailed: true),
              message: result[:message],
              verified: true
            }
          else
            render json: { 
              error: result[:error],
              details: result[:details],
              verified: false
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "Verify domain error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            error: Rails.env.development? ? e.message : 'Failed to verify domain',
            verified: false
          }, status: :unprocessable_entity
        end
      end
      
      # POST /api/platform/tenants/:id/generate_email_dns_records
      def generate_email_dns_records
        begin
          if @tenant.email_domain.blank?
            return render json: { error: 'No email domain configured' }, status: :unprocessable_entity
          end
          
          # Generate DKIM selector and keys
          dkim_selector = "mail"
          dkim_public_key = "v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC..." # Placeholder
          
          # Generate DNS records
          dns_records = [
            {
              type: 'TXT',
              name: '@',
              value: 'v=spf1 include:_spf.landlordinsight.com ~all',
              purpose: 'SPF - Authorizes our servers to send email from your domain',
              priority: 1
            },
            {
              type: 'TXT',
              name: "#{dkim_selector}._domainkey",
              value: dkim_public_key,
              purpose: 'DKIM - Cryptographic signature for email authentication',
              priority: 2
            },
            {
              type: 'TXT',
              name: '_dmarc',
              value: 'v=DMARC1; p=none; rua=mailto:dmarc@landlordinsight.com',
              purpose: 'DMARC - Email authentication policy',
              priority: 3
            },
            {
              type: 'MX',
              name: '@',
              value: 'mail.landlordinsight.com',
              priority: 10,
              purpose: 'MX - Mail server for receiving email (optional)'
            }
          ]
          
          render json: { 
            email_domain: @tenant.email_domain,
            dns_records: dns_records,
            instructions: {
              step1: 'Log in to your domain registrar or DNS provider',
              step2: 'Add the DNS records listed above',
              step3: 'Wait 24-48 hours for DNS propagation',
              step4: 'Click Verify to check your configuration'
            }
          }
        rescue => e
          Rails.logger.error "Generate email DNS error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            error: Rails.env.development? ? e.message : 'Failed to generate DNS records'
          }, status: :unprocessable_entity
        end
      end
      
      # GET /api/platform/tenants/:id/check_email_dns
      def check_email_dns
        begin
          if @tenant.email_domain.blank?
            return render json: { error: 'No email domain configured' }, status: :unprocessable_entity
          end
          
          result = @tenant.check_email_dns_records
          
          render json: result
        rescue => e
          Rails.logger.error "Check email DNS error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            success: false,
            error: Rails.env.development? ? e.message : 'Failed to check email DNS'
          }, status: :internal_server_error
        end
      end
      
      # POST /api/platform/tenants/:id/verify_email_domain
      def verify_email_domain
        begin
          if @tenant.email_domain.blank?
            return render json: { error: 'No email domain configured' }, status: :unprocessable_entity
          end
          
          result = @tenant.verify_email_domain!
          
          if result[:success]
            render json: { 
              tenant: serialize_tenant(@tenant, detailed: true),
              message: result[:message],
              verified: true,
              records: result[:records]
            }
          else
            render json: { 
              error: result[:error],
              verified: false,
              records: result[:records]
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "Verify email domain error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            error: Rails.env.development? ? e.message : 'Failed to verify email domain',
            verified: false
          }, status: :unprocessable_entity
        end
      end
      
      # POST /api/platform/tenants/:id/send_owner_invitation
      # Send the tenant owner invitation (for delayed invitations)
      def send_owner_invitation
        begin
          # Find the pending tenant invitation
          invitation = @tenant.invitations
                              .where(invitation_type: 'tenant')
                              .where(status: 'pending')
                              .order(created_at: :desc)
                              .first
          
          unless invitation
            return render json: { 
              error: 'No pending invitation found for this tenant' 
            }, status: :not_found
          end
          
          # Use InvitationService to resend (generates new token and sends)
          invitation_service = InvitationService.new(
            invited_by: current_user,
            company: @tenant
          )
          
          # Resend will regenerate token and send the invitation
          result = invitation_service.resend_invitation(invitation.id)
          
          if result[:success]
            # Reload to get updated sent_at timestamp
            invitation.reload
            
            render json: {
              success: true,
              invitation: {
                id: invitation.id,
                email: invitation.email,
                status: invitation.status,
                sent_at: invitation.sent_at || invitation.last_sent_at
              },
              message: 'Tenant owner invitation sent successfully'
            }
          else
            render json: {
              success: false,
              error: result[:error]
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "Send owner invitation error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            error: Rails.env.development? ? e.message : 'Failed to send invitation'
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/platform/tenants/:id/update_owner_invitation
      # Update or create the tenant owner invitation details (email, phone, name)
      def update_owner_invitation
        begin
          # Find the most recent tenant invitation (accepted or pending)
          invitation = @tenant.invitations
                              .where(invitation_type: 'tenant')
                              .order(created_at: :desc)
                              .first
          
          # Build full name from first and last
          recipient_name = [params[:first_name], params[:last_name]].compact.join(' ').strip
          recipient_name = nil if recipient_name.empty?
          
          # If no invitation exists, CREATE one (don't send yet)
          unless invitation
            Rails.logger.info "No invitation found for tenant #{@tenant.id}, creating new invitation"
            
            if params[:email].blank?
              return render json: { 
                error: 'Email is required to create an invitation' 
              }, status: :unprocessable_entity
            end
            
            # Use InvitationService to create invitation
            invitation_service = InvitationService.new(
              invited_by: current_user,
              company: @tenant
            )
            
            # Determine delivery method
            delivery_method = params[:phone].present? ? 'both' : 'email'
            
            # Create invitation (don't send yet - skip_send: true)
            result = invitation_service.create_invitation(
              invitation_type: 'tenant',
              email: params[:email],
              phone: params[:phone],
              recipient_name: recipient_name || params[:email].split('@').first.capitalize,
              role: 'tenant',
              permissions: [],
              delivery_method: delivery_method,
              message: "You've been invited to set up your company account for #{@tenant.name}.",
              skip_send: true  # Don't send yet - just create the record
            )
            
            if result[:success]
              invitation = result[:invitation]
              Rails.logger.info "✅ Created invitation for tenant #{@tenant.name}: ID #{invitation.id}"
              
              return render json: {
                success: true,
                invitation: tenant_owner_invitation_status(@tenant),
                message: 'Owner invitation created successfully (not sent yet)'
              }
            else
              return render json: { 
                error: result[:error] 
              }, status: :unprocessable_entity
            end
          end
          
          # Invitation exists - UPDATE it
          # Prepare update parameters
          update_params = {}
          update_params[:email] = params[:email] if params[:email].present?
          update_params[:phone] = params[:phone] if params[:phone].present?
          update_params[:recipient_name] = recipient_name if recipient_name.present?
          
          if update_params.empty?
            return render json: { 
              error: 'No update parameters provided' 
            }, status: :unprocessable_entity
          end
          
          if invitation.update(update_params)
            render json: {
              success: true,
              invitation: tenant_owner_invitation_status(@tenant),
              message: 'Owner invitation updated successfully'
            }
          else
            render json: { 
              error: invitation.errors.full_messages.join(', ') 
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "Update owner invitation error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
          render json: { 
            error: Rails.env.development? ? e.message : 'Failed to update invitation'
          }, status: :unprocessable_entity
        end
      end
      
      private
      
      def create_tenant_subscription(tenant, plan_id, billing_cycle, start_trial)
        plan = SubscriptionPlan.find(plan_id)
        
        subscription = TenantSubscription.new(
          company: tenant,
          subscription_plan: plan,
          billing_cycle: billing_cycle,
          status: start_trial && plan.trial_enabled? ? 'trial' : 'active'
        )
        
        if start_trial && plan.trial_enabled?
          subscription.trial_ends_at = plan.trial_days.days.from_now
        end
        
        # Set period dates
        subscription.current_period_start = Time.current
        subscription.current_period_end = billing_cycle == 'annual' ? 1.year.from_now : 1.month.from_now
        
        if subscription.save
          Rails.logger.info "✅ Created subscription for tenant #{tenant.name}: Plan #{plan.display_name}"
          
          # Update tenant's legacy subscription_tier field for backward compatibility
          tenant.update_columns(subscription_tier: plan.category)
          
          subscription
        else
          Rails.logger.error "❌ Failed to create subscription: #{subscription.errors.full_messages.join(', ')}"
          raise StandardError, subscription.errors.full_messages.join(', ')
        end
      end
      
      def update_tenant_subscription(tenant, plan_id, billing_cycle = nil)
        plan = SubscriptionPlan.find(plan_id)
        subscription = tenant.tenant_subscription
        
        if subscription.present?
          # Update existing subscription
          updates = { subscription_plan_id: plan.id }
          updates[:billing_cycle] = billing_cycle if billing_cycle.present?
          
          # If switching plans, update period end based on new billing cycle
          if billing_cycle.present? && billing_cycle != subscription.billing_cycle
            updates[:current_period_end] = billing_cycle == 'annual' ? 1.year.from_now : 1.month.from_now
          end
          
          if subscription.update(updates)
            Rails.logger.info "✅ Updated subscription for tenant #{tenant.name}: Plan changed to #{plan.display_name}"
            
            # Update tenant's legacy subscription_tier field for backward compatibility
            tenant.update_columns(subscription_tier: plan.category)
            
            subscription
          else
            Rails.logger.error "❌ Failed to update subscription: #{subscription.errors.full_messages.join(', ')}"
            raise StandardError, subscription.errors.full_messages.join(', ')
          end
        else
          # No existing subscription - create one
          Rails.logger.info "No existing subscription found for tenant #{tenant.id}, creating new one"
          create_tenant_subscription(tenant, plan_id, billing_cycle || 'monthly', false)
        end
      end
      
      def create_tenant_owner(tenant, send_now: false)
        # Use InvitationService to create proper invitation
        invitation_service = InvitationService.new(
          invited_by: current_user, 
          company: tenant
        )
        
        # Determine delivery method based on whether phone is provided
        delivery_method = tenant_params[:owner_phone].present? ? 'both' : 'email'
        
        # Build recipient name
        recipient_name = [
          tenant_params[:owner_first_name],
          tenant_params[:owner_last_name]
        ].compact.join(' ').presence || tenant_params[:owner_email].split('@').first.capitalize
        
        # Create invitation (send immediately only if send_now is true)
        result = invitation_service.create_invitation(
          invitation_type: 'tenant',
          email: tenant_params[:owner_email],
          phone: tenant_params[:owner_phone],
          recipient_name: recipient_name,
          role: 'tenant',
          permissions: [],
          delivery_method: delivery_method,
          message: "You've been invited to set up your company account for #{tenant.name}.",
          skip_send: !send_now  # NEW: Skip sending unless send_now is true
        )
        
        if result[:success]
          invitation = result[:invitation]
          Rails.logger.info "✅ Tenant invitation created for #{tenant.name}: ID #{invitation.id}"
          
          if Rails.env.development?
            puts "\n" + "="*80
            puts "TENANT INVITATION CREATED"
            puts "="*80
            puts "Email: #{invitation.email}"
            puts "Phone: #{invitation.phone || 'Not provided'}"
            puts "Tenant: #{tenant.name}"
            puts "Role: Tenant Owner (Full Admin)"
            puts "Delivery: #{delivery_method.titleize}"
            puts "Invitation ID: #{invitation.id}"
            puts "Check invitation URL via: /api/public/invitations/verify?token=XXX"
            puts "="*80 + "\n"
          end
        else
          error_msg = "Failed to create tenant invitation: #{result[:error]}"
          Rails.logger.error "❌ #{error_msg}"
          raise StandardError, result[:error]
        end
        
        invitation
      end
      
      def set_tenant
        @tenant = ::Company.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Tenant not found' }, status: :not_found
      end
      
      def tenant_params
        params.require(:tenant).permit(
          :name,
          :subdomain,
          :custom_domain,
          :email_domain,
          :phone,
          :email,
          :address_line1,
          :address_line2,
          :city,
          :state,
          :zip_code,
          :country,
          :status,
          :trial_ends_at,
          :subscription_tier,
          :max_users,
          :max_storage_gb,
          :zoho_subscription_id,
          :zoho_customer_id,
          :external_payments_id,
          :owner_email,
          :owner_first_name,
          :owner_last_name,
          :owner_phone,
          :send_invitation,  # NEW: Allow sending invitation immediately
          :sms_provisioning_mode,  # Phase 0: platform/dedicated/disabled
          :industry,               # Industry classification — drives labels + module visibility
          # New subscription params (extracted separately in create)
          :subscription_plan_id,
          :billing_cycle,
          :start_trial
        )
      end
      
      def serialize_tenant(tenant, detailed: false)
        base = {
          id: tenant.id,
          name: tenant.name,
          subdomain: tenant.subdomain,
          custom_domain: tenant.custom_domain,
          domain_verified: tenant.domain_verified?,
          status: tenant.status || 'active',
          subscription_tier: tenant.subscription_tier,
          users_count: tenant.users.count,
          sms_provisioning_mode: tenant.try(:sms_provisioning_mode) || 'platform',
          industry: tenant.try(:industry),
          created_at: tenant.created_at,
          updated_at: tenant.updated_at
        }
        
        # Include subscription info if tenant has a subscription
        if tenant.respond_to?(:tenant_subscription) && tenant.tenant_subscription.present?
          sub = tenant.tenant_subscription
          plan = sub.subscription_plan
          
          base[:subscription] = {
            plan_id: plan.id,
            plan_name: plan.name,
            plan_display_name: plan.display_name,
            status: sub.status,
            billing_cycle: sub.billing_cycle,
            current_period_end: sub.current_period_end,
            zoho_subscription_id: sub.zoho_subscription_id
          }
          
          base[:limits] = {
            max_users: plan.max_users,
            max_storage_gb: plan.max_storage_gb,
            max_locations: plan.max_locations,
            current_users: sub.current_users || 0,
            current_storage_gb: sub.current_storage_gb || 0,
            current_locations: sub.current_locations || 0
          }
        end
        
        if detailed
          base.merge!(
            email_domain: tenant.email_domain,
            email_domain_verified: tenant.email_domain_verified?,
            domain_verified_at: tenant.domain_verified_at,
            email_domain_verified_at: tenant.email_domain_verified_at,
            trial_ends_at: tenant.trial_ends_at,
            max_users: tenant.max_users,
            max_storage_gb: tenant.max_storage_gb,
            users_count: tenant.users.count,
            users_remaining: tenant.remaining_user_slots,
            zoho_subscription_id: tenant.zoho_subscription_id,
            zoho_customer_id: tenant.zoho_customer_id,
            external_payments_id: tenant.external_payments_id,
            domain_verification_token: tenant.domain_verification_token,
            primary_domain: tenant.custom_domain || tenant.subdomain,
            subdomain_url: tenant.subdomain_url,
            owner_invitation: tenant_owner_invitation_status(tenant)  # NEW: Add invitation status
          )
          
          # Include module access for detailed view
          if tenant.respond_to?(:module_access)
            base[:modules] = tenant.modules_with_status
          end

          base[:company_profile] = Setting.get('Company', tenant.id, 'company_profile') || {}
        end
        
        base
      rescue => e
        Rails.logger.error "Serialize error for tenant #{tenant.id}: #{e.message}"
        {
          id: tenant.id,
          name: tenant.name || 'Unknown',
          subdomain: tenant.subdomain,
          custom_domain: nil,
          domain_verified: false,
          status: 'active',
          subscription_tier: nil,
          users_count: 0,
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      
      def tenant_owner_invitation_status(tenant)
        invitation = tenant.invitations
                           .where(invitation_type: 'tenant')
                           .order(created_at: :desc)
                           .first
        
        return nil unless invitation
        
        # Parse recipient_name into first and last name
        name_parts = (invitation.recipient_name || '').split(' ', 2)
        first_name = name_parts[0] || ''
        last_name = name_parts[1] || ''
        
        {
          id: invitation.id,
          email: invitation.email,
          phone: invitation.phone,
          recipient_name: invitation.recipient_name,
          first_name: first_name,
          last_name: last_name,
          status: invitation.status,
          sent_at: invitation.sent_at,
          accepted_at: invitation.accepted_at,
          can_send: invitation.status == 'pending' && invitation.sent_at.nil?
        }
      end
    end
  end
end
