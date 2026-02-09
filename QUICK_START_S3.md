# 🚀 QUICK START: Test AWS S3 Integration

## Step 1: Install AWS SDK (2 minutes)

```bash
cd ~/src/renterinsight_api
bundle install
```

## Step 2: Restart Rails (1 minute)

```bash
pkill -f "puma.*3001"
bin/rails server -b 'ssl://0.0.0.0:3001?cert=localhost+1.pem&key=localhost+1-key.pem'
```

## Step 3: Verify S3 Service (30 seconds)

```bash
bin/rails console

# Should print bucket name and region
s3 = S3UploadService.new
puts "✅ S3 Ready: #{s3.bucket_name} in #{s3.region}"

exit
```

**Expected Output:**
```
✅ S3 Ready: renterinsight-website-assets-staging in us-west-2
```

---

## ✅ If All Works - What You've Got:

- AWS S3 bucket created and configured
- Rails backend can upload files to S3
- Files stored securely (private bucket)
- Presigned URLs generated for temporary access
- Automatic file cleanup on DB save failure

---

## Next Phase (Frontend):

Update `MediaManager.tsx` to:
1. Send files as `multipart/form-data` (not base64)
2. Display uploaded media using presigned URLs

**Ready to start frontend updates?** Let me know!

---

## Need Help?

**Error Messages:**
- "AWS credentials missing" → Check `.env` file
- "Bundle install failed" → Run `bundle install --redownload`
- "Rails won't start" → Check Docker PostgreSQL is running

**Quick Diagnostics:**
```bash
# Check Docker
docker ps | grep pg-local

# Check AWS env vars
grep AWS_ .env

# Test Rails API
curl -k https://localhost:3001/api/v1/websites
```
