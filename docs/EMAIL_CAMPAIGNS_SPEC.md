# Email Campaigns Module — Final Spec

**Version:** 2.0 (grounded against live schema)
**Ship model:** Big-bang. Nothing ships to customers until the entire module is feature-complete.
**Target:** 8 working weeks. Internal phases A/B build the backend; C/D add frontend.
**Philosophy:** User views, tests, edits. Never builds from scratch. Templates + AI do the heavy lifting.
**Reusability:** All Messaging::* primitives are designed so the existing Nurture module can be rewritten on top of them later.

## Scope summary

In v1: blast, drip, triggered, recurring inventory digest. OAuth-only sending (User/Location/Company, never platform). All 3 inventory merge modes. AI campaign generation with refinement. 11 seeded templates. Open/click/reply/bounce/unsubscribe tracking. 8 goal types. Suppression list. Per-campaign and per-recipient analytics. Webhook events. API key scopes.

Deferred to v2: A/B testing, ESP integration (SendGrid/Postmark/SES), drag-drop email designer, ML send-time optimization, heatmaps, SMS.

## Reused infrastructure (do not duplicate)

- Communication, CommunicationEvent — outbound email records + open/click/bounce/unsubscribe events. Auto-updates Communication status.
- CommunicationService.send_email — provider dispatch (oauth_gmail → SmtpProvider, oauth_outlook → MicrosoftGraphProvider). Pass provider + credentials through.
- UserEmailConnection — full OAuth refresh + Graph token handling. Cloned for LocationEmailConnection and CompanyEmailConnection.
- AiQueryLog — already has input_tokens, output_tokens, cost_cents, feature, module_key, company_id. Just add features ai_campaign_generate, ai_campaign_refine to the FEATURES constant.
- WorkflowEngine::ConditionEvaluator — evaluates {type, children, field, operator, value} AST. Used for audience filter trees. Zero new filter logic.
- WebhookEndpoint, WebhookDelivery, WebhookService — register new event types; existing infra fires them.
- ApiKey — register new scopes; existing middleware authenticates.
- InboundEmail::ProcessorService — extend to handle reply+campaign-<send_id>@ token prefix.
- /webhooks/email/:communication_id/pixel.gif — open tracking already live; reuse unchanged.
- SubscriptionLimitService — pre-flight credit check pattern from AI Search.

## Identity resolution

Sender picks User / Location / Company. At send time:

```
campaign.from_identity_type + from_identity_id
  ├─ 'User'     → UserEmailConnection.where(user_id: id, is_active: true).first
  ├─ 'Location' → LocationEmailConnection.where(location_id: id, is_active: true).first
  └─ 'Company'  → CompanyEmailConnection.where(company_id: id, is_active: true).first
```

If nil → enrollment.failure_reason = 'no_valid_email_connection', status = 'failed'. Never falls through.

## Inventory merge — three modes

- segment_based — reads recipient's custom_field_values for budget/preferences, applies as Vehicle filters
- category_based — campaign-level filter set (manufacturer, bedrooms, price_max, location_ids)
- manual_pick — explicit vehicle_ids, re-checked at send time, drops unavailable units

Sort: newest | price_low | price_high | best_match. Max units configurable. Fallback: skip_block | show_cta | abort_send.

## Block-based composition

campaign_step.body_blocks is a typed jsonb array: text, image, button, inventory, divider, footer_unsubscribe. footer_unsubscribe auto-inserted if missing (CAN-SPAM).

## Goals (v1)

opened, clicked, replied, form_submitted, deal_created, deal_stage_advanced, unit_sold, custom_webhook. meeting_booked deferred.

## Module boundaries

Shared primitives (app/services/messaging/) are campaign-agnostic so Nurture can adopt them later: BlockRenderer, MergeTagResolver, LinkTokenizer, InventoryBlockResolver, PixelInjector, UnsubscribeFooter, EmailConnectionResolver, SendWindowCalculator, ThrottleChecker.

Campaign-specific (app/services/campaigns/): CampaignSender, AudienceEnroller, ReplyHandler, GoalChecker, AiBuilder, TemplateInstantiator.
