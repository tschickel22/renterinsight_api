# 🚀 One-Time Setup for Render Free Tier

Since Render's free tier doesn't automatically run `rails db:seed`, we've created a secure one-time setup endpoint.

## 📝 Setup Steps

### 1️⃣ Add Environment Variable to Render

In your Render dashboard:
1. Go to your web service
2. Click **Environment** tab
3. Add this variable:
   ```
   SETUP_TOKEN=Mindzenty1Setup2025
   ```
4. **Save Changes** (this will redeploy)

### 2️⃣ Call the Setup Endpoint

Once deployed, visit this URL in your browser (or use curl):

```
https://your-app-name.onrender.com/api/setup?token=Mindzenty1Setup2025
```

**Replace `your-app-name` with your actual Render app name!**

### 3️⃣ Expected Response

**Success (first time):**
```json
{
  "message": "🎉 Setup complete!",
  "users_created": [
    { "email": "t+admin@renterinsight.com", "role": "admin" },
    { "email": "t+client@renterinsight.com", "role": "client" }
  ],
  "login_url": "https://your-app.onrender.com/api/auth/login",
  "admin_credentials": {
    "email": "t+admin@renterinsight.com",
    "password": "Mindzenty1!"
  }
}
```

**Already setup:**
```json
{
  "message": "✅ Already setup! Admin user exists.",
  "admin_email": "t+admin@renterinsight.com"
}
```

**Wrong token:**
```json
{
  "error": "Invalid token"
}
```

## 🔐 Admin Login Credentials

After setup, you can login with:

- **Email:** `t+admin@renterinsight.com`
- **Password:** `Mindzenty1!`

## ⚠️ Security Notes

- The endpoint checks if users already exist - safe to call multiple times
- Only creates users if they don't exist
- Token is required - no token = no access
- **IMPORTANT:** This is just for initial setup. Delete the `SETUP_TOKEN` env var after you're done if you want extra security!

## 🧹 After Setup (Optional)

Once your admin user is created, you can optionally:
1. Remove the `SETUP_TOKEN` environment variable from Render
2. The endpoint will still exist but won't work without the token

---

**Need to reset?** Delete the users and call the endpoint again:
```ruby
# In Rails console
User.where(email: ['t+admin@renterinsight.com', 't+client@renterinsight.com']).destroy_all
```
