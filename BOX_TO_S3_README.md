# Box → S3 Champion Homes Transfer

## Run (WSL Ubuntu terminal)

```bash
cd ~/src/renterinsight_api

# Install deps (once)
pip install boto3 requests --break-system-packages

# Set AWS credentials
export AWS_ACCESS_KEY_ID="your_key_here"
export AWS_SECRET_ACCESS_KEY="your_secret_here"
export AWS_REGION="us-west-2"
export AWS_S3_BUCKET="renterinsight-website-assets-staging"

# Run
python3 box_to_s3.py
```

## What it does
1. Crawls Champion Homes folder in Box (Topeka IN factory)
   - Genesis series → Emerald Sky model → WEB / JPGS / Videos
   - Embrace series → all models
   - Skips "Topeka Prime [Not for Web]" automatically
2. Streams each file Box → S3 directly (zero local disk usage)
3. 4 parallel upload workers
4. Fully resumable — Ctrl+C and rerun, skips already-uploaded files

## S3 path structure
```
renterinsight-website-assets-staging/
  floor-plans/champion/topeka-in/champion-homes/
    genesis/
      emerald-sky/
        web/    ← 29 web-optimized JPGs (used by configurator)
        jpgs/   ← 29 full-res JPGs
        videos/ ← 4 video files
    embrace/
      [model-name]/web|jpgs|videos/
```

## Output files (stay in renterinsight_api/)
- `manifest.json`  — every uploaded file with s3_url, model info
- `progress.json`  — resume state (safe to delete after full run)
- `box_to_s3.log`  — full transfer log

## After transfer
Feed manifest.json to the inventory importer to create FloorPlan records
and add all homes to Factory Direct Homes' RenterInsight inventory.
