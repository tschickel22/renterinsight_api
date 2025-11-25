# Zego Payment Webhook Configuration

## Overview
Zego sends webhook callbacks to notify your application of payment status changes. This system handles these callbacks asynchronously to ensure quick response times and prevent timeouts.

## Architecture

```
Zego → Webhook Controller → Background Job → Payment Processing
```

1. **Webhook Controller** (`app/controllers/webhooks/zego_controller.rb`)
   - Receives POST requests from Zego
   - Logs incoming data
   - Enqueues background job
   - Returns 200 OK immediately

2. **Background Job** (`app/jobs/handle_payment_update_job.rb`)
   - Processes webhook data asynchronously
   - Updates payment records
   - Sends notifications
   - Handles accounting updates

## Webhook Endpoints

### Processed Payment
**URL:** `POST /webhooks/zego/processed`

Called when Zego successfully processes a payment.

**Expected Parameters:**
```json
{
  "payment_reference_id": "12345",
  "transaction_id": "ZEGO-TX-67890",
  "gateway_payer_id": "GP-12345",
  "amount": "500.00",
  "status": "Success"
}
```

### Canceled Payment
**URL:** `POST /webhooks/zego/canceled`

Called when Zego cancels or rejects a payment.

**Expected Parameters:**
```json
{
  "payment_reference_id": "12345",
  "transaction_id": "ZEGO-TX-67890",
  "code": "5",
  "message": "Payment was canceled",
  "status": "Canceled"
}
```

## Zego Configuration

### Development/Staging URLs
```
Processed: https://your-staging-api.render.com/webhooks/zego/processed
Canceled:  https://your-staging-api.render.com/webhooks/zego/canceled
```

### Production URLs
```
Processed: https://your-production-api.render.com/webhooks/zego/processed
Canceled:  https://your-production-api.render.com/webhooks/zego/canceled
```

## Setup in Zego Admin Panel

1. Log into Zego Admin Portal
2. Navigate to **Settings** → **Webhooks**
3. Add webhook URLs for:
   - Payment Processed
   - Payment Canceled
4. Save configuration
5. Test webhooks using Zego's test mode

## Payment Status Flow

### Successful Payment Flow
1. Payment initiated via API
2. Zego processes payment
3. Zego sends webhook to `/webhooks/zego/processed`
4. Background job updates payment status to `completed`
5. Payment method's `external_id` updated with `gateway_payer_id`
6. Confirmation email/SMS sent to payer
7. Lease balance updated
8. Accounting transaction recorded

### Failed Payment Flow
1. Payment initiated via API
2. Zego rejects payment
3. Zego sends webhook to `/webhooks/zego/canceled`
4. Background job updates payment status to `failed`
5. Failure reason recorded based on error code
6. Failure notification sent to payer
7. Property manager notified
8. If ACH return, payment method flagged

## Error Codes

| Code | Description | Action Taken |
|------|-------------|--------------|
| 2 | Insufficient funds | Mark payment failed, notify payer |
| 3 | Invalid account | Mark payment failed, flag payment method |
| 4 | Declined by processor | Mark payment failed, notify payer |
| 5 | Canceled | Mark payment failed, log cancellation |
| 6 | ACH returned | Mark payment failed, flag ACH account |

## Testing Webhooks

### Using cURL
```bash
# Test processed webhook
curl -X POST http://localhost:3000/webhooks/zego/processed \
  -H "Content-Type: application/json" \
  -d '{
    "payment_reference_id": "123",
    "transaction_id": "TEST-TX-456",
    "gateway_payer_id": "GP-789",
    "amount": "100.00",
    "status": "Success"
  }'

# Test canceled webhook
curl -X POST http://localhost:3000/webhooks/zego/canceled \
  -H "Content-Type: application/json" \
  -d '{
    "payment_reference_id": "123",
    "transaction_id": "TEST-TX-456",
    "code": "5",
    "message": "Payment canceled",
    "status": "Canceled"
  }'
```

### Using Rails Console
```ruby
# Simulate processed webhook
HandlePaymentUpdateJob.perform_now('processed', {
  payment_reference_id: '123',
  transaction_id: 'TEST-TX-456',
  gateway_payer_id: 'GP-789',
  amount: '100.00'
}.to_json)

# Simulate canceled webhook
HandlePaymentUpdateJob.perform_now('canceled', {
  payment_reference_id: '123',
  transaction_id: 'TEST-TX-456',
  code: '5',
  message: 'Payment canceled'
}.to_json)
```

## Monitoring

### Log Files
Webhook activity is logged to Rails logger:
```
Rails.logger.info("Zego Webhook: PROCESSED")
Rails.logger.info("Processing Zego processed webhook for payment 123")
Rails.logger.info("Successfully processed payment 123: TEST-TX-456")
```

### Background Job Queue
Monitor background jobs in Sidekiq (if using Sidekiq):
```
http://your-app.com/sidekiq
```

### Database Queries
Check payment status updates:
```sql
SELECT id, status, external_id, processed_at, failed_at, failure_reason
FROM payments
WHERE updated_at > NOW() - INTERVAL '1 hour'
ORDER BY updated_at DESC;
```

## Troubleshooting

### Webhook Not Received
1. Check Zego admin panel webhook configuration
2. Verify URLs are publicly accessible
3. Check firewall/security settings
4. Review Zego logs for delivery attempts

### Payment Not Updated
1. Check background job queue for failures
2. Review Rails logs for errors
3. Verify payment exists with `payment_reference_id`
4. Check JSON parsing in HandlePaymentUpdateJob

### Duplicate Processing
The system is idempotent - multiple webhook calls with same data will only update the payment once. The `external_id` and status fields prevent duplicates.

## Security Considerations

1. **No Authentication Required**: Webhooks bypass authentication
2. **IP Whitelisting**: Consider adding Zego IP whitelist (optional)
3. **Webhook Signatures**: Zego may provide signatures for verification (implement if available)
4. **HTTPS Only**: Always use HTTPS in production
5. **Immediate Response**: Always return 200 OK to prevent retries

## Post-Processing Extensions

The `HandlePaymentUpdateJob` includes hooks for custom processing:

- `process_payment_completion(payment)` - Add custom success logic
- `process_payment_failure(payment, reason)` - Add custom failure logic
- `send_payment_confirmation(payment)` - Customize notifications
- `record_accounting_transaction(payment)` - Integrate accounting
- `notify_external_systems(payment)` - Trigger external webhooks

## Related Files

- Controller: `app/controllers/webhooks/zego_controller.rb`
- Job: `app/jobs/handle_payment_update_job.rb`
- Routes: `config/routes.rb` (webhooks namespace)
- API Service: `lib/zego_payment_api.rb`
- Payment Model: `app/models/payment.rb`
