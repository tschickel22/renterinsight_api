# 🐛 Tracking Issues - Troubleshooting Guide

## ✅ **SMS Issue - FIXED**

### Problem
```
Error: The 'StatusCallback' URL http://localhost:3001/webhooks/twilio/sms/status is not a valid URL
```

### Solution
✅ **Fixed!** The code now skips the StatusCallback URL when running on localhost. Twilio doesn't accept localhost URLs for webhooks.

**What Changed:**
- SMS will now send successfully on localhost
- No delivery tracking on localhost (that's okay for testing)
- Delivery tracking will work when deployed to production with a real domain

### To Test SMS Now:
1. Restart your Rails server
2. Try sending SMS again - it should work!
3. SMS will be sent, but `delivered_at` won't be updated on localhost
4. This is expected behavior - delivery tracking requires a public URL

---

## 🔍 **Email Tracking Issue - Debugging**

### Why Email Tracking Might Not Work

#### **1. Email Client Blocking Images (Most Common)**
Most email clients block images by default for privacy:
- Gmail: Blocks images unless you click "Display images"
- Outlook: Blocks external content
- Apple Mail: May block tracking pixels

**Solution:** Manually load images in your email client

#### **2. Plain Text Email Instead of HTML**
If the email body doesn't contain HTML, the tracking pixel won't work.

**Check:** View the sent email's HTML source to see if the pixel is there

#### **3. Tracking Pixel URL Incorrect**
The pixel URL should look like: `http://localhost:3001/webhooks/email/123/pixel.gif`

---

## 🧪 **Step-by-Step Testing Guide**

### Test 1: Send Email and Verify Tracking Pixel

```bash
# 1. Open Rails console
cd \\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api
rails c

# 2. Find the last email sent
email = Communication.where(channel: 'email').last

# 3. Check if tracking pixel was added
puts email.body
# Should see: <img src="http://localhost:3001/webhooks/email/123/pixel.gif" ...>

# 4. Check current status
puts "ID: #{email.id}"
puts "Status: #{email.status}"
puts "Sent at: #{email.sent_at}"
puts "Read at: #{email.read_at}"  # Should be nil before opening
```

### Test 2: Manually Trigger Tracking Pixel

Instead of waiting for email client to load images, test the webhook directly:

```bash
# In your browser or using curl:
curl http://localhost:3001/webhooks/email/123/pixel.gif

# Replace 123 with your actual communication ID
```

**Expected Result:**
- You should see a tiny image (1x1 transparent GIF)
- Check Rails console logs - should see:
  ```
  [EmailTracking] Email 123 opened by kelly@example.com
  ```

### Test 3: Verify Read Status Updated

```bash
# Back in Rails console:
email.reload
puts "Read at: #{email.read_at}"  # Should now show a timestamp

# Check events
email.communication_events.each do |event|
  puts "Event: #{event.event_type} at #{event.occurred_at}"
end
# Should see: Event: opened at [timestamp]
```

### Test 4: Verify Frontend Display

1. Refresh the Communication Center in your browser
2. Look at the History tab
3. You should now see: **👁️ Read [timestamp]**

---

## 🔬 **Advanced Debugging**

### Check if Tracking Pixel is Being Added

```ruby
# Rails console
email = Communication.where(channel: 'email').last

# See the actual body
puts "=" * 50
puts email.body
puts "=" * 50

# Check if pixel is there
if email.body.include?('pixel.gif')
  puts "✅ Tracking pixel is present!"
  
  # Extract the pixel URL
  pixel_url = email.body.match(/src="([^"]*pixel\.gif)"/)[1]
  puts "Pixel URL: #{pixel_url}"
else
  puts "❌ Tracking pixel NOT found - this is the problem!"
  puts "Email might be plain text, or pixel wasn't added"
end
```

### Test Webhook Endpoint Directly

```bash
# Test the webhook controller works:
curl -v http://localhost:3001/webhooks/email/999/pixel.gif

# Should return:
# HTTP/1.1 200 OK
# Content-Type: image/gif
# (and a tiny binary GIF image)
```

### Check Rails Logs

```bash
# Watch logs while testing
tail -f \\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api\log\development.log | grep -i "email\|tracking\|pixel"
```

---

## 📧 **Email Client Workarounds**

### Gmail
1. Open the email
2. Look for "Images are not displayed"
3. Click **"Display images below"**
4. Or click **"Always display images from..."**

### Outlook
1. Open the email
2. Click **"Download pictures"** at the top
3. Or go to Settings → Trust Center → Automatic Download → Unblock

### Apple Mail
1. Usually loads images automatically
2. If not: Mail → Preferences → Privacy → Uncheck "Block all remote content"

---

## 🎯 **Quick Fix: Force Email to Open**

If you just want to test that tracking works, use this shortcut:

```ruby
# Rails console
# Find your test email
email = Communication.where(channel: 'email', communicable_id: 4).last

# Manually mark as opened (simulating pixel load)
email.update!(read_at: Time.current)
CommunicationEvent.track_open(email, ip_address: '127.0.0.1', user_agent: 'Manual Test')

# Verify
puts "Read at: #{email.read_at}"  # Should show timestamp

# Refresh frontend - should now show 👁️ Read indicator
```

---

## 📊 **Expected Behavior Summary**

### SMS (After Fix)
✅ **Localhost:**
- SMS sends successfully
- No delivery tracking (StatusCallback skipped)
- `delivered_at` stays null
- Shows "sent" status in UI

✅ **Production (with public domain):**
- SMS sends successfully
- Twilio calls webhook
- `delivered_at` gets updated
- Shows **✓ "Delivered [time]"** in UI

### Email
✅ **Always Works:**
- Email sends successfully
- Tracking pixel embedded
- Communication record created
- Shows "sent" status in UI

✅ **When Recipient Opens (or pixel is loaded manually):**
- Webhook fires
- `read_at` gets updated
- Shows **👁️ "Read [time]"** in UI

❌ **When Email Client Blocks Images:**
- Tracking pixel never loads
- `read_at` stays null
- No "Read" indicator shown
- This is expected - user must load images

---

## 🚀 **Next Steps**

1. **Test SMS Fix:**
   - Restart Rails server
   - Send SMS via UI
   - Should work without 422 error

2. **Test Email Tracking:**
   - Send email via UI
   - Check Rails console for tracking pixel
   - Either:
     - Open email and load images, OR
     - Test webhook directly with curl, OR
     - Manually mark as read in console
   - Verify "Read" indicator shows in UI

3. **Production Deployment:**
   - Deploy to server with public URL
   - SMS delivery tracking will work automatically
   - Email tracking will work when recipients load images

---

## 💡 **Pro Tips**

### For Testing Email Tracking:
```bash
# Create a test that always works:
# 1. Send email
# 2. Get the communication ID from the response
# 3. Immediately hit the webhook:
curl http://localhost:3001/webhooks/email/[ID]/pixel.gif
# 4. Refresh UI - should show "Read"
```

### For Testing SMS Delivery:
```bash
# On production with ngrok:
# 1. Start ngrok: ngrok http 3001
# 2. Code will automatically use the ngrok URL
# 3. Send SMS - delivery tracking will work!
```

---

## ✅ **Success Checklist**

- [ ] SMS sends without 422 error
- [ ] Email sends successfully  
- [ ] Email body contains tracking pixel (check in console)
- [ ] Webhook endpoint responds to curl test
- [ ] Manual pixel trigger updates `read_at`
- [ ] Frontend shows "Read" indicator after triggering
- [ ] Frontend shows message history correctly

---

**Having Issues?** Check the Rails logs for errors and verify each step above.
