# frozen_string_literal: true
Rails.application.routes.draw do
  # ==================== TENANT WEBSITES (CUSTOM HOSTNAMES) ====================
  #
  # FIRST on purpose. Cloudflare for SaaS forwards the visitor's original Host, so a dealer
  # site arrives on the dealer's own hostname and has to win the root path, which the API
  # root below would otherwise claim.
  #
  # Safe to sit here because the constraint is doubly restrictive: it matches only hosts
  # that resolve to a published tenant website, and it refuses reserved path prefixes
  # (/api, /webhooks, /rails, tracking links) so a dealer hostname can never swallow API or
  # webhook traffic. Platform hostnames short-circuit before any database lookup.
  constraints(Constraints::TenantWebsiteHost) do
    get '/robots.txt', to: 'public/sites#robots', format: false
    get '/sitemap.xml', to: 'public/sites#sitemap', format: false
    get '/', to: 'public/sites#show', as: :tenant_website_root
    get '*path', to: 'public/sites#show', format: false, as: :tenant_website_page
  end

  # Health check
  get 'up', to: 'rails/health#show', as: :rails_health_check

  # Root
  root to: proc { [200, {}, ['Renter Insight API']] }
  
  # Serve uploaded files (logos, images, etc.) - Legacy URLs without /api prefix
  get 'uploads/*path', to: 'api/uploads#show', format: false
  
  # Public tokenized SMS reply links — no authentication required
  get  'r/:token',       to: 'sms_replies#show'
  post 'r/:token/reply', to: 'sms_replies#reply'

  # Public tokenized tracked-link redirects (nurture/campaign attachments)
  get 't/:token', to: 'public/tracked_links#show', as: :tracked_link_redirect

  # ==================== PUBLIC CHAMPION LEAD ACCEPT/DECLINE (No Auth Required) ====================
  # One-click Accept/Decline links sent in the Champion lead notification email.
  scope '/cl' do
    get  ':token/accept',  to: 'public/champion_lead_actions#accept',       as: :public_champion_lead_accept
    get  ':token/decline', to: 'public/champion_lead_actions#decline_form', as: :public_champion_lead_decline_form
    post ':token/decline', to: 'public/champion_lead_actions#decline',      as: :public_champion_lead_decline
  end

  # ==================== PUBLIC AGREEMENT SIGNING (No Auth Required) ====================
  get  'sign/:token',          to: 'public/agreement_signing#show'
  post 'sign/:token/view',    to: 'public/agreement_signing#view_agreement'
  post 'sign/:token/sign',    to: 'public/agreement_signing#sign'
  post 'sign/:token/decline', to: 'public/agreement_signing#decline'
  get  'sign/:token/download', to: 'public/agreement_signing#download'

  # Inbound workflow triggers (no auth — token-based)
  namespace :api do
    namespace :webhooks do
      post 'inbound/:token', to: 'inbound_workflow_triggers#trigger'
    end
  end

  # ==================== WEBHOOKS (NO AUTH REQUIRED) ====================
  namespace :webhooks do
    # Email tracking pixel (no auth required)
    get 'email/:communication_id/pixel.gif', to: 'email_tracking#pixel', as: :email_pixel
  end
  
  # Inbound email webhook (separate namespace - singular)
  namespace :webhook do
    # Inbound email handling (BCC capture + reply tracking)
    post 'inbound_mail/handle', to: 'inbound_mail#handle'
  end
  
  # Legacy route aliases (for existing SNS subscription)
  post 'webhooks/inbound_mail/process', to: 'webhook/inbound_mail#handle'
  post 'webhooks/inbound_mail/handle', to: 'webhook/inbound_mail#handle'
  
  # Other webhooks (plural namespace)
  namespace :webhooks do
    # Twilio SMS status callbacks (Twilio signature verification)
    post 'twilio/sms/status', to: 'twilio#sms_status'
    post 'twilio/sms/inbound', to: 'twilio#sms_inbound'
    
    # Zego payment webhooks
    post 'zego/processed', to: 'zego#processed'
    post 'zego/canceled', to: 'zego#canceled'
    
    # QuickBooks webhooks
    post 'quickbooks/notifications', to: 'quickbooks#notifications'

    # Stripe Financial Connections webhooks (signature-verified, no auth)
    post 'stripe', to: 'stripe#receive'

    # Facebook Lead Ads webhooks
    get  'facebook/leads', to: 'facebook_leads#verify'
    post 'facebook/leads', to: 'facebook_leads#receive'

    # SES bounce/complaint/delivery notifications via SNS (signature-verified, no auth)
    post 'ses/events', to: 'ses_events#receive'
  end

  # ==================== PUBLIC INTAKE FORMS ====================
  scope path: 'f', module: 'public', as: 'public' do
    get ':public_id', to: 'forms#show', as: :form
    post ':public_id/submit', to: 'forms#submit', as: :form_submit
  end
  
  # ==================== PUBLIC BROCHURES ====================
  get '/b/:public_id', to: 'api/v1/brochures#public_view', as: :public_brochure
  
  # ==================== PUBLIC LISTING VIEW ====================
  get '/l/:id', to: 'api/v1/listings#public_view', as: :public_listing
  
  # ==================== PUBLIC BLOG (No Auth Required) ====================
  get 'api/public/websites/:token/blog', to: 'api/public/blog_posts#index'
  get 'api/public/websites/:token/blog/categories', to: 'api/public/blog_posts#categories'
  get 'api/public/websites/:token/blog/:slug', to: 'api/public/blog_posts#show'
  
  # ==================== PUBLIC SYNDICATION FEEDS ====================
  namespace :public do
    get 'feeds/:id', to: 'syndication_feeds#show', as: :syndication_feed
    
    # ==================== PUBLIC INVENTORY (Vehicle Catalog) ====================
    resources :inventory, only: [:index, :show], controller: 'inventory' do
      collection do
        get :filters  # Get available filter options
      end
    end

    # ==================== PUBLIC LAND PARCELS ====================
    resources :land_parcels, only: [:index, :show], controller: 'land_parcels' do
      collection do
        get :filters
      end
    end
  end
  
  # ==================== PUBLIC QUOTES ====================
  get '/q/:token', to: 'api/public/quotes#show', as: :public_quote
  post '/q/:token/accept', to: 'api/public/quotes#accept', as: :public_quote_accept
  post '/q/:token/reject', to: 'api/public/quotes#reject', as: :public_quote_reject
  
  # ==================== PUBLIC WARRANTY CLAIMS ====================
  get '/w/:token', to: 'api/public/warranty_claims#show', as: :public_warranty_claim
  post '/w/:token/respond', to: 'api/public/warranty_claims#respond', as: :public_warranty_claim_respond
  
  # ==================== PUBLIC INVOICES ====================
  get '/invoice/:token', to: 'public/invoices#show', as: :public_invoice
  get '/invoice/:token/pdf', to: 'public/invoices#pdf', as: :public_invoice_pdf
  
  # API endpoints for public forms (for frontend)
  namespace :api do
    # ==================== PUBLIC INVITATIONS (No Auth Required) ====================
    namespace :public do
      get 'invitations/verify', to: 'invitations#verify_token'
      post 'invitations/accept', to: 'invitations#accept'

      # ==================== PUBLIC CONFIGURATION VIEWING ====================
      get 'configurations/:token', to: 'configurations#show', as: :public_configuration

      # ==================== PUBLIC CONFIGURATOR (Anonymous Builder) ====================
      scope 'configurator/:subdomain' do
        get 'info', to: 'configurator#company_info'
        get 'floor-plans', to: 'configurator#floor_plans'
        get 'floor-plans/:id', to: 'configurator#floor_plan_detail'
        post 'submit', to: 'configurator#submit'
      end
    end
    
    # ==================== PUBLIC INVOICE PAYMENTS (No Auth Required) ====================
    namespace :v1 do
      namespace :public do
        resources :invoice_payments, only: [], param: :token do
          member do
            get '', action: :show
            post :process_payment
          end
        end
      end
    end

    # ==================== PUBLIC PROJECT PROGRESS (No Auth Required) ====================
    namespace :v1 do
      namespace :public do
        get 'project-progress/:token', to: 'project_progress#show', as: :public_project_progress
        # Customer approval gate actions (token-scoped, no auth)
        post 'project-progress/:token/reviews/:assignment_id/approve',          to: 'project_progress#approve'
        post 'project-progress/:token/reviews/:assignment_id/request_revision', to: 'project_progress#request_revision'
        post 'project-progress/:token/reviews/:assignment_id/reject',           to: 'project_progress#reject'
      end
    end

    scope path: 'f' do
      get ':public_id', to: '/public/forms#show'
      post ':public_id/submit', to: '/public/forms#submit'
    end
    
    # ==================== V1 API ====================
    namespace :v1 do
      # Lightweight auth/token health check
      get 'health/ping', to: 'health#ping'

      # ==================== CATALOG SUBSCRIPTIONS (Surface A — dealer opt-in) ====================
      resources :catalog_subscriptions, only: %i[index create destroy]

      # ==================== TRACKED LINKS (Attachment Engagement) ====================
      resources :tracked_links, only: %i[index show] do
        collection do
          get :prospect_interest
        end
      end

      # ==================== IMPORT / EXPORT ENGINE ====================
      resources :import_jobs, only: %i[index show create destroy] do
        member do
          post :preview
          post :start
          post :rollback
        end
      end
      resources :import_templates, only: %i[index show create update destroy]
      resources :export_jobs, only: %i[index show create] do
        member { get :download }
      end
      scope path: 'import_export', controller: 'import_export_metadata' do
        get 'modules',                       action: :modules
        get 'modules/:module_type/fields',    action: :fields
        get 'modules/:module_type/sample_csv', action: :sample_csv
      end

      # ==================== DEAL DESK ====================
      scope path: 'deal_desk' do
        # Config dropdowns (read-only) for the desk workspace.
        resources :lender_programs, only: [:index], controller: 'deal_desk_lender_programs'
        resources :fee_templates,   only: [:index], controller: 'deal_desk_fee_templates'
        resources :fni_products,    only: [:index, :create, :update, :destroy], controller: 'deal_desk_fni_products'

        resources :scenarios, only: %i[index show create update destroy],
                              controller: 'deal_desk_scenarios' do
          collection do
            post :solve     # reverse-solve a lever for a target payment
            post :compare   # comparable-unit matching + ranking
            post :grid      # payment matrix: engine-computed cell per (term, cash_down) pair
            post :ai_solve  # AI interprets intent; engine computes; returns ranked options
          end
          member do
            post :select          # flag selected (single per deal); does NOT mutate the deal
            post :apply           # deliberately write the structure back to the deal
            post :apply_unit_swap   # MANAGER ONLY: swap this unit onto the deal (captures baseline)
            post :revert_unit_swap  # MANAGER ONLY: undo a swap, restore the deal's baseline
            post :generate_quote  # turn the selected scenario into a Quote
            post :transfer_unit   # MANAGER ONLY: commit a cross-location unit
            get  :summary, defaults: { format: 'pdf' }  # /scenarios/:id/summary.pdf
          end
        end

        # Public-token scenario shares (customer-facing SMS/email leave-behind).
        # Authenticated create; the show endpoint is public (skip_before_action in
        # DealDeskSharesController) so the customer can hit it from an SMS link
        # without an account. The `:token` constraint allows base64url characters.
        resources :shares, only: [:create], controller: 'deal_desk_shares' do
          collection do
            post :preview  # dry-run: build the same customer payload without persisting
          end
        end
        get 'shares/:token', to: 'deal_desk_shares#show', constraints: { token: /[A-Za-z0-9_\-]+/ }
      end

      # ==================== AI REPORT QUERY ====================
      scope 'report-ai', as: 'report_ai' do
        post 'ask',               to: 'report_ai#ask'
        post 'classify',          to: 'report_ai#classify'
        post 'execute',           to: 'report_ai#execute'
        post 'contextual',        to: 'report_ai#contextual'
        get  'usage',             to: 'report_ai#usage'
        get  'suggested',         to: 'report_ai#suggested'
        get  'history',           to: 'report_ai#history'
        get  'platform-insights', to: 'report_ai#platform_insights'
        post 'trigger-digest',    to: 'report_ai#trigger_digest'
        post 'refresh-digest',     to: 'report_ai#refresh_digest'
        get  'digest-drilldown',   to: 'report_ai#digest_drilldown'
        get  'failure-log',        to: 'report_ai#failure_log'
      end

      # ==================== COMPANY SETTINGS (OPERATIONAL) ====================
      scope path: 'company_settings', controller: 'company_settings' do
        get 'operational', action: :show_operational
        patch 'operational', action: :update_operational
        get 'company_profile', action: :show_company_profile
        patch 'company_profile', action: :update_company_profile
        get 'project_management', action: :show_project_management
        patch 'project_management', action: :update_project_management
        get 'branding', action: :show_branding
        patch 'branding', action: :update_branding
        get 'communication', action: :show_communication
        patch 'communication', action: :update_communication
        patch 'rbac', action: :update_rbac
        get 'loan', action: :show_loan
        patch 'loan', action: :update_loan
        get 'service_warranty_policy', action: :show_service_warranty_policy
        patch 'service_warranty_policy', action: :update_service_warranty_policy
        get 'portal_modules', action: :show_portal_modules
        patch 'portal_modules', action: :update_portal_modules
        patch :save_communication_settings
        delete :clear_communication_settings
        get 'form_states', action: :show_form_states
        patch 'form_states', action: :update_form_states
        get 'tax_rate_for_state', action: :tax_rate_for_state
        get 'ai_settings', action: :ai_settings
        patch 'ai_settings', action: :update_ai_settings
        get 'embed_inventory_config', action: :show_embed_inventory_config
        patch 'embed_inventory_config', action: :update_embed_inventory_config
      end
      
      # ==================== GLOBAL SEARCH ====================
      get 'search/global', to: 'search#global'
      # Typeahead for related-record pickers — the five linkable types, each
      # result carrying its parent ids so one pick fills the rest of the ladder.
      get 'search/related', to: 'search#related'

      # ==================== COMPANIES (Platform Admin) ====================
      scope path: 'companies', controller: 'companies' do
        get 'accessible', action: :accessible
        get ':id/locations', action: :locations
      end
      
      # ==================== NOTES ====================
      resources :notes, only: [:index, :create, :update, :destroy]

      # ==================== ACTIVITY LOGS ====================
      resources :activity_logs, only: [:index] do
        collection do
          get :my_activity
          get 'account/:account_id', action: :account_feed, as: :account_feed
          get 'entity/:trackable_type/:trackable_id', action: :entity_feed, as: :entity_feed
          get :stats
        end
      end
      
      # ==================== USER SETTINGS ====================
      scope path: 'user_settings', controller: 'user_settings' do
        get 'profile'
        patch 'profile', action: 'update_profile'
        post 'change_password'
        post 'test_digest'
        get 'security'
        patch 'security', action: 'update_security'
        get 'login_activity'
        get 'notifications'
        patch 'notifications', action: 'update_notifications'
      end
      
      # ==================== USER EMAIL CONNECTIONS ====================
      resources :user_email_connections, path: 'user-email-connections' do
        member do
          post :test
          post :set_default
          post :send_verification
        end
        collection do
          get :check_domain
          post :verify  # Token-based verification (no auth on token itself)
        end
      end
      
      # ==================== SETTINGS (Public Inventory) ====================
      namespace :settings do
        patch :company
        post :regenerate_public_inventory_token
      end

      # ==================== COMPANY LABELS ====================
      scope path: 'company', controller: 'labels' do
        get    'labels',         action: :show
        put    'labels',         action: :update
        patch  'labels',         action: :update
        post   'labels/reset',   action: :reset
        delete 'labels/:key',    action: :destroy
      end

      # ==================== CONVERSION TRACKING ====================
      # Company default + per-location overrides for public-form ad tracking.
      scope path: 'company', controller: 'tracking_settings' do
        get   'tracking-settings', action: :show
        put   'tracking-settings', action: :update
        patch 'tracking-settings', action: :update
      end

      # Field-level tooltip overrides (system + custom fields). Same shape as
      # labels — see Api::V1::FieldTooltipsController.
      scope path: 'company', controller: 'field_tooltips' do
        get    'field-tooltips',                          action: :index
        put    'field-tooltips',                          action: :update
        patch  'field-tooltips',                          action: :update
        post   'field-tooltips/reset',                    action: :reset
        delete 'field-tooltips/:module/:field_key',       action: :destroy, constraints: { module: /[^\/]+/, field_key: /[^\/]+/ }
      end
      
      # ==================== NOTIFICATIONS ====================
      resources :notifications, only: [:index, :show, :destroy] do
        collection do
          get :unread_count
          patch :mark_all_read
          delete :bulk_destroy
          post :bulk_mark_read
          post :broadcast
          post :preview_recipients
          get :stats
          post :test  # Test notification endpoint
        end
        member do
          patch :mark_as_read
          patch :mark_as_unread
          get 'attachments/:attachment_id', action: :download_attachment, as: :download_attachment
        end
      end
      
      resources :notification_preferences, path: 'notification-preferences' do
        collection do
          patch :bulk_update
          post :reset_defaults
          patch 'category/:category', action: :update_category
        end
      end
      
      # Notification Settings (Unified Reminder System)
      resource :notification_settings, only: [:show, :update], path: 'notification_settings'
      
      # ==================== TASKS ====================
      resources :tasks do
        member do
          post :complete
          post :reopen
        end
        
        collection do
          get :stats
        end
      end

      # ==================== WORKFLOW AUTOMATION ====================
      resources :workflow_rules do
        collection do
          post :preview_unsaved, path: 'preview'
          post :ai_generate
          post :ai_accept
          post :ai_refine
        end
        member do
          post :activate
          post :pause
          post :resume
          post :archive
          post :validate
          post :preview
          get  :runs
        end
      end
      resources :workflow_runs, only: [:index, :show] do
        member do
          post :cancel
          post :retry
          get  :steps
        end
      end
      resources :workflow_events, only: [:index]
      resources :workflow_templates, only: [:index, :show] do
        member do
          post :activate
        end
      end
      resources :workflow_approvals, only: [:index, :show] do
        member do
          post :approve
          post :reject
        end
      end
      resources :workflow_inbound_triggers
      get 'workflow_metrics', to: 'workflow_metrics#index'
      get 'workflow_field_options', to: 'workflow_field_options#index'

      # ==================== PROJECTS ====================
      resources :projects do
        collection do
          get :summary
          get :grid
        end
        member do
          post :advance_phase
          post :undo_advance
          post :set_phase_status
          post :skip_phase
          post :toggle_task   # POST body: { phase_id:, task_id: }
          post :assign_phase_task_contractor     # POST body: { phase_id:, task_id:, contractor_id: }
          delete :unassign_phase_task_contractor  # DELETE body: { phase_id:, task_id:, contractor_id: }
          post :assign_phase_task_user            # POST body: { phase_id:, task_id:, user_id: }
          delete :unassign_phase_task_user        # DELETE body: { phase_id:, task_id: }
          get :export_pdf
          post :flush_assignment_notifications
          post :pause_assignment_notifications
          post :resume_assignment_notifications
          post :skip_assignment_notification
          post :unskip_assignment_notification
        end
        # Nested phase tasks (CRUD only — toggle uses project member action above)
        resources :phases, only: [:create, :update], controller: 'project_phases' do
          collection do
            post :reorder
          end
          resources :tasks, controller: 'project_phase_tasks', only: [:index, :create, :update, :destroy]
          # Phase 2A: Rich project tasks (with checklists, dependencies, etc.)
          resources :project_tasks, controller: 'project_tasks', only: [:index, :create] do
            collection do
              post :reorder
            end
          end
          # Work logs on phase tasks (dealer ↔ contractor bidirectional)
          resources :phase_tasks, controller: 'phase_task_work_logs', only: [] do
            member do
              get :work_logs, action: :index
              post :work_logs, action: :create
            end
          end
        end

        # Phase 2A: Project tasks (show/update/destroy at project level)
        resources :project_tasks, controller: 'project_tasks', only: [:show, :update, :destroy], as: :project_task_detail do
          member do
            patch :update_status
            post :assign_contractor
            delete :unassign_contractor
          end

          resources :checklists, controller: 'project_task_checklists', only: [:create, :update, :destroy] do
            member do
              post :add_item
            end
          end

          resources :checklist_items, controller: 'project_task_checklists', only: [] do
            member do
              patch :toggle_item
              delete :delete_item
            end
          end
        end

        # Phase 2A: Notification preferences
        resources :notification_preferences, controller: 'project_notification_preferences', only: [:index, :create, :update, :destroy] do
          collection do
            post :auto_setup
          end
        end

        # Phase 2D: Cost tracking, materials, documents
        resources :cost_items, controller: 'project_cost_items' do
          collection do
            get :summary
          end
        end

        resources :materials, controller: 'project_material_usages' do
          member do
            post :check_out
            post :mark_used
            post :return_parts
          end
          collection do
            get :search_parts
          end
        end

        resources :documents, controller: 'project_documents'
      end

      # Phase 2A: Offline sync
      post 'offline_sync', to: 'offline_sync#create'

      resources :project_templates, path: 'project-templates' do
        member do
          post :duplicate
        end
      end

      # ==================== CALENDAR ====================
      scope path: 'calendar', controller: 'calendar' do
        get 'events'
        get 'views', action: :available_views
        get 'stats'
      end
      
      # ==================== DASHBOARD ====================
      scope path: 'dashboard', controller: 'dashboard' do
        get 'presets', action: :presets
        get 'layout/:preset_id', action: :layout
        post 'layout/:preset_id', action: :save_layout
        delete 'layout/:preset_id', action: :reset_layout
        get 'metrics/:card_type', action: :metrics
      end
      
      # ==================== WORKQUEUE ====================
      get 'workqueue/summary', to: 'workqueue#summary'
      get 'workqueue/items',   to: 'workqueue#items'

      # ==================== SERVICE TICKETS ====================
      resources :service_tickets, path: 'service-tickets' do
        member do
          post :upload_attachments, path: 'upload-attachments'
          patch 'attachments/:attachment_id/audience', action: :set_attachment_audience
          post :mark_warranty_suspected, path: 'mark-warranty-suspected'
          post :mark_warranty, path: 'mark-warranty'
          post :unmark_warranty, path: 'unmark-warranty'
          post :set_line_billing, path: 'set-line-billing'
          post :generate_customer_invoice, path: 'generate-customer-invoice'
          post :generate_warranty_claim, path: 'generate-warranty-claim'
          post :generate_both, path: 'generate-both'
          post :assign_contractor, path: 'assign-contractor'
          delete :unassign_contractor, path: 'unassign-contractor'
          post :resend_contractor_notification, path: 'resend-contractor-notification'
          get :contractor_notifications, path: 'contractor-notifications'
        end
        
        collection do
          get :stats
        end

        # Complaints. Each issue owns its own parts, labor and pay type.
        resources :issues, controller: 'service_ticket_issues', only: %i[index show create update destroy] do
          member do
            post :request_authorization, path: 'request-authorization'
            post :record_authorization, path: 'record-authorization'
          end

          collection do
            post :reorder
          end
        end
      end

      # ==================== SERVICE ISSUE TEMPLATES ====================
      resources :service_issue_templates, path: 'service-issue-templates',
                                          only: %i[index create update destroy] do
        collection do
          post :reorder
        end
      end

      # ==================== VENDORS (unified contractors + suppliers) ====================
      resources :vendors

      # ==================== CONTRACTORS ====================
      resources :contractors do
        member do
          post :sms_consent, path: 'sms-consent'
          # Dealer generates a portal code to read to the contractor directly,
          # for when email and SMS don't arrive.
          post :portal_access_code, path: 'portal-access-code'
        end

        collection do
          get :stats
          get :vendors
        end

        resources :contractor_assignments, only: [:index, :create, :update, :destroy]
      end

      # Contractor Reviews (dealer-side approval workflow)
      resources :contractor_reviews, path: 'contractor-reviews', only: [:index, :show] do
        member do
          post :approve
          post :request_revision
          post :reject
          post :act_on_behalf  # Dealer records the customer's decision on their behalf
        end
      end

      # ==================== WARRANTY SYSTEM ====================
      # Manufacturers
      resources :manufacturers, only: [:index, :show]
      
      # Warranty Claims
      resources :warranty_claims, path: 'warranty-claims' do
        member do
          post :submit
          post :approve
          post :deny
          post :request_more_info
          post :resubmit
          post :reopen
          post :close
          post :record_payment
          post :add_note, path: 'notes'
          get :public_link
        end
        collection do
          get :stats
        end
      end
      
      # Manufacturer AR Transactions
      resources :manufacturer_ar_transactions, path: 'manufacturer-ar-transactions' do
        member do
          post :mark_short_paid
          post :write_off
        end
        collection do
          get :stats
        end
      end
      
      # Manufacturer AR Payments
      resources :manufacturer_ar_payments, path: 'manufacturer-ar-payments' do
        member do
          post :upload_attachments
        end
      end
      
      # ==================== WEBSITE BUILDER ====================
      # Landing pages are WebsitePages with page_kind 'landing', so they inherit
      # domains, SSL, host resolution and SSR from the website builder. Separate
      # controller because the surface differs: publish state, campaign linkage,
      # bound forms and cloning, rather than a page inside a site tree.
      resources :landing_pages, only: %i[index show create update destroy] do
        member do
          post :publish
          post :unpublish
          post :duplicate
          post :clone_to_locations
        end
      end

      # Site Content Profiles — scan a client's existing site into reusable
      # content. Projection into templates happens on the frontend, where the
      # templates live.
      resources :site_content_profiles, only: %i[index show create update destroy] do
        member do
          post :rotate_preview_token
        end
        collection do
          get 'by_token/:token', action: :by_token  # PUBLIC - shareable preview
        end
      end

      resources :websites do
        member do
          post :publish
          post :unpublish
          post :sync_branding  # Sync branding from Company/Location settings
        end
        
        collection do
          get :stats
          get :branding_preview  # Preview branding before sync
          get :showcase_inventory  # Own inventory, or a demo lot, for the design showcase
          get 'by_token/:token', action: :by_token  # ⭐ PUBLIC - Preview website by token
          get 'by_slug_public/:slug', action: :by_slug_public  # ⭐ PUBLIC - Preview website by slug (Safari compatible)
          get 'by_slug/:slug', action: :by_slug  # Authenticated preview by slug
        end
        
        # Website Pages (nested under websites)
        resources :pages, controller: 'website_pages' do
          member do
            post :show_page, path: 'show'
            post :hide_page, path: 'hide'
            post :reorder
          end
          
          collection do
            post :bulk_reorder
          end
        end
        
        # Website Media (nested under websites)
        resources :media, controller: 'website_media'
        
        # Blog Posts (nested under websites)
        resources :blog_posts, path: 'blog/posts', controller: 'blog_posts' do
          member do
            post :publish
            post :unpublish
            post :schedule
            post :increment_views
          end
        end
        
        # Blog Categories (nested under websites)
        resources :blog_categories, path: 'blog/categories', controller: 'blog_categories' do
          collection do
            post :bulk_reorder
          end
        end
      end
      
      # Global media endpoints (not nested under websites)
      resources :media, controller: 'website_media', only: [:show, :update, :destroy] do
        collection do
          get :stats
        end
      end
      
      # ==================== CHAMPION IMS FEED INTEGRATION ====================
      # Note: catalog browsing was removed - sync writes directly to vehicles table
      # with source='champion_ims', so synced homes appear in regular inventory list.
      namespace :champion_ims, path: 'champion_ims' do
        resources :retailers do
          member do
            post :sync_now
          end
          # Read-only history of sync runs + per-home events
          resources :sync_runs, only: %i[index show]
        end
      end

      # ==================== CHAMPION LEADS API INTEGRATION ====================
      # Polls Champion's Retailer API for leads, supports accept/decline workflow.
      # Config CRUD + accept/decline/refresh actions on individual leads.
      namespace :champion_leads, path: 'champion-leads' do
        resources :configs do
          member do
            post :test_connection
            post :sync_now
          end
        end

        # Accept/decline/refresh actions on individual CRM leads
        scope 'actions/:id', controller: 'actions' do
          post :accept
          post :decline
          post :refresh
        end
      end

      # ==================== VEHICLES/INVENTORY ====================
      resources :vehicles do
        member do
          get :print
          get :max_advance  # Max Advance (lender cap) worksheet for this unit (invoice + applied items)
          get :service_tickets, path: 'service-tickets'  # Service history for this home (incl. dealer-only)
          post :clone
          post :share
          get :tags
          post :tags, to: 'vehicles#add_tags'
          delete 'tags/:tag_name', to: 'vehicles#remove_tag'
          post :post_to_accounting
        end
        
        collection do
          get :stats
          get :facets     # Distinct makes/years for the filter dropdowns
          get :export     # Add export route
          post :bulk_update
          post :bulk_delete
          post :import
        end
        
        # Vehicle image uploads. DELETE is collection-level (no :id) because images
        # live as URLs in the vehicles.images jsonb array — vehicle_images#destroy
        # removes by params[:url], not an attachment id.
        post   'images', to: 'vehicle_images#create'
        delete 'images', to: 'vehicle_images#destroy'

        # Vehicle documents (3-tier visibility: internal/customer/public)
        resources :documents, controller: 'vehicle_documents'

        # Internal-only manufacturer-invoice capture (Max Advance Phase 1).
        # Singular: one invoice per vehicle; create/update both upsert.
        # scan (Phase 5): vision-extract a DRAFT from a manufacturer invoice — never persists.
        resource :invoice, controller: 'vehicle_invoices', only: [:show, :create, :update] do
          post :scan
        end

        # Vehicle packages (Package Builder)
        resources :packages, controller: 'inventory_packages' do
          collection do
            post :reorder
            post :apply_template
          end
        end
      end
      
      # ==================== PACKAGE TEMPLATES ====================
      resources :package_templates do
        collection do
          post :reorder
        end
      end
      
      # ==================== LISTINGS ====================
      resources :listings do
        member do
          post :publish
          post :unpublish
        end
        
        collection do
          get :stats
        end
      end
      
      # ==================== PAYMENT METHODS ====================
      resources :payment_methods, path: 'payment-methods' do
        member do
          patch :set_default
          post :verify
        end
        
        collection do
          get :stats
        end
      end
      
      # Alias for underscore version (some frontend components use payment_methods)
      get 'payment_methods', to: 'payment_methods#index', as: 'payment_methods_underscore_list'
      get 'payment_methods/:id', to: 'payment_methods#show', as: 'payment_methods_underscore_show'
      post 'payment_methods', to: 'payment_methods#create', as: 'payment_methods_underscore_create'
      patch 'payment_methods/:id', to: 'payment_methods#update', as: 'payment_methods_underscore_update'
      delete 'payment_methods/:id', to: 'payment_methods#destroy', as: 'payment_methods_underscore_destroy'
      patch 'payment_methods/:id/set_default', to: 'payment_methods#set_default', as: 'payment_methods_underscore_set_default'
      post 'payment_methods/:id/verify', to: 'payment_methods#verify', as: 'payment_methods_underscore_verify'
      get 'payment_methods/stats', to: 'payment_methods#stats', as: 'payment_methods_underscore_stats'
      
      # ==================== PAYMENTS ====================
      resources :payments do
        member do
          post :cancel
          post :refund
          post :void
        end
        
        collection do
          get :stats
          get :export
        end
      end
      
      # ==================== INVOICES ====================
      resources :invoices do
        member do
          post :send_invoice
          post :send_sms
          post :mark_paid
          post :cancel
          post :finalize
          get :pdf
          get :draw_schedule_pdf
          post :mark_inventory_used, path: 'mark-inventory-used'  # Manual inventory override
        end
        
        collection do
          get :stats
          post :convert_from_quote, path: 'convert-from-quote'  # Quote → Invoice conversion
        end
      end

      resources :draw_schedule_templates do
        member do
          post :set_default
          get :preview
        end
      end

      resources :invoice_terms_templates do
        member do
          post :set_default
        end
      end

      resources :invoice_notes_templates do
        member do
          post :set_default
        end
      end
      
      # ==================== LOANS ====================
      resources :loans do
        member do
          post :activate
          post :mark_defaulted, path: 'mark-defaulted'
          post :record_payment, path: 'record-payment'
          post :record_manual_payment, path: 'record-manual-payment'
          get :documents
          post :documents, action: :upload_documents
          delete 'documents/:document_id', action: :destroy_document
          get :amortization_data, path: 'amortization-data'
        end
        
        collection do
          get :stats
          post :calculate_schedule, path: 'calculate-schedule'
          get :search_borrowers, path: 'search-borrowers'
        end
      end
      
      # ==================== BROCHURES ====================
      resources :brochures do
        member do
          post :share
        end
        
        collection do
          get :stats
          get :templates
          post :bulk_share
        end
      end
      
      # ==================== BROCHURE TEMPLATES ====================
      resources :brochure_templates, path: 'brochure-templates', only: [:index, :show, :create, :update, :destroy]
      
      # ==================== COMPANY DOMAINS (CUSTOM DOMAINS) ====================
      resources :company_domains, path: 'company-domains' do
        collection do
          get :hostname_advice, path: 'hostname-advice'
        end
        member do
          post :verify
          post :check_dns, path: 'check-dns'
          post :activate
          post :deactivate
          # SES sending identity
          post :enable_email, path: 'enable-email'
          post :check_email, path: 'check-email'
          post :disable_email, path: 'disable-email'
          get  :domain_connect, path: 'domain-connect'
        end
      end
      
      # ==================== RBAC ROLES ====================
      resources :roles do
        member do
          get :permissions
          put :permissions, action: :set_permissions
          post :clone
          post :toggle_visibility
        end
        
        collection do
          get :system, action: :system_roles, as: :system
        end
      end
      
      # ==================== RBAC RESOURCES ====================
      resources :resources, only: [:index, :show, :create, :update, :destroy]
      
      # ==================== RBAC ACTIONS ====================
      resources :actions, only: [:index, :show, :create, :update, :destroy]
      
      # ==================== RBAC SCOPES ====================
      resources :scopes, only: [:index, :show, :create, :update, :destroy]
      
      # ==================== RBAC PERMISSIONS ====================
      scope path: 'permissions', controller: 'permissions' do
        get 'check', action: :check
        get 'user/:user_id', action: :user_permissions
        post 'bulk_check', action: :bulk_check
      end
      
      # ==================== COMPANIES ====================
      resources :companies, only: [] do
        collection do
          get :accessible
        end
      end
      
      # ==================== LOCATIONS ====================
      resources :locations do
        collection do
          get :accessible
        end
        
        member do
          post :restore
          get :users
          get :available_users, path: 'available-users'
          post :assign_user, path: 'assign-user'
          delete 'remove_user/:user_id', action: :remove_user, as: :remove_user
          get :metrics
          get :stats
          get :activities
          patch :save_communication_settings
          delete :clear_communication_settings
        end
        
        collection do
          get :stats
          post :bulk_activate
          post :bulk_deactivate
          post :bulk_delete
        end
        
        # ==================== BANK ACCOUNTS (Nested under Locations) ====================
        resources :bank_accounts, path: 'bank-accounts', only: [:index, :create, :update, :destroy] do
          member do
            post :sync_to_zego, path: 'sync-to-zego'
            patch :update_display, path: 'update-display'
          end
        end
        
        # ==================== LOCATION MANUFACTURERS (Warranty System) ====================
        resources :manufacturers, only: [:index, :create, :update, :destroy], controller: 'locations/manufacturers'
      end
      
      # ==================== LAND MANAGEMENT ====================
      resources :land_parcels, path: 'land-parcels' do
        collection do
          get :stats
          get :export
          post :bulk_delete
        end
      end
      
      # ==================== USERS (COMPANY USERS) ====================
      resources :users, only: %i[index show create update destroy] do
        member do
          post :restore
          post :reset_mfa
          get :mfa_status
          get :locations, action: :user_locations
          post :assign_location, path: 'assign-location'
          delete 'remove_location/:location_id', action: :remove_location, as: :remove_location
        end

        collection do
          get :assignable  # Get users filtered by context (service, sales, finance, etc.)
          post :bulk_activate
          post :bulk_deactivate
          get 'me/signature', action: :my_signature
          put 'me/signature', action: :update_my_signature
        end
      end
      
      # ==================== ACTIVITIES ====================
      
      # ==================== MFA (Multi-Factor Authentication) ====================
      scope path: 'mfa', controller: 'mfa' do
        # Shared MFA routes
        get 'status', action: :status
        post 'disable', action: :disable
        
        # TOTP routes (keep existing)
        post 'enroll', action: :enroll
        post 'verify', action: :verify
        post 'backup_codes/regenerate', action: :regenerate_backup_codes
        
        # SMS routes (new - parallel to TOTP)
        post 'sms/enroll', action: :sms_enroll
        post 'sms/verify', action: :sms_verify
        post 'sms/resend', action: :sms_resend
        post 'sms/disable', action: :sms_disable
      end
      get 'activities/recent', to: 'activities#recent'
      
      # ==================== QUOTES ====================
      resources :quotes do
        member do
          post :send, to: 'quotes#send_quote'
          post :accept
          post :reject
          get :pdf
          get :tags
          post :tags, to: 'quotes#add_tags'
          delete 'tags/:tag_name', to: 'quotes#remove_tag'
          post :mark_parts_used, path: 'mark-parts-used'
        end
        
        collection do
          get :stats
          get :export
          get :search_parts, path: 'search-parts'
        end
        
        # Quote Inventory Usages (Parts tracking)
        resources :quote_inventory_usages, only: [:index, :create, :destroy], path: 'inventory-usages' do
          member do
            post :mark_used, path: 'mark-used'
          end
        end
      end
      
      # Account activity reminders (for marking as sent)
      post 'account_activities/:id/mark_reminder_sent', to: 'account_activities#mark_reminder_sent'
      
      # Contact activity reminders (for marking as sent)
      post 'contact_activities/:id/mark_reminder_sent', to: 'contact_activities#mark_reminder_sent'
      
      # ==================== COMMISSIONS ====================
      resources :commissions do
        member do
          post :approve
          post :reject
          post :mark_paid, path: 'mark-paid'
          get :audit_trail, path: 'audit-trail'
        end
        
        collection do
          get :stats
          post :calculate
        end
      end
      
      # ==================== COMMISSION PLANS ====================
      resources :commission_plans, path: 'commission-plans' do
        member do
          post :activate
          post :deactivate
          get :components
          get :available_components, path: 'available-components'
          post :add_component, path: 'add-component'
          delete 'remove-component/:component_id', to: 'commission_plans#remove_component'
          patch :reorder_components, path: 'reorder-components'
        end
        
        collection do
          get :stats
        end
      end
      
      # ==================== COMMISSION COMPONENTS ====================
      resources :commission_components, path: 'commission-components' do
        member do
          post :toggle
          post :calculate  # Test calculation with sample deal
        end
        
        collection do
          get :options  # Get dropdown options for form
        end
      end
      
      # ==================== COMMISSION PAYMENTS ====================
      resources :commission_payments, path: 'commission-payments' do
        member do
          post :approve
          post :mark_paid, path: 'mark-paid'
          post :reverse
          post :undo_reversal, path: 'undo-reversal'
          get :statement
        end
        
        collection do
          get :my_commissions, path: 'my-commissions'
          get :stats
          get :dashboard
          get :reports_data, path: 'reports-data'
          post :export
          post :bulk_approve, path: 'bulk-approve'
          post :bulk_mark_paid, path: 'bulk-mark-paid'
          post :bulk_mark_paid_detailed, path: 'bulk-mark-paid-detailed'
          post :generate_for_deal, path: 'generate-for-deal'
          get 'preview-for-deal/:deal_id', action: :preview_for_deal, as: :preview_for_deal
        end
      end
      
      # ==================== COMMISSION RULES ====================
      resources :commission_rules, path: 'commission-rules' do
        member do
          post :calculate
        end
      end

      # ==================== BUDGETS ====================
      resources :budgets do
        member do
          post :lock
          post :unlock
          post :activate
          post :deactivate
          post :archive
          get  :variance_report, path: 'variance-report'
          get  :pl_overview,     path: 'pl-overview'
        end
        collection do
          post :copy_from_prior_year, path: 'copy-from-prior-year'
          post :wizard
          post :ai_suggest, path: 'ai-suggest'
          post :rebuild_consolidated, path: 'rebuild-consolidated'
          get  :data_coverage, path: 'data-coverage'
          get  :stats
        end
      end
      
      # ==================== PORTAL USERS ====================
      resources :portal_users, path: 'portal_users' do
        member do
          post :generate_proxy_token
        end
        collection do
          get :stats
          post :password_reset
          post :invite
        end
      end
      
      # ==================== PARTS & INVENTORY MODULE ====================
      # Manufacturers
      resources :manufacturers do
        member do
          get :parts
        end
        collection do
          get :stats
          get :autocomplete
        end
      end
      
      # Part Categories
      resources :part_categories, path: 'part-categories' do
        collection do
          get :tree
        end
      end
      
      # Parts
      resources :parts do
        member do
          get :stock_by_location, path: 'stock-by-location'
          get :transaction_history, path: 'transaction-history'
          post :upload_image, path: 'upload-image'
          delete 'delete-image/:image_index', action: :delete_image, as: :delete_image
        end
        collection do
          get :stats
          get :export  # Export parts to CSV
          get :autocomplete  # Autocomplete suggestions
          get :find_by_identifier  # Get full part details by SKU/Barcode
          get :manufacturer_names  # List all manufacturer names with counts
          post :rename_manufacturer  # Rename manufacturer across all parts
          delete :delete_manufacturer  # Delete if unused
          post :rename_part_name  # Rename part name across all parts
          delete :delete_part_name  # Delete if unused
        end
      end
      
      # Company-level dealer-installed item defaults (Max Advance two-tier system, tier 1).
      # Seeded from 21st Mortgage; copied to each new lender as its starting schedule.
      resources :company_allowance_defaults,
                only: [:index, :show, :create, :update, :destroy] do
        collection do
          post :seed          # idempotent (re)seed of 21st defaults
          post :sync_lenders  # push defaults to lenders missing them (gap-fill only)
        end
      end

      # Lenders (lightweight managed list for the deal quick-add dropdown + Finance settings)
      resources :lenders do
        # Max Advance Phase 2 — per-lender calculation schedule (Finance settings).
        resources :allowance_items, controller: 'lender_allowance_items',
                  only: [:index, :show, :create, :update, :destroy]
        resources :deletion_items, controller: 'lender_deletion_items',
                  only: [:index, :show, :create, :update, :destroy]
        # Singular: one markup/VEP config per lender; create/update both upsert.
        resource :markup_config, controller: 'lender_markup_configs',
                 only: [:show, :create, :update]
      end

      # Suppliers
      resources :suppliers do
        member do
          get :parts
        end
        collection do
          get :stats
        end
      end
      
      # Purchase Orders
      resources :purchase_orders, path: 'purchase-orders' do
        member do
          post :send_to_supplier, path: 'send'
          post :cancel
          get :receiving_history, path: 'receiving-history'
          post :post_to_accounting
        end
        collection do
          get :stats
        end
      end
      
      # Bins
      resources :bins do
        collection do
          get :stats
          post :transfer
        end
      end
      
      # Inventory Transactions
      resources :inventory_transactions, path: 'inventory-transactions', only: [:index, :show] do
        collection do
          post :receive
          post :transfer
          post :adjust
          post :consume
          post :return, action: :return_inventory
        end
      end
      
      # Stock Balances
      resources :stock_balances, path: 'stock-balances', only: [:index] do
        collection do
          get :summary
          get 'by_part/:part_id', action: :by_part, as: :by_part
          get 'by_location/:location_id', action: :by_location, as: :by_location
        end
        member do
          post :reserve
          post :release
        end
      end
      
      # Reorder Rules
      resources :reorder_rules, path: 'reorder-rules' do
        collection do
          get :needs_reorder, path: 'needs-reorder'
        end
      end
      
      # ==================== HOME CONFIGURATOR ====================
      resources :floor_plans, path: 'floor-plans', only: [:index, :show]
      resources :company_floor_plans, path: 'company-floor-plans', only: [:index, :show, :create, :update, :destroy]
      resources :configurations do
        member do
          post :calculate_price, path: 'calculate-price'
          post :share
        end
      end

      # ==================== CONTACTS ====================
      resources :contacts do
        member do
          get :tags, to: 'contacts#tags'  # Get tags for contact
          post :tags, to: 'contacts#add_tags'
          delete 'tags/:tag_name', to: 'contacts#remove_tag'
          patch :opt_in_email, to: 'contacts#opt_in_email'
          patch :opt_out_email, to: 'contacts#opt_out_email'
          patch :opt_in_sms, to: 'contacts#opt_in_sms'
          patch :opt_out_sms, to: 'contacts#opt_out_sms'
          get :deals
          get :quotes
          get :portal_status
          get :documents
          post :documents, action: :upload_documents
        end
        
        collection do
          get :stats
          post :bulk_create
          post :check_duplicate
          post :check_duplicates
          post :quick_create
          # Bulk add tags across the whole filtered set (select-all-matching),
          # not just the visible page. Accepts contact_ids OR filter.
          post :bulk_add_tags
        end

        # Contact Communications
        resources :communications, controller: 'contact_communications', only: [:index] do
          collection do
            post :email
            post :sms
            post :log
          end
        end
        
        # Contact Activities
        resources :activities, controller: 'contact_activities' do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        
        # Contact Nurture
        get 'nurture', to: 'contact_nurture#index'
        post 'nurture/enroll', to: 'contact_nurture#enroll'
        post 'nurture/:enrollment_id/pause', to: 'contact_nurture#pause'
        post 'nurture/:enrollment_id/resume', to: 'contact_nurture#resume'
        post 'nurture/:enrollment_id/unenroll', to: 'contact_nurture#unenroll'
      end
      
      # ==================== REPORTS ====================
      resources :reports do
        collection do
          post :run
          get :modules
          get :fields
        end
        member do
          post :share
          delete :unshare
          get :export
        end
      end

      # ==================== ACCOUNTS ====================
      resources :accounts do
        member do
          post :convert_to_customer
          get :tags, to: 'accounts#tags'  # Get tags for account
          post :tags, to: 'accounts#add_tags'
          delete 'tags/:tag_name', to: 'accounts#remove_tag'
          get :deals
          get :contacts  # Account contacts list
          get 'communications/rollup', to: 'accounts#communications_rollup'  # Communication rollup across all contacts
        end
        
        collection do
          get :stats
          get :industries
          get :export
          post :convert_lead
          post :bulk_update
          # Soft duplicate lookup for the New Account form (name/email/phone match).
          post :check_duplicates
        end
        
        # Nested resources for accounts
        resources :contacts, only: [:index], controller: 'contacts'
        resources :activities, controller: 'account_activities' do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        resources :messages, controller: 'account_messages', only: [:index, :create]
        
        # Account Communications
        resources :communications, controller: 'account_communications', only: [:index] do
          collection do
            post :email
            post :sms
            post :log
          end
        end
        
        member do
          get :insights
          get :score
        end
      end
      
      # ==================== OAUTH EMAIL CONNECTIONS ====================
      scope path: 'oauth-email', controller: 'oauth_email' do
        get  'authorize',   action: :authorize
        get  'callback',    action: :callback
        delete 'disconnect', action: :disconnect
      end

      # ==================== QUICKBOOKS INTEGRATION ====================
      namespace :integrations do
        scope path: 'quickbooks' do
          get 'authorize', to: 'quickbooks_oauth#authorize'
          get 'callback', to: 'quickbooks_oauth#callback'
          get 'status', to: 'quickbooks_oauth#status'
          delete 'disconnect', to: 'quickbooks_oauth#disconnect'
          post 'refresh_token', to: 'quickbooks_oauth#refresh_token'
          
          # Sync Routes - Use settings controller for these
          post 'sync/full', to: 'quickbooks_settings#sync_all_entities'
          post 'sync/incremental', to: 'quickbooks_sync#incremental'
          post 'sync/entity', to: 'quickbooks_settings#sync_entity'
          get 'sync/status', to: 'quickbooks_sync#status'
          get 'sync/logs', to: 'quickbooks_sync#logs'
          get 'sync/mappings', to: 'quickbooks_sync#mappings'
          delete 'sync/mappings/:id', to: 'quickbooks_sync#delete_mapping'
          post 'sync/mappings/:id/retry', to: 'quickbooks_sync#retry_mapping'
          
          get 'settings', to: 'quickbooks_settings#show'
          put 'settings', to: 'quickbooks_settings#update'
          delete 'settings', to: 'quickbooks_settings#destroy'
          get 'settings/accounts', to: 'quickbooks_settings#accounts'
          post 'settings/test', to: 'quickbooks_settings#test_connection'
          get 'settings/entity/:entity_type', to: 'quickbooks_settings#entity_settings'
          put 'settings/entity/:entity_type', to: 'quickbooks_settings#update_entity_settings'
          get 'settings/mappings', to: 'quickbooks_settings#field_mappings'
          post 'settings/mappings', to: 'quickbooks_settings#create_field_mapping'
          post 'settings/mappings/defaults', to: 'quickbooks_settings#create_default_mappings'
          put 'settings/mappings/:id', to: 'quickbooks_settings#update_field_mapping'
          delete 'settings/mappings/:id', to: 'quickbooks_settings#delete_field_mapping'
          get 'settings/sync_logs', to: 'quickbooks_settings#sync_logs'
          get 'settings/sync_logs/:id', to: 'quickbooks_settings#sync_log_details'
          
          # Chart of Accounts & Account Mapping
          get 'settings/chart_of_accounts', to: 'quickbooks_settings#chart_of_accounts'
          get 'settings/account_mappings', to: 'quickbooks_settings#account_mappings'
          put 'settings/account_mappings', to: 'quickbooks_settings#update_account_mappings'
          
          # Custom Fields & Custom Field Mapping
          get 'settings/custom_fields', to: 'quickbooks_settings#custom_fields'
          get 'settings/custom_field_mappings', to: 'quickbooks_settings#custom_field_mappings'
          put 'settings/custom_field_mappings', to: 'quickbooks_settings#update_custom_field_mappings'
          
          # QuickBooks Field Schemas (for dropdowns)
          get 'settings/quickbooks_fields', to: 'quickbooks_settings#quickbooks_fields'
          
          # Phase 4 Sync Endpoints - Manual Sync Operations
          post 'sync/entity', to: 'quickbooks_settings#sync_entity'
          post 'sync/all', to: 'quickbooks_settings#sync_all_entities'
        end

        # ==================== FACEBOOK INTEGRATION (OAuth) ====================
        scope path: 'facebook' do
          get    'authorize',    to: 'facebook#authorize'
          get    'callback',     to: 'facebook#callback'
          post   'connect_page', to: 'facebook#connect_page'
          get    'status',       to: 'facebook#status'
          get    'ad_accounts',  to: 'facebook#ad_accounts'
          post   'link_ad_account', to: 'facebook#link_ad_account'
          delete 'disconnect',   to: 'facebook#disconnect'
        end
      end

      # ==================== FACEBOOK INTEGRATIONS (CRUD) ====================
      resources :facebook_integrations, path: 'facebook-integrations' do
        member do
          post :refresh_token
          get  :lead_log
        end
      end

      # ==================== SOCIAL ACCOUNTS ====================
      resources :social_accounts, path: 'social-accounts' do
        member do
          post :refresh_token
          post :disconnect
        end
        collection do
          get :stats
        end
      end

      # ==================== SOCIAL POSTS ====================
      resources :social_posts, path: 'social-posts' do
        member do
          post :approve
          post :publish
          post :schedule
          post :duplicate
          get  :skip
          get  :email_approve
          get  :email_decline
        end
        collection do
          post :generate
          get  :intent_options
          get  :stats
          get  :seasonal_suggestions
        end
      end

      # ==================== SOCIAL POST SCHEDULES ====================
      resources :social_post_schedules, path: 'social-post-schedules' do
        member do
          post :activate
          post :pause
          post :test_approval_email
        end
        collection do
          get :preview
        end
      end

      # ==================== META CATALOG FEED (public) ====================
      get   'meta/catalog/:company_id/feed', to: 'meta_catalog#feed'
      get   'meta/catalog/info',             to: 'meta_catalog#info'
      post  'meta/catalog/regenerate_token', to: 'meta_catalog#regenerate_token'
      patch 'meta/catalog/settings',         to: 'meta_catalog#update_settings'

      # ==================== SOCIAL ATTRIBUTION DASHBOARD ====================
      get 'social/attribution',      to: 'social_attribution#index'
      get 'social/rep_leaderboard',  to: 'social_attribution#rep_leaderboard'
      get 'social/advisor',          to: 'social_attribution#advisor'

      # ==================== AD CAMPAIGNS ====================
      resources :ad_campaigns, path: 'ad-campaigns' do
        member do
          post :pause
          post :resume
          get  'ad-sets', action: :ad_sets
        end
        collection do
          post :launch
          post :sync
          get  :roi_summary
          get  'ad-options',     action: :ad_options
          get  'lead-forms',     action: :lead_forms
          get  'catalog-status', action: :catalog_status
        end
      end

      # ==================== SOCIAL MEDIA UPLOADS ====================
      post 'social-media/upload', to: 'social_media_uploads#create'

      # ==================== BRAND HEALTH ====================
      get 'brand-health', to: 'brand_health#show'

      # ==================== SOCIAL COMMENTS ====================
      resources :social_comments, path: 'social-comments' do
        member do
          post :reply
          post :hide
        end
        collection do
          post :mark_all_read
        end
      end

      # ==================== SOCIAL MEDIA SETTINGS ====================
      scope path: 'social-media-settings', controller: 'social_media_settings' do
        get    '', action: :show
        patch  '', action: :update
        put    '', action: :update
      end

      namespace :platform do
        resources :quickbooks_settings, only: [] do
          collection do
            get '', action: :show
            put '', action: :update
            get :stats
            get :companies
            get :logs
            post :sync_all
          end
        end
      end

      # Integration field map — mappable partner-API fields per module (+ custom
      # fields) for the "Export field map" action next to the API keys.
      get 'integration/field_map', to: 'integration_fields#field_map'

      # ==================== PARTNER API KEY MANAGEMENT ====================
      resources :api_keys, only: [:index, :show, :create, :update, :destroy], path: 'api-keys' do
        collection do
          get :available_resources
          post :bulk
        end
        member do
          post :revoke
        end
      end

      # ==================== WEBHOOK MANAGEMENT ====================
      resources :webhook_endpoints, only: [:index, :show, :create, :update, :destroy], path: 'webhook-endpoints' do
        collection do
          get :available_events
        end
        member do
          post :test
        end
        resources :deliveries, only: [:index, :show], controller: 'webhook_deliveries'
      end

      # ==================== CUSTOM FIELDS ====================
      resources :custom_fields, only: [:index, :create, :update, :destroy] do
        member do
          get :migrations
          post :migrations, action: :create_migrations
        end
        collection do
          get :migration_recommendations
        end
      end

      # ==================== CUSTOM FIELD FILE/IMAGE UPLOADS ====================
      resources :custom_field_uploads, only: [:create] do
        collection do
          delete :destroy, action: :destroy
        end
      end

      # ==================== ENTITY BUYERS (Co-Buyers, Guarantors, Cosigners) ====================
      resources :deals, only: [] do
        resources :buyers, controller: 'entity_buyers', only: [:index, :create, :update, :destroy]
      end
      resources :quotes, only: [] do
        resources :buyers, controller: 'entity_buyers', only: [:index, :create, :update, :destroy]
      end
      resources :invoices, only: [] do
        resources :buyers, controller: 'entity_buyers', only: [:index, :create, :update, :destroy]
      end

      # ==================== PAGE LAYOUTS ====================
      get 'page_layouts/:module_name', to: 'page_layouts#show'
      patch 'page_layouts/:module_name', to: 'page_layouts#update'
      post 'page_layouts/:module_name/reset', to: 'page_layouts#reset'
      get 'page_layouts/:module_name/field_definitions', to: 'page_layouts#field_definitions'

      # Field option overrides (company-specific dropdown customization)
      get 'page_layouts/:module_name/field_option_overrides', to: 'page_layouts#field_option_overrides'
      put 'page_layouts/:module_name/field_option_overrides/:field_key', to: 'page_layouts#update_field_option_override'
      delete 'page_layouts/:module_name/field_option_overrides/:field_key', to: 'page_layouts#delete_field_option_override'

      # ==================== AGREEMENTS & E-SIGN ====================
      resources :agreement_categories, only: [:index, :create, :update, :destroy]

      resources :agreement_templates do
        collection do
          get :ai_scan_usage, action: :ai_scan_usage_info
          post :multi_state_create
          patch :multi_state_update
          delete :delete_group
          get :state_groups
        end
        member do
          post :duplicate
          post :preview
          post :vision_scan
          get :cached_scan
          patch :save_scan_mappings
          delete :clear_scan_cache
          post :upload_example_document
          delete :remove_example_document
          post :smart_scan
          get 'custom_fields', to: 'agreement_templates#list_custom_fields'
          post 'custom_fields', to: 'agreement_templates#add_custom_field'
          post 'custom_fields/reorder', to: 'agreement_templates#reorder_custom_fields'
          post 'custom_fields/validate_formula', to: 'agreement_templates#validate_formula'
          patch 'custom_fields/:field_key', to: 'agreement_templates#update_custom_field'
          delete 'custom_fields/:field_key', to: 'agreement_templates#remove_custom_field'
        end
      end

      resources :agreements do
        collection do
          get :ai_scan_usage, to: 'agreements#ai_scan_usage_info'
        end
        member do
          post :send_agreement
          post :void
          post :remind
          post :remind_signer
          post :duplicate
          post :save_as_template
          get :audit_log
          get :download
          get :certificate
          post :prepare_signature
          put :preparer_sign
          post :calculate
          post :vision_scan
          post :upload_signed_document
          get 'custom_fields', to: 'agreements#list_custom_fields'
          post 'custom_fields', to: 'agreements#add_custom_field'
          post 'custom_fields/validate_formula', to: 'agreements#validate_formula_field'
          patch 'custom_fields/:field_key', to: 'agreements#update_custom_field'
          delete 'custom_fields/:field_key', to: 'agreements#remove_custom_field'
        end

        collection do
          get :stats
          get :entity_context
          post :preview_calculate
        end

        # Nested signers
        post 'signers', to: 'agreements#add_signer'
        patch 'signers/:signer_id', to: 'agreements#update_signer'
        delete 'signers/:signer_id', to: 'agreements#remove_signer'

        # Nested attachments
        post 'attachments', to: 'agreements#add_attachment'
        delete 'attachments/:attachment_id', to: 'agreements#remove_attachment'
      end

      # Agreement Documents (upload, delete, merge & merge preview)
      post 'agreement_documents/upload', to: 'agreement_documents#upload'
      delete 'agreement_documents', to: 'agreement_documents#delete'
      post 'agreement_documents/merge', to: 'agreement_documents#merge'
      post 'agreement_documents/merge_preview', to: 'agreement_documents#merge_preview'

      # Agreement Merge Fields (definitions)
      get 'agreement_merge_fields', to: 'agreement_merge_fields#index'

      # ==================== UNIFIED KNOWLEDGE BASE / SMART HELP ====================
      # Smart search + navigate + articles (read-only for end users).
      # Admin-side CRUD lives under api/admin/knowledge.
      scope :knowledge, controller: :knowledge do
        post   'search',                action: :search
        get    'navigate',              action: :navigate
        get    'articles',              action: :articles
        get    'articles/:slug',        action: :article, constraints: { slug: %r{[^/]+} }
        # IMPORTANT: generate must come before the :slug routes below so it
        # doesn't get caught as a slug.
        post   'articles/generate',     action: :generate_article
        post   'articles',              action: :create_article
        patch  'articles/:slug',        action: :update_article, constraints: { slug: %r{[^/]+} }
        delete 'articles/:slug',        action: :delete_article, constraints: { slug: %r{[^/]+} }
        post   'record_search',         action: :record_search
        get    'categories',            action: :categories
        post   'categories',            action: :manage_category
      end

      # Interactive guided tours (list/start/complete/step tracking).
      resources :tours, only: %i[index show create update destroy] do
        collection do
          get   :pause_state
          patch :pause_state, action: :set_pause_state
        end
        member do
          post :start
          post :complete
          post :step_complete
        end
      end

      # ==================== EMAIL CAMPAIGNS ====================
      resources :campaigns do
        collection do
          post :ai_generate
          post 'ai_generate/:generation_id/accept', action: :ai_accept, as: :ai_accept
          post 'ai_generate/:generation_id/refine', action: :ai_refine, as: :ai_refine
          get  'ai_generate/:generation_id/preview_render', action: :ai_preview_render, as: :ai_preview_render
          get :templates, to: 'campaign_templates#index'
          get :merge_fields
          get :audience_field_schema
        end
        member do
          post :duplicate
          post :start
          post :pause
          post :refine_with_ai
          post :resume
          post :archive
          post :test_send
          get :preview
          get :stats
          get :analytics_timeseries
          get :engagement
          get 'engagement/by_step', action: :engagement_by_step
          get 'engagement/by_link', action: :engagement_by_link
          get 'audience/members', action: :audience_members
          post 'audience/exclude_members', action: :exclude_audience_members
        end
        resource :audience, controller: 'campaign_audiences', only: [:create, :update] do
          post :preview
          post :recompute
          post :acknowledge_sms_compliance
        end
        resources :enrollments, controller: 'campaign_enrollments', only: [:index, :show] do
          member { post :unenroll }
        end
        resources :events, controller: 'campaign_events', only: [:index]
        resources :sends, controller: 'campaign_sends', only: [:index, :show]
        resources :steps, controller: 'campaign_steps', only: [:create, :update, :destroy] do
          member do
            post :upload_attachment
            delete :remove_attachment
            patch :update_attachment_mode
          end
        end
        resources :campaign_uploads, only: [:create], path: 'uploads' do
          collection do
            delete :destroy
          end
        end
      end

      resources :campaign_templates, only: [:index, :show] do
        member { post :instantiate }
      end

      resources :campaign_suppressions, only: [:index, :create, :destroy]

      resources :audiences do
        member do
          post :preview
          post :refresh
          post :archive
          post :unarchive
          get :members
          get :export, defaults: { format: 'csv' }
          post :add_members
          post :remove_members
        end
        collection do
          post :preview_dry_run
          post :ai_generate
          post :ai_refine
          post :ai_accept
        end
      end

      resources :email_senders, only: [:index]

      resources :location_email_connections, path: 'location-email-connections' do
        member do
          post :test
          post :set_default
          post :send_verification
        end
      end

      resource :company_email_connection, path: 'company-email-connection', only: [:show, :create, :update, :destroy] do
        member do
          post :test
          post :send_verification
        end
      end

      # ==================== ACCOUNTING MODULE ====================
      resources :chart_of_accounts do
        collection do
          post :import
        end
      end

      resources :journal_entries do
        member do
          post :void
          post :upload_attachment
          delete :delete_attachment
        end
      end

      resource :accounting_settings, only: [:show, :update] do
        get :tax_rates_for_state
      end

      resources :deal_approvals, only: [:show, :update] do
        collection do
          get :pending
          get :stats
          post :bulk_approve_commissions
        end
        member do
          post :approve
          post :approve_commission
        end
      end

      resources :fiscal_periods, only: [:index] do
        collection do
          post :generate
        end
        member do
          post :close
          post :reopen
        end
      end

      resources :account_links do
        collection do
          post :resolve
        end
      end

      get 'accounting/reports/trial_balance', to: 'accounting_reports#trial_balance'
      get 'accounting/reports/general_ledger', to: 'accounting_reports#general_ledger'
      get 'accounting/reports/profit_and_loss', to: 'accounting_reports#profit_and_loss'
      get 'accounting/reports/balance_sheet', to: 'accounting_reports#balance_sheet'
      get 'accounting/reports/ar_aging', to: 'accounting_reports#ar_aging'
      get 'accounting/reports/ap_aging', to: 'accounting_reports#ap_aging'
      get 'accounting/reports/source_entries', to: 'accounting_reports#source_entries'
      get 'accounting/reports/deal_profitability', to: 'accounting_reports#deal_profitability'
      get 'accounting/reports/floor_plan', to: 'accounting_reports#floor_plan'
      get 'accounting/reports/departmental_pnl', to: 'accounting_reports#departmental_pnl'
      get 'accounting/reports/sales_tax_summary', to: 'accounting_reports#sales_tax_summary'
      get 'accounting/reports/cash_flow_statement', to: 'accounting_reports#cash_flow_statement'
      get 'accounting/reports/cash_flow_forecast', to: 'accounting_reports#cash_flow_forecast'
      get 'accounting/dashboard', to: 'accounting_reports#dashboard'
      get 'accounting/locations', to: 'accounting_reports#accounting_locations'

      # Inventory Stock List & GP Snapshot (read-only)
      get 'inventory/reports/stock_list', to: 'inventory_reports#stock_list'
      # Salesperson GP Pipeline "Cheat Sheet" (read-only)
      get 'inventory/reports/salesperson_gp_pipeline', to: 'inventory_reports#salesperson_gp_pipeline'

      resources :deals, only: [] do
        member do
          post :record_payment, to: 'deal_payments#record_payment'
        end
        resource :accounting, controller: 'deal_accounting', only: [:show] do
          post :calculate
          post :post_closing
        end
      end

      resources :recurring_journal_entries do
        member do
          post :generate_now
        end
      end

      # ==================== BANKING & RECONCILIATION ====================
      resources :bank_accounts, only: [:index, :create, :update] do
        collection do
          get :check_enabled
        end
        resources :transactions, controller: 'bank_transactions', only: [:index, :show] do
          member do
            post :categorize
            post :match
            post :exclude
            post :unmatch
            get  :suggestions
          end
          collection do
            post :auto_match
            post :import_csv
            post :bulk_action
          end
        end
      end

      scope 'bank_accounts/:bank_account_id/feed', controller: 'bank_account_feeds' do
        post :create_session
        post :complete_connection
        post :sync
        post :disconnect
        get  :status
      end

      resources :bank_rules do
        collection do
          post :test
          post :create_from_transaction
        end
      end

      resources :bank_reconciliations do
        member do
          post :toggle_item
          post :clear_all
          post :unclear_all
          post :complete
          post :add_adjustment
          post :undo
        end
      end

      resources :recurring_bills do
        member do
          post :generate_now
        end
      end

      resources :bills do
        collection do
          post :bulk_action
          post :scan_receipt
        end
        member do
          post   :void
          post   :record_payment
          post   :upload_attachment
          delete :delete_attachment
        end
      end

      resources :cash_receipts, only: [:index, :show, :create, :destroy] do
      collection do
      get :open_invoices
      end
      member do
      post :void
      end
      end

      # Unassigned Location Items
      scope 'accounting/unassigned_items', controller: 'accounting/unassigned_items' do
        get '', action: :index
        get 'count', action: :count
        patch 'assign', action: :assign
      end

    # Year-End Close
      get 'accounting/year_end_close/preview', to: 'accounting_year_end_close#preview'
      post 'accounting/year_end_close/execute', to: 'accounting_year_end_close#execute'

      resources :record_transactions, only: [:create], path: 'record-transactions'

      resources :printed_checks, only: [:index, :create] do
        collection do
          post :print_batch
          post :reprint
          get  :check_settings
        end
        member do
          post :void
        end
      end

      resources :accounting_imports, only: [:index, :show] do
        collection do
          post :preview
          post :run_import
          post :parse_iif
          post :parse_csv
        end
      end

      scope :quickbooks, controller: :quickbooks do
        get    :authorize
        get    :callback
        post   :exchange_token
        get    :status
        delete :disconnect
        post   :sync
        get    :qb_accounts
        get    :sync_logs
        patch  :update_settings
      end
    end
  end

  # ==================== EMAIL CAMPAIGN TRACKING (PUBLIC) ====================
  get  '/t/:token',  to: 'campaign_tracking#click', as: :campaign_click
  get  '/u/:token',  to: 'campaign_tracking#unsubscribe_show', as: :campaign_unsubscribe_show
  post '/u/:token',  to: 'campaign_tracking#unsubscribe_confirm', as: :campaign_unsubscribe_confirm

  # "Refer a friend" — public, no-auth (the React page lives at /r/:token on the FE).
  get  '/api/referrals/:token', to: 'public/referrals#show',   as: :public_referral_show
  post '/api/referrals/:token', to: 'public/referrals#create', as: :public_referral_create

  # One-time setup endpoint for Render free tier
  namespace :api do
    get 'setup', to: 'setup#create'
    post 'setup', to: 'setup#create'
    get 'setup/sources', to: 'setup#create_sources'
    post 'setup/sources', to: 'setup#create_sources'
  end

  # Phase 5A - Unified Login Authentication
  namespace :api do
    namespace :auth do
      post 'login', to: 'login#create'
      post 'logout', to: 'login#destroy'
      post 'refresh', to: 'login#refresh'
      get 'verify', to: 'login#verify'
      get 'me', to: 'login#me'
      # Re-verify the signed-in user's own password (e.g. Deal Desk "Employee View" reveal).
      post 'verify_password', to: 'login#verify_password'

      # Password Reset
      post 'request_password_reset', to: 'password_reset#request_reset'
      post 'verify_reset_token', to: 'password_reset#verify_token'
      post 'reset_password', to: 'password_reset#reset_password'
      
      # Magic Link
      post 'request_magic_link', to: 'magic_link#request_magic_link'
      get 'verify_magic_link', to: 'magic_link#verify_magic_link'
      
      # MFA (Multi-Factor Authentication) - Login Flow
      scope path: 'mfa', controller: 'mfa' do
        post 'request_code'
        post 'verify_code'
        get 'settings'
        patch 'toggle'
      end
      
      # Impersonation (Platform Admin Only)
      post 'impersonate', to: 'impersonation#create'
      post 'stop_impersonation', to: 'impersonation#destroy'
      delete 'impersonation', to: 'impersonation#destroy'
      
      # Phase 6 - Token Management
      resource :tokens, only: [] do
        post :refresh, on: :collection
        post :validate, on: :collection
        delete :logout, on: :collection
      end
    end
    
    # MFA (Multi-Factor Authentication) - Phase 3: User Enrollment
    scope path: 'mfa' do
      # Status
      get 'status', to: 'mfa#status'
      
      # Enrollment
      post 'enroll/start', to: 'mfa#enroll_start'
      post 'enroll/verify', to: 'mfa#enroll_verify'
      
      # Backup Codes
      get 'backup-codes', to: 'mfa#backup_codes_status'
      post 'backup-codes/regenerate', to: 'mfa#regenerate_backup_codes'
      
      # Disable
      post 'disable', to: 'mfa#disable'
      
      # Login Verification (Phase 4)
      post 'verify-login', to: 'mfa#verify_login'
    end
    
    # Phase 6 - Unified Invitation System (User Invitations)
    # NOTE: Public invitation endpoints are declared at the top of the api namespace
    
    # Authenticated invitation endpoints
    resources :invitations, only: [:show, :destroy] do
      member do
        post :resend
      end
    end
    
    # Company-scoped invitations
    scope path: 'companies/:company_id' do
      get 'invitations', to: 'invitations#index'
      post 'invitations', to: 'invitations#create'
    end
  end

  # Mount ActionCable for WebSocket notifications
  mount ActionCable.server => '/cable'

  namespace :api, defaults: { format: :json } do
    # ==================== INVITATIONS (User Invitations) ====================
    # NOTE: Public invitation endpoints are declared at the top of the first api namespace (line ~26)
    
    # ==================== COMPANIES API ====================
    resources :companies, only: [] do
      resources :users, controller: 'companies/users' do
        collection do
          get :available_roles, path: 'available-roles'
          get :pending_invitations, path: 'pending-invitations'
          post :resend_all_invitations, path: 'resend-all-invitations'
        end
        
        member do
          post :resend_invitation
        end
      end
      
      # Alias invitations to users controller for frontend compatibility
      resources :invitations, controller: 'companies/users', only: [:index, :create] do
        member do
          post :resend, action: :resend_invitation
          delete '', action: :destroy
        end
      end
    end
    
    # ==================== SETTINGS API ====================
    get 'settings/tenant_basic', to: 'settings#tenant_basic'  # Basic tenant info for all authenticated users
    get 'settings/tenant', to: 'settings#tenant'  # Full tenant settings (requires company_settings permission)
    get 'settings/platform', to: 'settings#platform'  # Get platform defaults
    get 'settings/scoped', to: 'settings#show_scoped'  # Fetch a single setting by key + scope_type + scope_id
    get 'settings', to: 'settings#show_scoped'          # GET /api/settings?key=...&scope_type=...&scope_id=...
    patch 'settings', to: 'settings#update'
    put 'settings', to: 'settings#update'  # Support PUT for company settings
    delete 'settings', to: 'settings#destroy'  # Reset to platform defaults
    patch 'settings/branding', to: 'settings#update_branding'
    get 'settings/quotes', to: 'settings#quotes'
    patch 'settings/quotes', to: 'settings#update_quotes'
    get 'settings/pipeline_stages', to: 'settings#pipeline_stages'
    patch 'settings/pipeline_stages', to: 'settings#update_pipeline_stages'
    
    # Custom Fields
    get 'settings/custom_fields', to: 'settings#custom_fields'
    post 'settings/custom_fields', to: 'settings#create_custom_field'
    patch 'settings/custom_fields/:id', to: 'settings#update_custom_field'
    delete 'settings/custom_fields/:id', to: 'settings#destroy_custom_field'
    
    # ==================== UPLOADS API ====================
    get 'uploads/*path', to: 'uploads#show', format: false  # Serve uploaded files
    post 'uploads/logo', to: 'uploads#logo'
    post 'uploads', to: 'uploads#create'
    delete 'uploads', to: 'uploads#destroy'

    # ==================== CRM NAMESPACE ====================
    namespace :crm do
      # ==================== SOURCES ====================
      resources :sources, only: %i[index create update destroy] do
        member { get :stats }
        collection { get :stats }
      end

      # ==================== LEAD STATUSES ====================
      # Tenant-configurable lead status list (parallel to sources). Backs the
      # status dropdown on the lead form and the status filter on the lead list.
      resources :lead_statuses, only: %i[index create update destroy] do
        collection { post :reorder }
      end

      # ==================== TAGS ====================
      resources :tags, only: %i[index create update destroy] do
        member do
          get :analytics
        end
        collection do
          post :assign
          get 'entity/:entity_type/:entity_id', to: 'tags#entity_tags'
        end
      end
      delete 'tags/assignments/:id', to: 'tags#remove_assignment'

      # ==================== AI INSIGHTS (Non-Lead-Scoped) ====================
      resources :ai_insights, only: [] do
        member { post :mark_read }
      end

      # ==================== REMINDERS (Non-Lead-Scoped) ====================
      resources :reminders, only: [] do
        member do
          post :complete
          patch :complete
        end
      end

      # ==================== LEAD SCORES ====================
      resources :lead_scores, only: [] do
        collection do
          get ':lead_id', to: 'lead_scores#show'
          post ':lead_id/calculate', to: 'lead_scores#calculate'
        end
      end

      # ==================== COMMUNICATIONS (Non-Lead-Scoped) ====================
      # These routes accept lead_id in the request body
      post 'communications/email', to: 'communications#email'
      post 'communications/sms', to: 'communications#sms'

      # ==================== ACTIVITIES (Collection Endpoints) ====================
      # Collection endpoints for aggregating activities across all entities
      get 'leads/activities', to: 'activities#lead_activities'
      get 'accounts/activities', to: 'activities#account_activities'
      get 'contacts/activities', to: 'activities#contact_activities'
      get 'deals/activities', to: 'activities#deal_activities'

      # ==================== LEADS ====================
      resources :leads, only: %i[index show create update destroy] do
        collection do
          # Soft duplicate lookup for the New Lead form (email/phone match).
          post :check_duplicates

          # Bulk reassign — handles the "rep quit, move all of their leads" case in
          # one query. Accepts lead_ids OR filter (status_category/search/owner_id).
          post :bulk_reassign

          # Bulk add tags — "select all matching" tagging across every page, not
          # just the visible selection. Accepts lead_ids OR the same filter.
          post :bulk_add_tags

          # Bulk field update (status/owner) across the whole filtered set, not
          # just the visible page. Accepts lead_ids OR the same filter.
          post :bulk_update

          # Kanban view: leads grouped by status, capped per column.
          get :kanban
        end

        # Member routes (actions on specific lead)
        member do
          # Notes
          post :notes
          
          # Conversion
          post :convert
          
          # Scoring
          get :score, to: 'lead_scores#show'
          post 'score/calculate', to: 'lead_scores#calculate'

          # Health Score
          get  :health_score,              to: 'lead_scores#health_score'
          post :recalculate_health_score,  to: 'lead_scores#recalculate_health_score'
          get  :score_history,             to: 'lead_scores#score_history'

          # Custom field migration integrity check
          get :conversion_integrity_check
        end

        # Nested resources

        # Activities — aliased to LeadActivitiesController so
        # /api/crm/leads/:lead_id/activities/:id follows the same convention as
        # accounts/contacts (which point at their own *_activities controllers).
        # The previous declaration omitted `controller:` and defaulted to
        # Api::Crm::ActivitiesController, which is aggregation-only and has no
        # RESTful actions — every DELETE/POST/PATCH under this route 404'd with
        # AbstractController::ActionNotFound. Broke Task Center bulk-delete for
        # every lead-activity row (staging 291-row runaway couldn't be cleared).
        resources :activities, controller: 'lead_activities', only: %i[index create update destroy]

        # Communications
        resources :communications, only: %i[index create] do
          collection do
            post :send_email
            post :send_sms
          end
        end
        # Alternative communication routes
        post 'communications/email', to: 'communications#send_email'
        post 'communications/sms', to: 'communications#send_sms'

        # AI Insights
        resources :ai_insights, only: %i[index] do
          collection { post :generate }
        end
        # Alternative hyphenated routes for AI Insights
        get 'ai-insights', to: 'ai_insights#index'
        post 'ai-insights/generate', to: 'ai_insights#generate'

        # Reminders
        resources :reminders, only: %i[index create update destroy] do
          member do
            post :complete
            patch :complete
          end
        end

        # Tasks
        resources :tasks, only: %i[create update destroy], controller: 'lead_tasks'
        
        # Lead Activities (unified activities)
        resources :lead_activities, only: %i[index show create update destroy] do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end

        # Lead reminders endpoint (for activity notifications)
        get 'reminders/upcoming', to: 'lead_activities#reminders'
        post 'lead_activities/:id/mark_reminder_sent', to: 'lead_activities#mark_reminder_sent'

        # Tags (lead-scoped)
        get 'tags', to: 'tags#entity_tags_for_lead'
        post 'tags', to: 'tags#assign_to_lead'
        delete 'tags/:tag_id', to: 'tags#remove_from_lead'
      end

      # ==================== NURTURE ====================
      namespace :nurture do
        resources :sequences, only: %i[index create update destroy] do
          collection { post :bulk }
          resources :steps, only: %i[index create update destroy] do
            member do
              post :upload_attachment
              delete :remove_attachment
              post :send_test
            end
          end
        end

        resources :enrollments, only: %i[index create update destroy] do
          collection { post :bulk }
          member { post :trigger_step }
        end

        resources :templates, only: %i[index create update destroy] do
          collection { post :bulk }
          member { delete 'attachments/:attachment_id', to: 'templates#delete_attachment' }
        end

        # AI Template Generation
        resources :ai_templates, only: [] do
          collection do
            post :generate
            post :save
          end
        end

        # AI Sequence Generation
        resources :ai_sequences, only: [] do
          collection do
            post :generate
            post :save
          end
        end
      end

      # ==================== INTAKE ====================
      namespace :intake do
        resources :forms do
          collection do
            post :bulk
            get :lead_fields
          end
        end

        resources :submissions, only: %i[index create] do
          collection { post :bulk }
        end
      end

      # ==================== DEALS (SALES PIPELINE) ====================
      resources :deals, only: %i[index show create update destroy] do
        collection do
          get :metrics
          get :forecast
          get :by_stage
          get :owners
        end
        
        member do
          post :move_stage
          get :tags
          post :tags, to: 'deals#add_tags'
          delete 'tags/:tag_name', to: 'deals#remove_tag'
          get :commission_breakdown # Commission economics breakdown
          get :max_advance # Max Advance (lender cap) for this deal's vehicle (Phase 4a)
          post :max_advance # Same, but with CURRENT (unsaved) line items in the body for live preview
          get :financials # NEW: Get deal financials (permission-gated)
          patch :financials, to: 'deals#update_financials' # NEW: Update deal financials (permission-gated)
          get :service_tickets # NEW: Get service tickets for this deal
        end
        
        # Commission Payments (nested under deals)
        resources :commission_payments, only: [:index], controller: 'commission_payments', path: 'commissions' do
          collection do
            post :preview
          end
        end
        
        # Deal Activities (unified activities)
        resources :deal_activities, only: %i[index show create update destroy] do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        
        # Deal reminders endpoint (for activity notifications)
        post 'deal_activities/:id/mark_reminder_sent', to: 'deal_activities#mark_reminder_sent'
        
        # Nested resources for deals
        resources :products, only: %i[index show create update destroy], controller: 'deal_products' do
          collection do
            post :bulk_create
          end
        end
        
        resources :stage_histories, only: %i[index show create], controller: 'deal_stage_histories'
        
        resources :approvals, only: %i[index show create update destroy] do
          member do
            post :approve
            post :reject
            post :cancel
          end
        end
        
        # Win/Loss Report (singular resource - one per deal)
        resource :win_loss_report, only: %i[show create update destroy], controller: 'win_loss_reports'
      end
      
      # Win/Loss Reports collection routes (not deal-scoped)
      resources :win_loss_reports, only: %i[index] do
        collection do
          get :summary
          get :trends
        end
      end
      
      # ==================== COMMISSIONS ====================
      # Commission Plans
      resources :commission_plans, path: 'commission-plans', only: %i[index show create update destroy] do
        collection do
          get :stats
        end
        
        member do
          post :activate
          post :deactivate
          get :components
          get :available_components, path: 'available-components'
          post :add_component, path: 'add-component'
          delete 'remove-component/:component_id', to: 'commission_plans#remove_component'
          patch :reorder_components, path: 'reorder-components'
        end
      end
      
      # Commission Components
      resources :commission_components, path: 'commission-components', only: %i[index show create update destroy] do
        collection do
          get :stats
        end
        
        member do
          post :activate
          post :deactivate
        end
      end
      
      # Commission Payments (top-level routes)
      resources :commission_payments, path: 'commission-payments', only: %i[index show create update destroy] do
        collection do
          get :stats
          post :bulk_approve
          post :bulk_pay
        end
        
        member do
          post :approve
          post :pay
          post :reverse
        end
      end
      
      # ==================== APPROVALS (Non-Deal-Scoped) ====================
      # Root-level approval routes for listing all approvals
      resources :approvals, only: %i[index show] do
        member do
          post :approve
          post :reject
          post :escalate
        end
      end
      
      # ==================== TERRITORIES ====================
      resources :territories, only: %i[index show create update destroy] do
        member do
          get :stats
          post :assign_user
        end
      end
      
      # ==================== CONTACTS ====================
      resources :contacts, only: %i[index show create update destroy] do
        # Contact Activities (unified activities)
        resources :activities, controller: 'contact_activities', only: %i[index show create update destroy] do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        
        # Contact reminders endpoint (for activity notifications)
        post 'activities/:id/mark_reminder_sent', to: 'contact_activities#mark_reminder_sent'
      end
    end

    # ==================== COMPANY SETTINGS ====================
    namespace :company do
      resource :settings, only: %i[show update] do
        post :test_email, on: :collection
        post :send_test_email, on: :collection
        post :test_sms, on: :collection
      end
      
      # Company Manufacturers (Warranty System)
      # Company-owned manufacturer CRUD (distinct from selecting a global one)
      post   'manufacturers/owned',     to: 'manufacturers#create_owned'
      patch  'manufacturers/owned/:id', to: 'manufacturers#update_owned'
      delete 'manufacturers/owned/:id', to: 'manufacturers#destroy_owned'
      post   'manufacturers/import',    to: 'manufacturers#import'
      resources :manufacturers, only: [:index, :create, :update, :destroy]

      # Company Security Settings
      scope path: ':company_id/security' do
        get 'settings', to: 'security_settings#show'
        patch 'settings', to: 'security_settings#update'
        get 'mfa_stats', to: 'security_settings#mfa_stats'
      end
    end

    # ==================== ADMIN NAMESPACE (Platform Admin Only) ====================
    namespace :admin do
      # Admin Buyers (Portal Users for Admin View)
      resources :buyers, only: [:index]
      
      # Admin Documents (Documents across all clients)
      resources :documents, only: [:index, :show, :create, :update, :destroy] do
        member do
          get :download
        end
      end
      
      resources :manufacturers do
        member do
          post :activate
          post :deactivate
        end
      end

      # ==================== CATALOG SOURCES (Surface B — Platform Admin Only) ====================
      resources :catalog_sources do
        collection do
          get :adapter_options  # per-adapter form metadata (e.g. Clayton Epic regions)
          get  :clayton_home_centers        # typeahead for the Add Clayton Dealer picker
          post :refresh_clayton_directory   # force re-crawl of the Clayton retailer directory
          post :upload_snapshot             # load a captured Trove catalog without shell access
          get  :cavco_retailers             # typeahead for the Add Cavco Dealer picker
          post :refresh_cavco_directory     # rebuild the Cavco retailer directory
          get  :timber_creek_dealers           # typeahead for the Add Timber Creek Dealer picker
          post :refresh_timber_creek_directory # rebuild the Timber Creek retailer directory
        end
        member do
          post :test     # dry-run discover+parse, inline extraction rates (no ingest)
          post :run_now  # enqueue an immediate run
          get  :runs     # scrape_runs history for this source
          post :seed_inventory # one-time onboarding import of a Cavco dealer's real lot
        end
      end

      # ==================== KNOWLEDGE BASE ADMIN (Platform Admin Only) ====================
      # Resource-dispatched CRUD — ?resource=modules|features|articles|tours|...
      scope :knowledge, controller: :knowledge do
        get    'analytics',           action: :analytics
        get    'analytics/:kind',     action: :analytics_kind, constraints: { kind: /searches|tours|articles/ }
        get    ':resource',           action: :index
        post   ':resource',           action: :create
        get    ':resource/:id',       action: :show,    constraints: { id: /\d+/ }
        patch  ':resource/:id',       action: :update,  constraints: { id: /\d+/ }
        put    ':resource/:id',       action: :update,  constraints: { id: /\d+/ }
        delete ':resource/:id',       action: :destroy, constraints: { id: /\d+/ }
      end
    end

    # ==================== PLATFORM SETTINGS ====================
    namespace :platform do
      # ==================== SUBSCRIPTION PLANS ====================
      resources :subscription_plans, path: 'subscription-plans' do
        member do
          post :set_modules
          patch :set_module_config
        end
        collection do
          get :modules
          get :templates
        end
      end
      
      # ==================== TENANTS (TENANT MANAGEMENT) ====================
      resources :tenants do
        # Tenant Subscription Management
        resource :subscription, only: [:show, :create, :update], controller: 'tenant_subscriptions' do
          post :cancel
          post :suspend
          post :activate
        end
        
        # Tenant Module Overrides
        get :modules, to: 'tenant_subscriptions#modules'
        post 'modules/override', to: 'tenant_subscriptions#override_module'
        delete 'modules/override/:module_key', to: 'tenant_subscriptions#remove_override'
        post 'modules/bulk_override', to: 'tenant_subscriptions#bulk_override'
        patch 'modules/config', to: 'tenant_subscriptions#update_module_config'
        
        member do
          get :check_domain_dns
          post :verify_domain
          post :generate_domain_token
          post :send_owner_invitation  # NEW: Send tenant owner invitation
          patch :update_owner_invitation  # NEW: Update owner invitation details
        end
        collection do
          get :check_subdomain_available
          get :check_domain_available
        end

        # Twilio SMS Provisioning (Platform Admin)
        post   'twilio/provision',   to: 'twilio_provisioning#provision'
        delete 'twilio/deprovision', to: 'twilio_provisioning#deprovision'
        get    'twilio/status',      to: 'twilio_provisioning#status'
      end

      # SMS Usage Dashboard (Platform Admin)
      get   'sms_usage',                        to: 'sms_usage#index'
      get   'sms_usage/:company_id',            to: 'sms_usage#show'
      patch 'sms_usage/:company_id/set_limit',  to: 'sms_usage#set_limit'

      get   'email_usage',                       to: 'email_usage#index'
      get   'email_usage/:company_id',           to: 'email_usage#show'
      patch 'email_usage/:company_id/set_limit', to: 'email_usage#set_limit'

      resource :settings, only: %i[show update] do
        post :test_email, on: :collection
        post :test_sms, on: :collection
      end

      # ==================== PLATFORM COMMUNICATIONS ====================
      # Unified communications API for all entity types
      get 'communications/:entity_type/:entity_id/history', to: 'communications#history'
      get 'communications/:entity_type/:entity_id/stats', to: 'communications#stats'
      delete 'communications/:entity_type/:entity_id/messages/:id', to: 'communications#destroy'
      post 'communications/email', to: 'communications#email'
      post 'communications/sms', to: 'communications#sms'
      
      # Communication templates - Namespaced RESTful routes
      namespace :communications do
        resources :templates, only: [:index, :show, :create, :update, :destroy] do
          member do
            post :test
          end
        end
      end
      
      # ==================== SYNDICATION PARTNERS ====================
      resources :syndication_partners, path: 'syndication-partners' do
        member do
          patch :toggle
          post :regenerate_token, path: 'regenerate-token'
        end
      end
    end
  end

  # Phase 4A & 4B - Portal (Portal User System)
  namespace :api do
    namespace :portal do
      # Phase 4A - Authentication (Portal Users)
      post 'auth/login', to: 'auth#login'
      post 'auth/request_magic_link', to: 'auth#request_magic_link'
      post 'auth/magic-link', to: 'auth#request_magic_link'
      get 'auth/verify_magic_link', to: 'auth#verify_magic_link'
      post 'auth/request_reset', to: 'auth#request_reset'
      post 'auth/forgot-password', to: 'auth#forgot_password'
      post 'auth/reset-password', to: 'auth#reset_password'
      patch 'auth/reset_password', to: 'auth#reset_password'
      get 'auth/profile', to: 'auth#profile'
      get 'auth/verify_invitation', to: 'auth#verify_invitation'
      post 'auth/complete_registration', to: 'auth#complete_registration'
      
      # Phase 4B - Quote Management
      resources :quotes, only: [:index, :show] do
        member do
          patch :accept
          patch :reject
        end
      end
      
      # Phase 4C - Communications
      resources :communications, only: [:index, :show, :create] do
        member do
          patch :mark_as_read
        end
      end
      get 'communications/threads', to: 'communications#threads'
      post 'communications/:thread_id/reply', to: 'communications#create'
      
      # Phase 4E - Document Management
      resources :documents, only: [:index, :show, :create, :destroy] do
        member do
          get :download
        end
      end

      # Phase 4D - Communication Preferences
      get 'preferences', to: 'preferences#show'
      patch 'preferences', to: 'preferences#update'
      get 'preferences/history', to: 'preferences#history'
      
      # Portal Settings (Branding & Modules)
      get 'settings/branding', to: 'settings#branding'
      get 'settings/modules', to: 'settings#modules'
      
      # Phase 4F - Loans with Payment Processing
      resources :loans, only: [:index, :show] do
        member do
          get :payments
          post :make_payment
        end
      end
      
      # Phase 4F - Payment Methods (Saved Payment Methods)
      resources :payment_methods, only: [:index, :destroy], path: 'payment-methods' do
        member do
          post :set_default
        end
      end
      
      # Phase 4G - Invoices with Payment Processing
      resources :invoices, only: [:index, :show] do
        member do
          get :payments
          post :make_payment
          get :download
        end
        
        collection do
          get :stats
        end
      end
      
      # Portal Project Progress
      resources :projects, only: [:index, :show] do
        collection do
          get :pending_approvals  # Cross-project list of work awaiting buyer review (dashboard tile)
        end
        member do
          post :acknowledge_task  # POST body: { phase_id:, task_id: }
          # Client review actions on a completed contractor assignment.
          # POST body: { notes: } (required for request_revision)
          post 'reviews/:assignment_id/approve',          action: :approve
          post 'reviews/:assignment_id/request_revision', action: :request_revision
          post 'reviews/:assignment_id/reject',           action: :reject
        end
      end

      # Portal Service Tickets
      resources :service_tickets, only: [:index, :show, :create], path: 'service-tickets' do
        member do
          post :notes # Customer replies to a customer-facing note thread
        end
      end

      # Portal Agreements
      resources :agreements, only: [:index, :show] do
        member do
          get :download
        end
      end

      # Portal Home Configurator
      scope 'configurator' do
        get 'settings', to: 'configurator#settings'
        get 'floor-plans', to: 'configurator#floor_plans'
        get 'floor-plans/:id', to: 'configurator#floor_plan_detail'
        post 'submit', to: 'configurator#submit'
        get 'my-configurations', to: 'configurator#my_configurations'
      end
    end
  end

  # ==================== CONTRACTOR PORTAL ====================
  namespace :api do
    namespace :contractor do
      # Authentication
      post 'sessions/magic_link', to: 'sessions#magic_link'
      post 'sessions/verify', to: 'sessions#verify'
      post 'sessions/login', to: 'sessions#login'

      # Dashboard
      get 'dashboard', to: 'dashboard#index'

      # Profile
      get 'profile', to: 'profile#show'
      patch 'profile', to: 'profile#update'
      post 'profile/set_password', to: 'profile#set_password'
      post 'profile/sync_credentials', to: 'profile#sync_credentials'

      # Branding
      get 'branding', to: 'branding#show'

      # Projects
      resources :projects, only: [:index, :show]

      # Tasks
      resources :tasks, only: [:index, :show] do
        member do
          patch :update_status
          patch :toggle_checklist_item
          patch :add_note
          post :submit_for_review
          get :work_logs
          post :work_logs, action: :create_work_log
        end
      end

      # Service Tickets
      resources :service_tickets, only: [:index, :show], path: 'service-tickets' do
        member do
          patch :update_status
          patch :add_note
          post :submit_for_review
          get :work_logs
          post :work_logs, action: :create_work_log
          # Vendor confirms what was actually done on one complaint.
          patch 'issues/:issue_id', action: :confirm_issue
        end
      end

      # Uploads
      post 'uploads', to: 'uploads#create'
      delete 'uploads', to: 'uploads#destroy'
    end
  end

  # ==================== PARTNER API (API Key Auth) ====================
  namespace :api do
    namespace :partner do
      namespace :v1 do
        # Health check
        get 'ping', to: 'ping#show'

        # Tier 1 - Core CRM Resources
        resources :contacts, only: [:index, :show, :create, :update, :destroy]
        resources :leads, only: [:index, :show, :create, :update, :destroy]
        resources :accounts, only: [:index, :show, :create, :update, :destroy]
        resources :deals, only: [:index, :show, :create, :update, :destroy]

        # Tier 2 - Operations & Inventory
        resources :vehicles, only: [:index, :show, :create, :update, :destroy]
        resources :invoices, only: [:index, :show, :create, :update, :destroy]
        resources :service_tickets, only: [:index, :show, :create, :update, :destroy], path: 'service-tickets'
        resources :quotes, only: [:index, :show, :create, :update, :destroy]

        # Tier 3 - Organization & Finance
        resources :locations, only: [:index, :show, :create, :update, :destroy]
        resources :users, only: [:index, :show]
        resources :payments, only: [:index, :show, :create, :update, :destroy]
        resources :loans, only: [:index, :show, :create, :update, :destroy]

        # Webhooks
        get 'webhook-events', to: 'webhook_events#index'
        resources :webhook_endpoints, only: [:index, :show, :create, :update, :destroy], path: 'webhook-endpoints' do
          resources :deliveries, only: [:index, :show], controller: 'webhook_deliveries'
        end
      end
    end
  end

end
